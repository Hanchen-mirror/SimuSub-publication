import Foundation

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
            for mode in ["allads", "stale", "failure"] {
                var failed = false
                do { _ = try await TwitchRecordingJob(advertisementTimeout: 3, stallTimeout: 3, temporaryRoot: spoolRoot).run(input(mode), output: directory.appendingPathComponent(mode + ".mkv"), maximumSeconds: 12, segmentSeconds: nil) { _ in } }
                catch { failed = true }
                try require(failed, mode + "_fails_explicitly")
            }
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
