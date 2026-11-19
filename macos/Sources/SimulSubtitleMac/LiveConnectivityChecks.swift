import Foundation

@MainActor
enum LiveConnectivityChecks {
    static func run(directory: URL) async throws {
        let args = CommandLine.arguments
        guard let p = args.firstIndex(of: "--connectivity-platform"), p + 1 < args.count,
              let platform = LivePlatform(rawValue: args[p + 1]),
              let u = args.firstIndex(of: "--connectivity-url"), u + 1 < args.count else { throw LiveMonitorError.invalidResponse }
        let address = try LiveAddress.normalize(args[u + 1], platform: platform)
        let seconds: Double = {
            guard let i = args.firstIndex(of: "--connectivity-seconds"), i + 1 < args.count else { return 120 }
            return min(600, max(10, Double(args[i + 1]) ?? 120))
        }()
        let service = LivePlatformService(cacheRoot: directory.appendingPathComponent("stream-cache"))
        let access = LivePlatformAccess()
        var creator = WatchedCreator(.init(platform: platform, address: address, name: platform.title))
        var report: [String: Any] = ["platform": platform.rawValue, "address": address, "requestedSeconds": seconds,
                                   "startedAt": ISO8601DateFormatter().string(from: Date()), "passed": false]
        do {
            let statusStart = Date()
            if platform == .youtube && address.contains("/watch?") {
                // The exact supplied broadcast is verified by browserMedia's isLiveNow.
                creator.snapshot = .init(state: .live, liveURL: address)
            } else {
                creator.snapshot = try await service.status(creator, access: access)
                report["statusSeconds"] = Date().timeIntervalSince(statusStart)
                guard creator.snapshot.state == .live else { throw LiveExtractionError.offline }
            }
            let resolveStart = Date()
            let input = try await service.recordingInput(creator, access: access)
            report["resolveSeconds"] = Date().timeIntervalSince(resolveStart)
            let start = Date()
            var firstFrame: Double?
            let file: URL
            let result: LiveToolOutput
            if let capture = input.browserCapture {
                report["route"] = "browser capture"
                var saved: URL?
                let job = BrowserCaptureJob()
                result = try await job.run(capture, folder: directory, prefix: "sample-", container: "mp4", maximumSeconds: seconds) { url in
                    if firstFrame == nil { firstFrame = Date().timeIntervalSince(start) }
                    saved = url
                }
                guard let saved else { throw LiveMonitorError.unavailable("No browser frames saved") }
                file = saved
            } else if input.twitchHLS {
                report["route"] = "Twitch content-aware stream copy"
                file = directory.appendingPathComponent("sample.mkv")
                let job = TwitchRecordingJob()
                var states: [[String: Any]] = []
                result = try await withTaskCancellationHandler {
                    try await job.run(input, output: file, maximumSeconds: seconds, segmentSeconds: nil) { state in
                        let elapsed = Date().timeIntervalSince(start)
                        states.append(["state": state.rawValue, "elapsedSeconds": elapsed])
                        if state == .recording && firstFrame == nil { firstFrame = elapsed }
                    }
                } onCancel: { job.cancel() }
                report["contentStates"] = states
                report["contentReview"] = "Manual frame review required; media structure alone is not content validation."
            } else {
                report["route"] = "native stream copy"
                report["hosts"] = input.tracks.compactMap { $0.url.host }
                file = directory.appendingPathComponent("sample.mkv")
                let progressURL = directory.appendingPathComponent("sample.progress")
                let progress = LiveRecordingProgress()
                let watcher = Task {
                    while !Task.isCancelled {
                        if progress.poll(progressURL) { firstFrame = Date().timeIntervalSince(start); return }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                defer { watcher.cancel() }
                var command = try LiveRecordingEngine.arguments(input: input, output: file, progressURL: progressURL)
                command.insert(contentsOf: ["-t", String(seconds)], at: command.count - 1)
                result = try await LiveTools.run("ffmpeg", arguments: command, timeout: seconds + 35)
            }
            report["recordWallSeconds"] = Date().timeIntervalSince(start)
            report["firstFrameSeconds"] = firstFrame
            report["exitStatus"] = result.status
            report["file"] = file.path
            if !result.error.isEmpty { report["streamWarning"] = LiveRecordingEngine.failureMessage(result.error) }
            let probe = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height,avg_frame_rate", "-of", "json", file.path], timeout: 15)
            let media = try JSONSerialization.jsonObject(with: probe.data) as? [String: Any] ?? [:]
            report["media"] = media
            let streams = media["streams"] as? [[String: Any]] ?? []
            let format = media["format"] as? [String: Any] ?? [:]
            let duration = Double(format["duration"] as? String ?? "0") ?? 0
            report["transportPassed"] = result.status == 0 && duration >= (input.twitchHLS ? 1 : seconds - 8)
                && streams.contains { $0["codec_type"] as? String == "video" }
                && streams.contains { $0["codec_type"] as? String == "audio" }
            report["passed"] = report["transportPassed"]
        } catch { report["error"] = error.localizedDescription }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        if report["passed"] as? Bool != true { throw LiveMonitorError.unavailable(report["error"] as? String ?? "Connectivity recording validation failed") }
    }
}
