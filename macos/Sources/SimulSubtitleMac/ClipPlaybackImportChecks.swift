import AVFoundation
import Foundation

@MainActor
enum ClipPlaybackImportChecks {
    static func run(directory: URL, fixture: URL) async throws -> [String] {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("recording with spaces.mkv")
        let remux = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-y", "-i", fixture.path, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy", source.path])
        var checks: [String] = []
        func check(_ passed: Bool, _ name: String) throws {
            guard passed else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        try check(remux.status == 0, "clip_real_matroska_fixture")
        let store = ClipStore(root: directory.appendingPathComponent("store"))
        let id = try await store.importVideo(source)
        guard let project = store.selected else { throw ClipError.message("Missing clip project") }
        try check(project.ranges.isEmpty && ClipStore(root: store.root).selected?.ranges == [], "clip_new_project_reopens_without_ranges")

        let cache = directory.appendingPathComponent("cache")
        let playback = ClipPlayback()
        await playback.prepare(project.media, cache: cache)
        for _ in 0..<100 where !playback.ready && playback.failure == nil { try await Task.sleep(nanoseconds: 50_000_000) }
        guard let preview = (playback.player.currentItem?.asset as? AVURLAsset)?.url else { throw ClipError.message(playback.failure ?? "No player item") }
        try check(playback.ready && preview != source && preview.pathExtension == "mp4", "clip_mkv_editor_uses_playable_mp4")
        playback.toggle()
        for _ in 0..<80 where playback.time < 0.2 { try await Task.sleep(nanoseconds: 50_000_000) }
        playback.player.pause()
        try check(playback.time >= 0.2, "clip_matroska_player_clock_advances")
        let moved = await playback.player.seek(to: CMTime(seconds: 3, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let asset = AVURLAsset(url: preview)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: 3, preferredTimescale: 600)).image
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        try check(moved && abs(playback.player.currentTime().seconds - 3) < 0.1 && image.width > 0 && !audioTracks.isEmpty,
                  "clip_matroska_seek_displays_frame_and_preserves_audio")
        let modified = try preview.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reused = try await ClipPlaybackSource.resolve(project.media, cache: cache)
        let reusedDate = try reused.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try check(preview == reused && modified == reusedDate, "clip_reopen_reuses_valid_proxy")
        playback.player.replaceCurrentItem(with: nil)
        try Data("bad cache".utf8).write(to: preview, options: .atomic)
        let rebuilt = try await ClipPlaybackSource.resolve(project.media, cache: cache)
        let rebuiltMedia = try await ClipMediaEngine.inspect(rebuilt)
        try check(rebuilt == preview && abs(rebuiltMedia.duration - project.media.duration) < 0.25, "clip_corrupt_proxy_regenerates")
        let native = try await ClipMediaEngine.inspect(fixture)
        let direct = try await ClipPlaybackSource.resolve(native, cache: cache)
        try check(direct == fixture, "clip_native_movie_plays_directly")

        let silent = directory.appendingPathComponent("silent.mkv")
        let encoded = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-y", "-i", fixture.path, "-t", "1.5", "-an", "-c:v", "mpeg4", silent.path])
        try check(encoded.status == 0, "clip_mpeg4_silent_matroska_fixture")
        let silentMedia = try await ClipMediaEngine.inspect(silent)
        async let left = ClipPlaybackSource.resolve(silentMedia, cache: cache)
        async let right = ClipPlaybackSource.resolve(silentMedia, cache: cache)
        let (firstURL, secondURL) = try await (left, right)
        let converted = try await ClipMediaEngine.inspect(firstURL)
        let convertedProbe = try await ClipMediaEngine.probe(secondURL)
        let filesAfter = try files.contentsOfDirectory(atPath: cache.path)
        try check(firstURL == secondURL && !converted.hasAudio && abs(converted.duration - 1.5) < 0.2
                  && convertedProbe.streams.first?.codec_name == "h264" && !filesAfter.contains { $0.hasPrefix(".") },
                  "clip_concurrent_silent_mkv_transcode_publishes_only_complete_h264")
        try files.removeItem(at: silent)
        do {
            _ = try await ClipPlaybackSource.resolve(silentMedia, cache: cache)
            throw ClipError.message("CHECK FAILED: missing source reused")
        } catch let error as ClipError {
            try check(!error.localizedDescription.hasPrefix("CHECK FAILED"), "clip_missing_source_reported_even_with_cached_proxy")
        }

        let output = directory.appendingPathComponent("exports")
        var first = ClipRange(title: "切片 1", start: 0.75, end: 2.75)
        first.selected = false
        let second = ClipRange(title: "选段 2", start: 3.5, end: 5)
        store.saveRange(id, range: first)
        store.saveRange(id, range: second)
        let saved = ClipStore(root: store.root)
        try check(saved.selected?.ranges == [first, second] && saved.selected?.media.url == source, "clip_existing_ranges_selection_and_original_persist")
        try files.removeItem(at: preview)
        saved.start(ClipJob(projectID: id, kind: .export, ranges: [first, second], burnSubtitles: false, outputFolder: output.path), model: nil)
        for _ in 0..<300 where saved.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        guard let movie = saved.selected?.exports.first, let job = saved.jobs.first else { throw ClipError.message(saved.jobs.first?.message ?? "No exported movie") }
        let exported = try await ClipMediaEngine.inspect(URL(fileURLWithPath: movie))
        try check(job.state == .completed && job.ranges == [second] && saved.selected?.exports.count == 1 && abs(exported.duration - second.duration) < 0.15,
                  "clip_only_checked_range_exported_from_original_without_proxy")
        saved.update(id) { $0.ranges = [first] }
        let previousJobCount = saved.jobs.count
        saved.start(ClipJob(projectID: id, kind: .export, ranges: [first, second], outputFolder: output.path), model: nil)
        try check(saved.jobs.count == previousJobCount && !saved.isBusy, "clip_unchecked_and_deleted_ranges_cannot_export")
        saved.update(id) { $0.ranges.removeAll() }
        let reopened = ClipStore(root: store.root)
        try check(reopened.selected?.ranges == [] && reopened.selected?.exports == [movie], "clip_last_range_deleted_reopens_empty_with_outputs")
        // Exercise the same action used by the empty inspector, row separators and footer.
        let manual = ClipStore(root: directory.appendingPathComponent("manual-store"))
        let manualID = try await manual.importVideo(fixture)
        let draftRange = manual.selected!.wholeRange
        func insert(at playhead: Double, before cueID: UUID? = nil) throws -> Caption {
            guard let result = manual.insertSegmentCaption(manualID, range: draftRange, playhead: playhead,
                       before: cueID, source: .english, target: .simplifiedChinese) else {
                throw ClipError.message(manual.notice ?? "Missing inserted caption")
            }
            return result.cue
        }
        var middle = try insert(at: 3)
        try check(manual.selected?.ranges.count == 1 && middle.start == 3 && middle.end == 6 && middle.sourceLanguage == .english,
                  "manual_first_action_creates_range_and_cue_at_playhead")
        func visibleMode(_ project: ClipProject, _ range: ClipRange) -> ClipLanguageMode {
            project.subtitleStyle(for: range, displaying: project.captions(for: range)).mode
        }
        for mode in [ClipLanguageMode.chinese, .japanese] {
            middle.original = mode == .japanese ? "Middle" : ""
            middle.translated = mode == .chinese ? "中间" : ""
            guard manual.saveSegmentCaption(manualID, rangeID: draftRange.id, cue: middle),
                  let project = manual.selected, let range = project.ranges.first else { throw ClipError.message("Missing manual line") }
            try check(visibleMode(project, range) == mode && project.hasBurnableCaptions(for: range),
                      "manual_only_cue_burnable_\(mode == .japanese ? "source" : "translation")")
        }
        middle.original = "Middle"; middle.translated = "中间"
        try check(manual.saveSegmentCaption(manualID, rangeID: draftRange.id, cue: middle), "manual_first_caption_accepts_both_languages")
        var after = try insert(at: 3)
        var before = try insert(at: 3, before: middle.id)
        try check(before.start == 0 && before.end == 3 && after.start == 6 && after.end == 9,
                  "manual_separators_insert_before_and_after_without_retiming_neighbor")
        after.original = "After"; after.translated = "后面"
        before.original = "Before"; before.translated = "前面"
        try check(manual.saveSegmentCaption(manualID, rangeID: draftRange.id, cue: after)
                  && manual.saveSegmentCaption(manualID, rangeID: draftRange.id, cue: before), "manual_adjacent_cues_editable")
        manual.saveRange(manualID, range: draftRange)
        let restored = ClipStore(root: manual.root)
        guard let manualProject = restored.selected, let manualRange = manualProject.ranges.first else { throw ClipError.message("Missing manual range") }
        try check(manualProject.captions(for: manualRange) == [before, middle, after] && manualProject.hasBurnableCaptions(for: manualRange),
                  "manual_track_survives_save_reopen_and_is_ready_to_burn")
        restored.start(ClipJob(projectID: manualID, kind: .export, ranges: [manualRange], burnSubtitles: true,
                               outputFolder: output.path), model: nil)
        for _ in 0..<300 where restored.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        guard let burned = restored.selected?.exports.first else { throw ClipError.message(restored.jobs.first?.message ?? "Missing manual export") }
        let srt = try String(contentsOf: URL(fileURLWithPath: burned).deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
        try check(restored.jobs.first?.state == .completed && srt.contains("前面") && srt.contains("Middle") && srt.contains("后面"),
                  "manual_subtitles_export_burned_mp4_and_matching_sidecar")
        let insertedBefore = try insert(at: 0, before: before.id)
        guard let packed = manual.selected, let packedRange = packed.ranges.first else { throw ClipError.message("Missing packed range") }
        let preserved = packed.captions(for: packedRange).first { $0.id == before.id }
        try check(insertedBefore.start == 0 && insertedBefore.end == preserved?.start && preserved?.end == 3
                  && preserved?.original == before.original, "manual_packed_boundary_inserts_in_display_order_and_keeps_edited_text")
        var tiny = ClipRange(title: "短句", start: 0, end: 0.2)
        tiny.importedCaptions = [Caption(start: 0, end: 0.2, original: "短", translated: "短")]
        manual.saveRange(manualID, range: tiny)
        let denied = manual.insertSegmentCaption(manualID, range: tiny, playhead: 0, source: .japanese, target: .simplifiedChinese)
        try check(denied == nil && manual.notice != nil && manual.selected?.ranges.last == tiny,
                  "manual_full_short_range_reports_reason_and_preserves_track")
        var monoRange = draftRange
        monoRange.importedCaptions = try ClipSubtitleImport.parse("1\n00:00:01,000 --> 00:00:03,000\nこんにちは\n",
                     extension: "srt", layout: .automatic, offset: 0, duration: manualProject.media.duration)
        try check(visibleMode(manualProject, monoRange) == .japanese && manualProject.hasBurnableCaptions(for: monoRange),
                  "manual_source_only_import_defaults_to_burnable_original")
        monoRange.importedCaptions = try ClipSubtitleImport.parse("1\n00:00:01,000 --> 00:00:03,000\n你好\n",
                     extension: "srt", layout: .automatic, offset: 0, duration: manualProject.media.duration)
        try check(visibleMode(manualProject, monoRange) == .chinese && manualProject.hasBurnableCaptions(for: monoRange),
                  "manual_translation_only_import_defaults_to_burnable_translation")
        var imported = monoRange.importedCaptions![0]
        imported.original = "こんにちは"
        monoRange.captionEdits = [imported]
        try check(visibleMode(manualProject, monoRange) == .bilingual && manualProject.hasBurnableCaptions(for: monoRange),
                  "translated_import_edits_enable_both_languages")
        var originalOnly = Caption(start: 6, end: 8, original: "こんばんは", translated: "")
        monoRange.captionEdits?.append(originalOnly)
        monoRange.deletedCaptionIDs = [imported.id]
        try check(visibleMode(manualProject, monoRange) == .japanese && manualProject.hasBurnableCaptions(for: monoRange),
                  "deleted_import_rows_do_not_determine_language_mode")
        monoRange.deletedCaptionIDs = nil
        monoRange.start = 5
        try check(visibleMode(manualProject, monoRange) == .japanese && manualProject.hasBurnableCaptions(for: monoRange),
                  "cropped_import_rows_do_not_determine_language_mode")
        originalOnly.id = UUID()
        var generated = ClipRange(title: "识别草稿", start: 0, end: 10)
        generated.generation = ClipGeneration(serviceKey: "local", span: 0...10, captions: [originalOnly])
        generated.captionEdits = [originalOnly]
        try check(visibleMode(manualProject, generated) == .bilingual && !manualProject.hasBurnableCaptions(for: generated),
                  "incomplete_recognition_keeps_required_translation_after_source_edit")
        monoRange.subtitleStyle = .pink
        try check(monoRange.style == .pink && !manualProject.hasBurnableCaptions(for: monoRange),
                  "single_language_import_respects_an_explicit_bilingual_style")
        try project.media.validateFile()
        return checks
    }
}
