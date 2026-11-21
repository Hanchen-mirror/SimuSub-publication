import Foundation

@MainActor
enum ClipProjectTrackChecks {
    static func run(directory: URL, fixture: URL, services: ClipServices) async throws -> [String] {
        var checks: [String] = []
        func require(_ passed: Bool, _ name: String) throws {
            guard passed else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        func wait(_ store: ClipStore) async throws {
            for _ in 0..<600 where store.isBusy { try await Task.sleep(for: .milliseconds(50)) }
            guard !store.isBusy, store.jobs.first?.state == .completed else {
                throw ClipError.message(store.jobs.first?.message ?? "Missing project track job")
            }
        }
        let store = ClipStore(root: directory.appendingPathComponent("project"))
        let id = try await store.importVideo(fixture)
        let project = store.projects[0]
        let whole = project.subtitleRange
        try require(whole.id == id && whole.start == 0 && whole.end == project.media.duration && project.ranges.isEmpty,
                    "project_track_stable_target_without_export_ranges")
        // Use an actual SRT on the source clock, with cues on either side and across both cut points.
        let text = [
            "1\n00:00:01,000 --> 00:00:02,000\nBefore\n之前",
            "2\n00:00:02,500 --> 00:00:03,500\nHead\n跨头",
            "3\n00:00:04,000 --> 00:00:05,000\nMiddle\n区间内",
            "4\n00:00:05,500 --> 00:00:06,500\nTail\n跨尾",
            "5\n00:00:07,000 --> 00:00:08,000\nAfter\n之后"
        ].joined(separator: "\n\n")
        let imported = try ClipSubtitleImport.parse(text, extension: "srt", layout: .japaneseFirst,
                                                    offset: 0, duration: project.media.duration)
        var cut = ClipRange(title: "Only 3 to 6", start: 3, end: 6)
        try require(store.saveRange(id, range: cut), "project_track_saves_short_export_cut")
        try require(store.importProjectCaptions(id, captions: imported) == imported, "project_track_import_uses_project_scope")
        let loaded = store.projects[0]
        try require(loaded.captions(for: loaded.subtitleRange) == imported && loaded.ranges.count == 1
                    && loaded.captions(for: cut) == Array(imported[1...3]),
                    "project_track_absolute_import_retains_outside_and_both_crossing_cues")
        guard let inserted = store.insertSegmentCaption(id, range: loaded.subtitleRange, playhead: 8.5,
                source: .english, target: .simplifiedChinese) else { throw ClipError.message("Missing manual project cue") }
        var manual = inserted.cue; manual.original = "Manual"; manual.translated = "手动"
        try require(manual.start == 8.5 && store.saveSegmentCaption(id, rangeID: id, cue: manual),
                    "project_track_manual_insert_outside_current_cut")
        var edited = imported[0]; edited.translated = "整片内校对"
        try require(store.saveSegmentCaption(id, rangeID: id, cue: edited), "project_track_manual_edit_outside_current_cut")
        let expected = [edited] + Array(imported.dropFirst()) + [manual]
        let reimported = try ClipSubtitleImport.parse(text, extension: "srt", layout: .japaneseFirst,
                                                      offset: 0, duration: project.media.duration)
        try require(store.importProjectCaptions(id, captions: reimported) == expected,
                    "project_track_reimport_fresh_ids_preserves_manual_cues_and_corrections")
        cut.start = 4.1; cut.end = 4.9
        try require(store.saveRange(id, range: cut), "project_track_shorten_export_cut")
        try require(store.projects[0].captions(for: cut).map(\.id) == [imported[2].id]
                    && store.projects[0].captions(for: store.projects[0].subtitleRange) == expected,
                    "project_track_shrinking_cut_keeps_full_timestamps_text_and_ids")
        store.update(id) { $0.ranges.removeAll() }
        let restored = ClipStore(root: store.root)
        let saved = restored.projects[0]
        try require(saved.ranges.isEmpty && saved.captions(for: saved.subtitleRange) == expected,
                    "project_track_survives_last_range_removal_and_reopen")
        cut.start = 3; cut.end = 6
        try require(restored.saveRange(id, range: cut), "project_track_new_cut_after_reopen")
        let output = directory.appendingPathComponent("exports")
        restored.start(ClipJob(projectID: id, kind: .export, ranges: [cut], burnSubtitles: true, outputFolder: output.path), model: nil)
        try await wait(restored)
        guard let movie = restored.projects[0].exports.first else { throw ClipError.message("Missing project track export") }
        let base = URL(fileURLWithPath: movie).deletingPathExtension()
        for (ext, sep) in [("srt", ","), ("vtt", ".")] {
            let sidecar = try String(contentsOf: base.appendingPathExtension(ext), encoding: .utf8)
            try require(sidecar.contains("00:00:00\(sep)000 --> 00:00:00\(sep)500")
                        && sidecar.contains("00:00:01\(sep)000 --> 00:00:02\(sep)000")
                        && sidecar.contains("00:00:02\(sep)500 --> 00:00:03\(sep)000")
                        && ["Head", "Middle", "Tail"].allSatisfy { sidecar.contains($0) }
                        && !["Before", "After", "Manual"].contains { sidecar.contains($0) },
                        "project_track_\(ext)_intersects_both_edges_and_rebases_to_zero")
        }
        try require(restored.projects[0].captions(for: restored.projects[0].subtitleRange) == expected,
                    "project_track_export_keeps_source_clock_and_edits")

        // No export ranges at all: generating subtitles must target the project clock.
        let generated = ClipStore(root: directory.appendingPathComponent("generated"))
        let generatedID = try await generated.importVideo(fixture)
        let full = generated.projects[0].subtitleRange
        generated.start(ClipJob(projectID: generatedID, kind: .transcribe, range: full,
                                configuredServices: true, generationServiceKey: "qa.project-track"),
                        model: nil, services: services)
        try await wait(generated)
        let generatedAgain = ClipStore(root: generated.root).projects[0]
        let generation = generatedAgain.subtitleRange.generation
        try require(generatedAgain.ranges.isEmpty && generation?.complete == true
                    && generation?.span == (0...project.media.duration) && generation?.captions.isEmpty == false
                    && generatedAgain.captions(for: generatedAgain.subtitleRange).contains { !$0.translated.isEmpty },
                    "project_track_generates_and_reloads_without_creating_export_range")

        // Simulate a pre-project-track library saved by an older build, including duplicate imports.
        let legacy = ClipStore(root: directory.appendingPathComponent("legacy"))
        let legacyID = try await legacy.importVideo(fixture)
        var first = ClipRange(title: "Earlier", start: 1, end: 4)
        var second = ClipRange(title: "Later", start: 3, end: 6)
        var duplicate = imported[0]; duplicate.id = UUID()
        first.importedCaptions = [imported[0], imported[2], imported[4]]
        second.importedCaptions = [duplicate]
        var earlierEdit = imported[2]; earlierEdit.translated = "旧改"
        var laterEdit = earlierEdit; laterEdit.translated = "后改"
        first.captionEdits = [earlierEdit]; second.captionEdits = [laterEdit]
        first.deletedCaptionIDs = [laterEdit.id]; second.deletedCaptionIDs = [imported[4].id]
        legacy.update(legacyID) { $0.ranges = [first, second] }
        let migrated = ClipStore(root: legacy.root)
        let oldProject = migrated.projects[0]
        let migratedCues = oldProject.captions(for: oldProject.subtitleRange)
        try require(migratedCues.count == 2 && migratedCues.contains(imported[0]) && migratedCues.contains(laterEdit)
                    && oldProject.ranges == [first, second],
                    "project_track_legacy_dedup_later_edit_wins_and_original_range_records_survive")
        migrated.update(legacyID) { $0.ranges.removeAll() }
        let reopened = ClipStore(root: legacy.root).projects[0]
        try require(reopened.captions(for: reopened.subtitleRange) == migratedCues,
                    "project_track_migration_survives_removing_legacy_ranges")
        return checks
    }
}
