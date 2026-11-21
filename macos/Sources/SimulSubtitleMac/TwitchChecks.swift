import Foundation

private actor TwitchReconnectFixture: LivePlatformServing {
    let root: URL
    var attempts = 0
    init(root: URL) { self.root = root }
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] { [] }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate {
        .init(platform: platform, address: input, name: "Twitch Fixture")
    }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot {
        .init(state: attempts < 5 ? .live : .offline)
    }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        attempts += 1
        let mode = attempts < 5 ? "cycle" : "flaky"
        let url = root.appendingPathComponent(mode + "-" + UUID().uuidString + "/live.m3u8")
        return .init(tracks: [.init(url: url, headers: [:], hasVideo: true, hasAudio: true)], title: "Twitch Fixture", twitchHLS: true)
    }
}

@MainActor
enum TwitchChecks {
    static func run(directory: URL) async throws {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw LiveMonitorError.unavailable("Twitch CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: twitch_" + name)
        }
        let base = URL(string: "https://video.example/live.m3u8")!
        let header = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:42\n#EXT-X-TARGETDURATION:2\n"
        let range = "#EXT-X-DATERANGE:ID=\"stitched-ad-test\",CLASS=\"twitch-stitched-ad\",START-DATE=\"2026-11-03T12:00:00Z\",DURATION=2\n"
        let timeline = "#EXT-X-PROGRAM-DATE-TIME:2026-11-03T12:00:00Z\n#EXTINF:2,live\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:2,live\nb.ts\n"
        let parsed = try TwitchPlaylist(header + range + timeline, base: base)
        try require(parsed.segments.map(\.advertisement) == [true, false], "daterange_ends_at_boundary")
        try require(parsed.segments.map(\.sequence) == [42, 43] && parsed.segments[1].discontinuity, "sequence_and_discontinuity")
        try require(parsed.segments[0].url.absoluteString == "https://video.example/a.ts", "relative_segment_url")
        let zero = try TwitchPlaylist(header + range.replacingOccurrences(of: "DURATION=2", with: "DURATION=0,PLANNED-DURATION=60") + timeline, base: base)
        try require(zero.segments.allSatisfy { !$0.advertisement }, "explicit_zero_not_open_ended")
        let title = try TwitchPlaylist(header + "#EXTINF:2,Amazon|fixture\na.ts\n", base: base)
        try require(title.segments[0].advertisement, "amazon_title")
        let expired = try TwitchPlaylist(header + range + timeline.replacingOccurrences(of: "12:00:00Z", with: "12:00:30.500Z"), base: base)
        try require(expired.segments.allSatisfy { !$0.advertisement }, "stale_ad_range_does_not_hide_content")
        let future = try TwitchPlaylist(header + range.replacingOccurrences(of: "12:00:00Z", with: "12:01:00Z") + timeline, base: base)
        try require(future.segments.allSatisfy { !$0.advertisement }, "future_ad_does_not_hide_content")
        let endDate = try TwitchPlaylist(header + range.replacingOccurrences(of: "DURATION=2", with: "END-DATE=\"2026-11-03T12:00:02Z\"") + timeline, base: base)
        try require(endDate.segments.map(\.advertisement) == [true, false], "explicit_end_date")
        for tag in ["#EXT-X-GAP", "#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", "#EXT-X-MAP:URI=\"init.mp4\""] {
            try require((try? TwitchPlaylist(header + tag + "\n" + timeline, base: base)) == nil, "reject_unsupported_" + String(checks.count))
        }
        try require((try? TwitchPlaylist(header + "#EXTINF:2,live\nfile:///etc/passwd\n", base: base)) == nil, "reject_remote_local_file")
        if let i = CommandLine.arguments.firstIndex(of: "--twitch-fixture"), i + 1 < CommandLine.arguments.count,
           let fixture = URL(string: CommandLine.arguments[i + 1]), fixture.host == "127.0.0.1" {
            let runID = UUID().uuidString
            let spoolRoot = directory.appendingPathComponent("spools")
            func input(_ mode: String) -> ResolvedLiveInput {
                .init(tracks: [.init(url: fixture.appendingPathComponent(mode + "-" + runID + "/live.m3u8"), headers: [:], hasVideo: true, hasAudio: true)], title: "Fixture", twitchHLS: true)
            }
            let output = directory.appendingPathComponent("twitch-recovery.mkv")
            var states: [TwitchContentState] = []
            let result = try await TwitchRecordingJob(temporaryRoot: spoolRoot).run(input("recovery"), output: output, maximumSeconds: 25, segmentSeconds: nil) { states.append($0) }
            try require(result.status == 0, "recovery_mux_success")
            try require(states.filter { $0 == .advertisement }.count == 2 && states.last == .recording, "preroll_midroll_recovery")
            let probe = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-show_entries", "format=duration:stream=codec_type", "-of", "json", output.path])
            let json = try JSONSerialization.jsonObject(with: probe.data) as! [String: Any]
            let duration = Double((json["format"] as? [String: Any])?["duration"] as? String ?? "0") ?? 0
            let tracks = json["streams"] as? [[String: Any]] ?? []
            try require(duration > 10 && tracks.contains { $0["codec_type"] as? String == "audio" }, "recovered_real_av_media")
            let decode = try await LiveTools.run("ffmpeg", arguments: ["-v", "error", "-i", output.path, "-vf", "scale=160:-1", "-c:v", "png", "-c:a", "pcm_s16le", "-f", "null", "/dev/null"], timeout: 15)
            try require(decode.status == 0, "recovery_full_decode")
            let pattern = directory.appendingPathComponent("twitch-segment-%06d.mp4")
            let segmented = try await TwitchRecordingJob(temporaryRoot: spoolRoot).run(input("recoverymp4"), output: pattern, maximumSeconds: 25, segmentSeconds: 4) { _ in }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("twitch-segment-") && $0.pathExtension == "mp4" }
            try require(segmented.status == 0 && files.count >= 3, "fragmented_mp4_segments_survive_ad_recovery")
            for file in files {
                let decoded = try await LiveTools.run("ffmpeg", arguments: ["-v", "error", "-i", file.path, "-vf", "scale=160:-1", "-c:v", "png", "-c:a", "pcm_s16le", "-f", "null", "/dev/null"], timeout: 15)
                try require(decoded.status == 0, "mp4_decode_" + file.lastPathComponent)
            }
            let flaky = directory.appendingPathComponent("flaky.mkv")
            let flakyResult = try await TwitchRecordingJob(temporaryRoot: spoolRoot).run(input("flaky"), output: flaky, maximumSeconds: 20, segmentSeconds: nil) { _ in }
            let flakyMedia = try await ClipMediaEngine.inspect(flaky)
            try require(flakyResult.status == 0 && abs(flakyMedia.duration - 10) < 0.2 && flakyMedia.hasAudio, "transient_manifest_and_segment_503_without_lost_or_duplicate_media")
            let outage = directory.appendingPathComponent("outage-%06d.mkv")
            var outageFailed = false
            do {
                _ = try await TwitchRecordingJob(temporaryRoot: spoolRoot).run(input("outage"), output: outage, maximumSeconds: 20) { _ in }
            } catch { outageFailed = error.localizedDescription.contains("503") }
            let part = directory.appendingPathComponent("outage-000000.mkv")
            let outageMedia = try await ClipMediaEngine.inspect(part)
            let csv = try String(contentsOf: outage.deletingPathExtension().appendingPathExtension("csv"), encoding: .utf8)
            try require(outageFailed && csv.contains(part.lastPathComponent) && outageMedia.hasAudio && abs(outageMedia.duration - 6) < 0.2, "permanent_failure_flushes_all_received_media")
            let interrupted = directory.appendingPathComponent("unclean-000000.mkv")
            let raw = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-n", "-i", part.path, "-map", "0", "-c", "copy", "-live", "1", interrupted.path])
            let rawProbe = try await ClipMediaEngine.probe(interrupted)
            try require(raw.status == 0 && rawProbe.format?.duration == nil, "unfinalized_fixture_written")
            let tail = try FileHandle(forWritingTo: interrupted)
            let length = try tail.seekToEnd()
            try tail.truncate(atOffset: length - 128)
            try tail.close()
            try await TwitchRecordingJob.finalizeMKV(output: directory.appendingPathComponent("unclean-%06d.mkv"), segmented: true)
            let repaired = try await ClipMediaEngine.inspect(interrupted)
            try require(repaired.hasAudio && abs(repaired.duration - outageMedia.duration) < 0.2, "unfinalized_mkv_remuxed_and_indexed")
            for mode in ["allads", "stale", "failure"] {
                var failed = false
                do { _ = try await TwitchRecordingJob(advertisementTimeout: 3, stallTimeout: 3, temporaryRoot: spoolRoot).run(input(mode), output: directory.appendingPathComponent(mode + ".mkv"), maximumSeconds: 12, segmentSeconds: nil) { _ in } }
                catch { failed = true }
                try require(failed, mode + "_fails_explicitly")
            }
            let service = TwitchReconnectFixture(root: fixture)
            let store = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("cycle-store")), service: service, notificationsEnabled: false)
            store.updateSettings { $0.outputFolder = directory.appendingPathComponent("cycle-recordings").path }
            store.follow(.init(platform: .twitch, address: "fixture", name: "Fixture"))
            let creatorID = store.creators[0].id
            store.applySnapshot(.init(state: .live, sessionID: "fixture"), to: creatorID)
            store.startRecording(creatorID)
            for _ in 0..<900 {
                if !store.hasActiveRecordings { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let attempts = await service.attempts
            let saved = store.recordings.first
            try require(attempts == 5 && saved?.state == .completed && saved?.closedMediaURLs.count == 5, "store_recovers_four_separate_interruptions")
            for file in saved?.closedMediaURLs ?? [] {
                let media = try await ClipMediaEngine.inspect(file)
                try require(media.hasAudio && media.duration >= 9.9, "reconnected_playable_" + file.lastPathComponent)
            }
            await store.shutdown()
            let job = TwitchRecordingJob(temporaryRoot: spoolRoot), cancelledOutput = directory.appendingPathComponent("cancelads.mkv")
            let start = Date()
            let task = Task { try await job.run(input("cancelads"), output: cancelledOutput, maximumSeconds: 60, segmentSeconds: nil) { _ in } }
            try await Task.sleep(nanoseconds: 700_000_000); job.requestStop()
            _ = try await task.value
            try require(Date().timeIntervalSince(start) < 4 && !FileManager.default.fileExists(atPath: cancelledOutput.path), "stop_during_ad_no_fake_video")
            let remainingSpools = try FileManager.default.contentsOfDirectory(atPath: spoolRoot.path)
            try require(remainingSpools.isEmpty, "all_exit_paths_remove_spool")
            let log = try String(contentsOf: directory.appendingPathComponent("twitch-recovery.twitch.jsonl"), encoding: .utf8)
            try require(log.contains("unavailableSeconds") && !log.contains("http"), "gap_audit_without_remote_urls")
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("twitch-checks.json"))
    }
}
