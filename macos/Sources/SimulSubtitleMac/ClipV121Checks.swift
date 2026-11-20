import AppKit

@MainActor
enum ClipV121Checks {
    static func run(fixture: URL, directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ ok: Bool, _ name: String) throws {
            guard ok else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func wait(_ store: ClipStore) async throws {
            for _ in 0..<2400 {
                if !store.isBusy { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            store.cancel(); throw ClipError.message("v121 job timeout")
        }
        let root = directory.appendingPathComponent("v121")
        let folder = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Inject a real Foundation disk error at the file boundary, after the MP4
        // and SRT have been saved. No changes to the user's disk or permissions.
        let store = ClipStore(root: root.appendingPathComponent("store"), writeSubtitle: { text, url in
            if url.pathExtension == "vtt" { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
            try text.write(to: url, atomically: true, encoding: .utf8)
        })
        let id = try await store.importVideo(fixture)
        var range = ClipRange(title: "恢复检查", start: 1, end: 5)
        let cue = Caption(start: 1.2, end: 2.5, original: "今日は楽しい。", translated: "今天很开心。")
        store.update(id) { $0.ranges = [range]; $0.captions = [cue] }
        store.start(ClipJob(projectID: id, kind: .export, ranges: [range], burnSubtitles: true, outputFolder: folder.path), model: nil)
        try await wait(store)
        let failed = store.jobs[0]
        try require(failed.state == .failed && failed.message.contains("视频已保存") && failed.message.contains("CLIP-DISK-FULL"), "v121_sidecar_disk_failure_reports_saved_video_and_cause")
        let receipt = failed.exportReceipts!.first!
        let movie = URL(fileURLWithPath: receipt.mediaPath)
        let before = try Data(contentsOf: movie)
        try require(receipt.completedSidecars == ["srt"] && failed.completedRanges?.isEmpty == true, "v121_partial_export_tracks_srt_separately_not_completed")
        let restored = ClipStore(root: root.appendingPathComponent("store"))
        restored.start(restored.jobs[0], model: nil); try await wait(restored)
        try require(restored.jobs[0].state == .completed && restored.projects[0].exports.count == 1, "v121_retry_after_restart_reuses_saved_movie_without_duplicate")
        let after = try Data(contentsOf: movie)
        try require(before == after && FileManager.default.fileExists(atPath: movie.deletingPathExtension().appendingPathExtension("vtt").path), "v121_retry_backfills_missing_vtt_preserves_movie_bytes")
        let srt = movie.deletingPathExtension().appendingPathExtension("srt")
        try FileManager.default.removeItem(at: srt)
        restored.start(restored.jobs[0], model: nil); try await wait(restored)
        try require(restored.jobs[0].state == .completed && restored.projects[0].exports.count == 1 && FileManager.default.fileExists(atPath: srt.path), "v121_retry_rechecks_missing_sidecar_even_if_previously_complete")
        // Create another partial export, edit saved bounds and translation, retry.
        store.start(ClipJob(projectID: id, kind: .export, ranges: [range], burnSubtitles: false, outputFolder: folder.path), model: nil)
        try await wait(store)
        try require(store.jobs[0].state == .failed, "v121_second_partial_export_fault_injected")
        let edited = ClipStore(root: root.appendingPathComponent("store"))
        let oldJob = edited.jobs[0]
        range.end = 3; range.title = "修正后的选段"
        edited.saveRange(id, range: range)
        var changed = cue; changed.translated = "改好的中文字幕"
        try require(edited.saveSegmentCaption(id, rangeID: range.id, cue: changed), "v121_save_changed_cue_before_retry")
        edited.start(oldJob, model: nil); try await wait(edited)
        let latest = edited.jobs[0]
        let newMovie = URL(fileURLWithPath: edited.projects[0].exports[0])
        let info = try await ClipMediaEngine.inspect(newMovie)
        let text = try String(contentsOf: newMovie.deletingPathExtension().appendingPathExtension("srt"), encoding: .utf8)
        try require(latest.state == .completed && latest.ranges[0].end == 3 && abs(info.duration - 2) < 0.15 && text.contains(changed.translated), "v121_retry_uses_updated_saved_bounds_and_captions_together")
        try require(newMovie.path != oldJob.exportReceipts?.first?.mediaPath && FileManager.default.fileExists(atPath: oldJob.exportReceipts!.first!.mediaPath), "v121_changed_content_gets_new_movie_preserves_previous_export")
        // Deleted media invalidates its receipt, even when the ID was completed.
        try FileManager.default.removeItem(at: newMovie)
        edited.start(latest, model: nil); try await wait(edited)
        try require(edited.jobs[0].state == .completed && edited.projects[0].exports[0] != newMovie.path && FileManager.default.fileExists(atPath: edited.projects[0].exports[0]), "v121_missing_completed_movie_is_regenerated")
        let stale = edited.jobs[0]
        edited.update(id) { $0.ranges = [] }
        let jobCount = edited.jobs.count
        edited.start(stale, model: nil)
        try require(!edited.isBusy && edited.jobs.count == jobCount && edited.notice?.contains("已移除") == true, "v121_retry_deleted_range_has_explicit_recovery_message")
        edited.update(id) { $0.ranges = [range] }
        // Failed apply must retain the proposal; successful apply consumes it.
        var proposal = changed; proposal.end = 4
        edited.update(id) { $0.ranges[0].proofreadCandidates = [proposal] }
        try require(!edited.applyProofread(id, rangeID: range.id, cue: proposal) && edited.projects[0].ranges[0].proofreadCandidates?.count == 1, "v121_out_of_bounds_proposal_is_retained_when_save_fails")
        proposal.end = 2.5; proposal.translated = "已成功应用的建议"
        edited.update(id) { $0.ranges[0].proofreadCandidates = [proposal] }
        try require(edited.applyProofread(id, rangeID: range.id, cue: proposal) && edited.projects[0].ranges[0].proofreadCandidates?.isEmpty == true && edited.projects[0].captions(for: edited.projects[0].ranges[0])[0].translated == proposal.translated, "v121_successful_proposal_apply_updates_caption_and_consumes_suggestion")
        var overlap = Caption(start: 2.6, end: 2.9, original: "次", translated: "下一句")
        try require(edited.saveSegmentCaption(id, rangeID: range.id, cue: overlap), "v121_overlap_fixture_saved")
        overlap.start = 2.4
        edited.update(id) { $0.ranges[0].proofreadCandidates = [overlap] }
        try require(!edited.applyProofread(id, rangeID: range.id, cue: overlap) && edited.projects[0].ranges[0].proofreadCandidates?.count == 1, "v121_overlapping_proposal_is_retained_when_save_fails")
        // Error mapping does not expose raw stderr paths or secrets.
        let denied = ClipFailure.tool("Permission denied /private/secret?token=secret", operation: "读取视频").localizedDescription
        try require(denied.contains("CLIP-PERMISSION") && !denied.contains("secret"), "v121_permission_error_is_actionable_and_redacted")
        try require(ClipFailure.tool("moov atom not found", operation: "读取视频").localizedDescription.contains("CLIP-MEDIA"), "v121_corrupt_media_has_distinct_error")
        let missing = root.appendingPathComponent("missing.mp4")
        do { _ = try await ClipMediaEngine.inspect(missing); throw ClipError.message("missing file unexpectedly opened") }
        catch { try require(error.localizedDescription.contains("CLIP-NOT-FOUND"), "v121_missing_source_error_reproduced") }
        let corrupt = root.appendingPathComponent("corrupt.mp4")
        try Data("not a video".utf8).write(to: corrupt)
        do { _ = try await ClipMediaEngine.inspect(corrupt); throw ClipError.message("corrupt file unexpectedly opened") }
        catch { try require(error.localizedDescription.contains("CLIP-MEDIA"), "v121_corrupt_source_error_reproduced") }
        // Pre-v1.21 jobs decode without receipts; do not falsely trust legacy IDs.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latest)) as! [String: Any]
        legacy.removeValue(forKey: "exportReceipts")
        let decoded = try JSONDecoder().decode(ClipJob.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(decoded.exportReceipts == nil, "v121_legacy_jobs_decode_without_receipts")
        let deniedStore = ClipStore(root: root.appendingPathComponent("permission-store"), writeSubtitle: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        })
        let deniedID = try await deniedStore.importVideo(fixture)
        deniedStore.update(deniedID) { $0.ranges = [range]; $0.captions = [cue] }
        deniedStore.start(ClipJob(projectID: deniedID, kind: .export, ranges: [range], burnSubtitles: false, outputFolder: folder.path), model: nil)
        try await wait(deniedStore)
        try require(deniedStore.jobs[0].state == .failed && deniedStore.jobs[0].message.contains("CLIP-PERMISSION") && deniedStore.jobs[0].message.contains("视频已保存"), "v121_sidecar_permission_failure_preserves_movie_with_clear_error")
        let allowed = ClipStore(root: root.appendingPathComponent("permission-store"))
        allowed.start(allowed.jobs[0], model: nil); try await wait(allowed)
        try require(allowed.jobs[0].state == .completed && allowed.projects[0].exports.count == 1, "v121_permission_recovery_backfills_both_sidecars_without_duplicate")
        var blank = range; blank.id = UUID(); blank.title = "缺少中文"; blank.subtitleStyle = .classic; blank.subtitleStyle?.mode = .chinese
        blank.importedCaptions = [Caption(start: 1.2, end: 2.5, original: "日本語", translated: "")]
        allowed.update(deniedID) { $0.ranges.append(blank) }
        var translationOnly = blank
        translationOnly.importedCaptions = [Caption(start: 1.2, end: 2.5, original: "", translated: "测试")]
        translationOnly.subtitleStyle?.mode = .bilingual
        try require(!allowed.projects[0].hasBurnableCaptions(for: translationOnly), "export_sheet_blocks_bilingual_burn_with_only_translation")
        translationOnly.subtitleStyle?.mode = .chinese
        try require(allowed.projects[0].hasBurnableCaptions(for: translationOnly), "export_sheet_allows_translation_only_burn_with_translation")
        let exportsBefore = allowed.projects[0].exports.count
        allowed.start(ClipJob(projectID: deniedID, kind: .export, ranges: [range, blank], burnSubtitles: true, outputFolder: folder.path), model: nil)
        try await wait(allowed)
        try require(allowed.jobs[0].state == .failed && allowed.jobs[0].message.contains("纯中文") && !allowed.jobs[0].message.contains("双语") && allowed.projects[0].exports.count == exportsBefore, "v121_batch_preflight_reports_actual_language_before_any_export")
        return checks
    }
}
