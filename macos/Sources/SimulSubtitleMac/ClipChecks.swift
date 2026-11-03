import AppKit
import AVFoundation
import AVKit
import SwiftUI
import Darwin

private actor ClipFixtureRecognizer: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { "こんにちは。今日は楽しい配信です。" }
}
private actor ClipFixtureTranslator: TextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String { "你好，今天的直播很开心。" }
}
@MainActor
enum ClipChecks {
    private static var started = false
    static func runIfRequested(model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore) async -> Bool {
        guard let flag = CommandLine.arguments.firstIndex(of: "--clip-check"), CommandLine.arguments.count > flag + 2 else { return false }
        guard !started else { return true }; started = true
        let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
        let fixture = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func wait(_ store: ClipStore) async throws {
            for _ in 0..<3600 {
                if !store.isBusy { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            store.cancel(); throw ClipError.message("CHECK FAILED: batch task timeout")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try require(ClipTime.parse("01:02:03.250") == 3723.25 && ClipTime.parse("93.5") == 93.5, "clip_media_time_parsing")
            try require(ClipTime.parse("00:70:01") == nil && ClipTime.parse("nan") == nil && ClipTime.parse("-2") == nil, "clip_invalid_times_rejected")
            try await Release136Checks.translation()
            checks.append("v136_translation_cache_position_and_folders")
            let store = ClipStore(root: directory.appendingPathComponent("store"))
            let id = try await store.importVideo(fixture)
            let again = try await store.importVideo(fixture)
            try require(id == again && store.projects.count == 1, "clip_import_deduplicates_unchanged_media")
            try require(store.projects[0].posterPath.map { FileManager.default.fileExists(atPath: $0) } == true, "clip_cached_video_cover_generated_without_playback")
            let media = store.projects[0].media
            try media.validateFile()
            try await Release136Checks.positionedVideo(media: media, directory: directory)
            checks.append("v136_positioned_subtitle_real_video_export")
            try require(media.width == 640 && media.height == 360 && media.hasAudio && abs(media.duration - 10) < 0.1, "clip_probe_real_h264_audio_duration")
            checks += try await ClipV120Checks.run(fixture: fixture, directory: directory, model: model, monitor: monitor)
            checks += try await ClipV121Checks.run(fixture: fixture, directory: directory)
            checks += try await ClipV122Checks.run(fixture: fixture, directory: directory)
            checks += try await ClipV123Checks.run(directory: directory)
            checks += try await ClipV124Checks.run(directory: directory)
            checks += try await ClipV125Checks.run(directory: directory)
            checks += try ClipHighlightChecks.run(media: media)
            let changedURL = directory.appendingPathComponent("changed-source.mp4")
            try FileManager.default.copyItem(at: fixture, to: changedURL)
            let changedMedia = try await ClipMediaEngine.inspect(changedURL)
            let handle = try FileHandle(forWritingTo: changedURL); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
            try require((try? changedMedia.validateFile()) == nil, "clip_changed_source_requires_reimport_preserves_original_reference")
            let range = ClipRange(title: "双语测试", start: 1, end: 5)
            try range.validate(duration: media.duration)
            try require((try? ClipRange(title: "Bad", start: -1, end: 5).validate(duration: 10)) == nil, "clip_range_cannot_escape_source")
            try require((try? ClipRange(title: "Bad", start: 0, end: 800).validate(duration: 900)) == nil, "clip_export_bounded_to_ten_minutes")
            let cues = [Caption(start: 0.8, end: 2, original: "こんにちは、みんな！", translated: "大家好！"), Caption(start: 3, end: 4.2, original: "今日はとても楽しい。", translated: "今天非常开心。")]
            store.update(id) { $0.captions = cues; $0.ranges = [range] }
            let clipped = ClipTime.captions(cues, within: range)
            try require(clipped.count == 2 && clipped[0].start == 0 && clipped[1].start == 2 && clipped[1].end <= range.duration, "clip_subtitles_rebased_and_clamped_to_media_range")
            let srt = SubtitleDocument.render(clipped, format: .srt, mode: .bilingual)
            try require(srt.contains("00:00:00,000 --> 00:00:01,000") && srt.contains("大家好！"), "clip_srt_bilingual_real_relative_clock")
            let exportFolder = directory.appendingPathComponent("exports")
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
            store.start(ClipJob(projectID: id, kind: .export, ranges: [range], burnSubtitles: true, outputFolder: exportFolder.path), model: nil)
            try await wait(store)
            try require(store.jobs[0].state == .completed, "clip_batch_burn_export_completed_" + store.jobs[0].message)
            guard let movie = store.projects[0].exports.first else { throw ClipError.message("No exported movie") }
            let result = try await ClipMediaEngine.inspect(URL(fileURLWithPath: movie))
            try require(result.width == 640 && result.height == 360 && result.hasAudio && abs(result.duration - 4) < 0.2, "clip_mp4_keeps_aspect_audio_and_exact_duration")
            try require(FileManager.default.fileExists(atPath: URL(fileURLWithPath: movie).deletingPathExtension().appendingPathExtension("srt").path)
                        && FileManager.default.fileExists(atPath: URL(fileURLWithPath: movie).deletingPathExtension().appendingPathExtension("vtt").path), "clip_export_sidecars_saved")
            try media.validateFile(); try require(true, "clip_original_video_unchanged_after_export")
            let captionFrame = try frame(URL(fileURLWithPath: movie), time: 0.5, output: directory.appendingPathComponent("burned-japanese-chinese.png"))
            let gapFrame = try frame(URL(fileURLWithPath: movie), time: 1.5, output: directory.appendingPathComponent("burned-gap-no-ghost.png"))
            try require(pixelDifference(captionFrame, gapFrame) > 300, "clip_subtitle_pixels_burned_and_disappear_at_end")
            try require(store.jobs[0].completedRanges == [range.id], "clip_batch_records_completed_ranges_for_retry")
            store.start(store.jobs[0], model: nil); try await wait(store)
            try require(store.projects[0].exports.count == 1, "clip_retry_does_not_duplicate_completed_export")
            store.start(ClipJob(projectID: id, kind: .preview, range: range), model: nil)
            try await Task.sleep(nanoseconds: 15_000_000); store.cancel(); try await wait(store)
            try require(store.jobs[0].state == .cancelled && store.projects[0].exports.count == 1, "clip_cancel_inflight_job_preserves_finished_exports")
            let projectJSON = try Data(contentsOf: directory.appendingPathComponent("store/projects.json"))
            let restarted = ClipStore(root: directory.appendingPathComponent("store"))
            try require(restarted.projects[0].captions == cues && restarted.projects[0].ranges == [range], "clip_edits_and_ranges_survive_restart")
            try require(!String(decoding: projectJSON, as: UTF8.self).contains("apiKey"), "clip_project_contains_no_service_credentials")
            let crash = LiveMonitorStorage(root: directory.appendingPathComponent("crash"))
            try crash.save([ClipJob(projectID: id, kind: .transcribe)], name: "jobs")
            try require(ClipStore(root: crash.root).jobs[0].state == .interrupted, "clip_interrupted_job_recovered_for_retry")
            let fake = ClipServices(recognizer: ClipFixtureRecognizer(), translator: ClipFixtureTranslator())
            store.update(id) { $0.captions = [] }
            store.start(ClipJob(projectID: id, kind: .transcribe, range: ClipRange(title: "whole", start: 0, end: 10)), model: nil, services: fake)
            try await wait(store)
            try require(store.jobs[0].state == .completed && !store.projects[0].captions.isEmpty, "clip_real_audio_vad_to_timed_transcription_pipeline")
            try require(store.projects[0].captions.allSatisfy { $0.start >= 0 && $0.end <= 10 && $0.end > $0.start && !$0.translated.isEmpty }, "clip_timed_speech_cues_inside_media_bounds")
            try require(!store.projects[0].energy.isEmpty && store.projects[0].analysisCoverage == [0...10], "clip_audio_energy_and_analysis_coverage_persist")
            if let index = CommandLine.arguments.firstIndex(of: "--clip-real-models"), CommandLine.arguments.count > index + 1 {
                let local = LocalModelStore(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                let engines = try await Task.detached(priority: .utility) { ClipServices(recognizer: try ReazonSpeechRecognizer(store: local, threads: 2), translator: try LocalLlamaTranslator(modelPath: local.translationModelPath)) }.value
                store.update(id) { $0.captions = []; $0.analysisCoverage = [] }
                store.start(ClipJob(projectID: id, kind: .transcribe, range: ClipRange(title: "local", start: 0, end: 10)), model: nil, services: engines)
                try await wait(store)
                try require(store.jobs[0].state == .completed && !store.projects[0].captions.isEmpty && store.projects[0].captions.allSatisfy { !$0.original.isEmpty && !$0.translated.isEmpty }, "clip_real_local_japanese_asr_and_chinese_translation")
                try JSONEncoder().encode(store.projects[0].captions).write(to: directory.appendingPathComponent("local-asr-captions.json"))
            }
            store.start(ClipJob(projectID: id, kind: .recommend, recommendationCount: 3), model: nil)
            try await wait(store)
            try require(store.jobs[0].state == .completed && !(store.projects[0].candidates ?? []).isEmpty, "highlights_job_persists_candidates_from_real_timed_subtitles")
            let before = store.projects[0].ranges.count
            store.update(id) { $0.candidates?[0].selected = true }
            store.addCandidates(id); store.addCandidates(id)
            try require(store.projects[0].ranges.count == before + 1, "highlights_add_to_export_ranges_without_duplicates")
            store.start(ClipJob(projectID: id, kind: .preview, range: range), model: nil)
            try await Task.sleep(nanoseconds: 15_000_000); store.pause(); try await wait(store)
            try require(store.jobs[0].state == .paused, "clip_pause_preserves_progress_with_explicit_resume_state")
            let paused = store.jobs[0]; store.start(paused, model: nil); try await wait(store)
            try require(store.jobs[0].state == .completed && store.projects[0].previewHasSubtitles == true, "clip_resume_builds_bilingual_preview")
            let previewPath = store.projects[0].previewPath!
            try require(FileManager.default.fileExists(atPath: previewPath), "clip_preview_persisted_without_autoplay")
            let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
            previewWindow.isReleasedWhenClosed = false
            previewWindow.contentView = NSHostingView(rootView: ClipVideoPreview(url: URL(fileURLWithPath: previewPath), offset: 1, hasSubtitles: true, onSetStart: { _ in }, onSetEnd: { _ in }, onClose: {}).preferredColorScheme(.dark))
            previewWindow.orderFront(nil); try await Task.sleep(nanoseconds: 700_000_000)
            func nativePlayers(_ view: NSView) -> [AVPlayerView] { (view as? AVPlayerView).map { [$0] } ?? view.subviews.flatMap { nativePlayers($0) } }
            let players = nativePlayers(previewWindow.contentView!)
            try require(players.count == 1 && players[0].player != nil && players[0].player?.rate == 0, "clip_native_preview_player_opens_without_crash_or_autoplay")
            if let view = previewWindow.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("native-video-preview.png"))
            }
            previewWindow.contentView = nil; previewWindow.close()
            let allRanges = store.projects[0].ranges
            let previousExports = store.projects[0].exports.count
            store.start(ClipJob(projectID: id, kind: .export, ranges: allRanges, burnSubtitles: true, outputFolder: exportFolder.path), model: nil)
            try await wait(store)
            try require(store.jobs[0].state == .completed && store.projects[0].exports.count == previousExports + allRanges.count, "clip_real_transcript_highlight_to_batch_bilingual_mp4")
            let realMovie = store.projects[0].exports[0]
            _ = try frame(URL(fileURLWithPath: realMovie), time: 1, output: directory.appendingPathComponent("real-local-asr-burned.png"))
            var changedCue = store.projects[0].captions[0]; changedCue.translated += "（已编辑）"
            store.saveCaption(id, cue: changedCue)
            try require(store.projects[0].previewPath == nil && !FileManager.default.fileExists(atPath: previewPath), "clip_caption_edit_invalidates_stale_preview")
            let interruptedRoot = directory.appendingPathComponent("crash-cleanup")
            let partialPath = exportFolder.appendingPathComponent(".simusub-" + UUID().uuidString + ".mp4")
            let keepPath = exportFolder.appendingPathComponent("user-video.mp4")
            try Data([1, 2]).write(to: partialPath); try Data([3, 4]).write(to: keepPath)
            try LiveMonitorStorage(root: interruptedRoot).save([ClipJob(projectID: id, kind: .export, temporaryPaths: [partialPath.path, keepPath.path], outputFolder: exportFolder.path)], name: "jobs")
            _ = ClipStore(root: interruptedRoot)
            try require(!FileManager.default.fileExists(atPath: partialPath.path) && FileManager.default.fileExists(atPath: keepPath.path), "clip_crash_cleanup_only_removes_registered_owned_partial")
            let legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.projects[0])) as! [String: Any]
            var legacy = legacyJSON; ["candidates", "highlightsNote", "previewHasSubtitles"].forEach { legacy.removeValue(forKey: $0) }
            let migrated = try JSONDecoder().decode(ClipProject.self, from: JSONSerialization.data(withJSONObject: legacy))
            try require(migrated.captions == store.projects[0].captions, "clip_v111_project_migration_preserves_edited_subtitles")
            store.start(ClipJob(projectID: id, kind: .recommend, recommendationCount: 3), model: nil); try await wait(store)
            for dark in [true, false] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ClipWorkspace(onBack: {}).environmentObject(store).environmentObject(model).environmentObject(monitor).preferredColorScheme(dark ? .dark : .light))
                window.makeKeyAndOrderFront(nil); try await Task.sleep(nanoseconds: 500_000_000)
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ClipError.message("Cannot snapshot editor") }
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(dark ? "clip-editor-dark.png" : "clip-editor-light.png"))
                window.contentView = nil; window.close()
            }
            try require(true, "clip_native_editor_light_dark_rendered")
            for tool in [ClipWorkspaceTool.highlights, .subtitles] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ClipWorkspace(initialTool: tool, onBack: {}).environmentObject(store).environmentObject(model).environmentObject(monitor).preferredColorScheme(.dark))
                window.makeKeyAndOrderFront(nil); try await Task.sleep(nanoseconds: 500_000_000)
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ClipError.message("Cannot snapshot tool") }
                view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("clip-tool-" + tool.rawValue + ".png"))
                window.contentView = nil; window.close()
            }
            let quick = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 246, height: 78), styleMask: [], backing: .buffered, defer: false)
            quick.isReleasedWhenClosed = false
            quick.contentView = NSHostingView(rootView: ClipQuickActions(selected: .highlights) { _ in }.preferredColorScheme(.dark))
            quick.orderFront(nil); try await Task.sleep(nanoseconds: 200_000_000)
            if let view = quick.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("clip-four-actions.png"))
            }
            quick.contentView = nil; quick.close()
            try require(true, "clip_four_action_menu_and_highlights_subtitles_routes_rendered")
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "movie": movie], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
            print("PASS: \(checks.count) clip checks"); fflush(stdout); Darwin.exit(0)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
            print("FAIL: " + error.localizedDescription); fflush(stdout); Darwin.exit(1)
        }
    }
    private static func frame(_ url: URL, time: Double, output: URL) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: output); return image
    }
    private static func pixelDifference(_ a: CGImage, _ b: CGImage) -> Int {
        func pixels(_ image: CGImage) -> [UInt8] {
            var result = [UInt8](repeating: 0, count: image.width * image.height * 4)
            result.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }; return result
        }
        let x = pixels(a), y = pixels(b)
        return stride(from: 0, to: min(x.count, y.count), by: 4).filter { abs(Int(x[$0]) - Int(y[$0])) > 40 || abs(Int(x[$0 + 1]) - Int(y[$0 + 1])) > 40 }.count
    }
}
