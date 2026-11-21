import Foundation

/// Twitch advert metadata, rather than the existence of an A/V track, decides
/// whether a segment can be offered to the recorder. Persistent logs omit remote URLs.
struct TwitchPlaylist: Sendable {
    struct Segment: Sendable {
        let sequence: Int
        let url: URL
        let duration: Double
        let advertisement: Bool
        let discontinuity: Bool
    }
    let segments: [Segment]
    let targetDuration: Double
    let ended: Bool

    static func attributes(_ text: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#)
        let ns = text as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2))
        }
        return result
    }
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    init(_ text: String, base: URL) throws {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U", text.utf8.count <= 1_048_576 else { throw LiveMonitorError.invalidResponse }
        let ranges = lines.filter { $0.hasPrefix("#EXT-X-DATERANGE:") }.map(Self.attributes).filter {
            $0["CLASS"] == "twitch-stitched-ad" || ($0["ID"] ?? "").hasPrefix("stitched-ad-")
        }
        var sequence = 0, target: Double = 2, duration: Double?, title = "", time: Date?, discontinuity = false
        var parsed: [Segment] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int(line.dropFirst(22)) ?? 0 }
            else if line.hasPrefix("#EXT-X-TARGETDURATION:") { target = Double(line.dropFirst(22)) ?? 2 }
            else if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") { time = Self.date(String(line.dropFirst(25))) }
            else if line.hasPrefix("#EXTINF:") {
                let parts = line.dropFirst(8).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                duration = Double(parts.first ?? ""); title = parts.count > 1 ? String(parts[1]) : ""
            } else if line == "#EXT-X-DISCONTINUITY" { discontinuity = true }
            else if line.hasPrefix("#EXT-X-MAP:") || line.hasPrefix("#EXT-X-BYTERANGE:") || line == "#EXT-X-GAP"
                        || (line.hasPrefix("#EXT-X-KEY:") && Self.attributes(line)["METHOD"] != "NONE") {
                throw LiveMonitorError.unavailable("Twitch 返回了暂不支持或缺失的媒体分片，正在重新连接。")
            } else if !line.isEmpty && !line.hasPrefix("#"), let seconds = duration {
                guard seconds.isFinite, seconds > 0, seconds <= 60,
                      let url = URL(string: line, relativeTo: base)?.absoluteURL,
                      url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1"),
                      url.user == nil, url.password == nil else { throw LiveMonitorError.invalidResponse }
                let ad = title.contains("Amazon") || ranges.contains { range in
                    guard let start = Self.date(range["START-DATE"]), let time else { return true }
                    // Explicit zero duration is not an open-ended ad (Streamlink #7074).
                    let length = range["DURATION"].flatMap(Double.init) ?? range["PLANNED-DURATION"].flatMap(Double.init)
                    let end = Self.date(range["END-DATE"]) ?? length.map { start.addingTimeInterval(max(0, $0)) }
                    return time >= start && (end == nil || time < end!)
                }
                parsed.append(.init(sequence: sequence, url: url, duration: seconds, advertisement: ad, discontinuity: discontinuity))
                sequence += 1; time = time?.addingTimeInterval(seconds); duration = nil; discontinuity = false
            }
        }
        guard !parsed.isEmpty, target.isFinite, target > 0, target <= 60 else { throw LiveMonitorError.invalidResponse }
        segments = parsed; targetDuration = target; ended = lines.contains("#EXT-X-ENDLIST")
    }
}

enum TwitchContentState: String, Sendable {
    case advertisement, receiving, recording
    var message: String {
        switch self {
        case .advertisement: return "Twitch 广告占位中，未取得这段主播画面；等待恢复。"
        case .receiving: return "已收到非广告分片，正在等待可保存的画面。"
        case .recording: return "正在保存 Twitch 非广告直播流；广告缺口记录在录像目录中。"
        }
    }
}

/// A bounded local HLS spool keeps FFmpeg away from advert segments. Polling
/// continues during ads; an ad does not consume the store's reconnect budget.
/// Files contain local names only, and the spool is removed on every exit path.
final class TwitchRecordingJob: LiveRecordingControl, @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var workerFinished = false
    private var downloadedSeconds = 0.0
    private var verifiedVideo = false
    var sustainedRecording: Bool { lock.withLock { verifiedVideo && downloadedSeconds >= 30 } }
    private let process = LiveToolProcess()
    private let session: URLSession
    private let advertisementTimeout: Double
    private let stallTimeout: Double
    private let temporaryRoot: URL
    init(session: URLSession? = nil, advertisementTimeout: Double = 360, stallTimeout: Double = 30, temporaryRoot: URL? = nil) {
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
        self.advertisementTimeout = advertisementTimeout; self.stallTimeout = stallTimeout
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
        self.session = session ?? URLSession(configuration: config)
    }
    func requestStop() { lock.withLock { stopping = true } }
    func cancel() { requestStop() }
    private var shouldStop: Bool { lock.withLock { stopping } }
    private func markFinished() { lock.withLock { workerFinished = true } }

    /// Only the last segment can still be open after FFmpeg exits. Validate
    /// a replacement before publishing it at the path used by recording history.
    static func finalizeMKV(output: URL, segmented: Bool) async throws {
        guard output.pathExtension == "mkv" else { return }
        let folder = output.deletingLastPathComponent()
        var file = output
        if segmented {
            let pattern = output.lastPathComponent
            let candidates = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { url in
                    guard let number = url.deletingPathExtension().lastPathComponent.split(separator: "-").last,
                          number.count == 6, number.allSatisfy(\.isNumber) else { return false }
                    return url.lastPathComponent == pattern.replacingOccurrences(of: "%06d", with: number)
                }
            guard let last = candidates.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }
            file = last
        }
        guard LiveRecordingEngine.fileSize(file.path) > 0 else { return }
        let probe = try await ClipMediaEngine.probe(file)
        if let duration = Double(probe.format?.duration ?? ""), duration.isFinite, duration > 0 { return }
        let temporary = folder.appendingPathComponent(".finalize-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let mux = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-n", "-protocol_whitelist", "file",
            "-i", file.path, "-map", "0", "-c", "copy", "-f", "matroska", temporary.path], timeout: 600)
        guard mux.status == 0 else { throw LiveMonitorError.unavailable("录像封装修复失败，原分段已保留。") }
        let media = try await ClipMediaEngine.inspect(temporary)
        guard media.hasAudio == probe.streams.contains(where: { $0.codec_type == "audio" }) else {
            throw LiveMonitorError.unavailable("录像音轨校验失败，原分段已保留。")
        }
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    }

    func run(_ input: ResolvedLiveInput, output: URL, maximumSeconds: Double, segmentSeconds: Int? = 300,
             onState: @escaping @MainActor @Sendable (TwitchContentState) -> Void) async throws -> LiveToolOutput {
        guard input.twitchHLS, let track = input.tracks.first else { throw LiveMonitorError.invalidResponse }
        let spool = temporaryRoot.appendingPathComponent("SimuSub-Twitch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let playlist = spool.appendingPathComponent("stream.m3u8"), progressURL = spool.appendingPathComponent("progress")
        let events = output.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "%06d", with: "events") + ".twitch.jsonl")
        let progress = LiveRecordingProgress(), start = Date(), deadline = Date().addingTimeInterval(maximumSeconds)
        var worker: Task<LiveToolOutput, Error>?
        var lastState: TwitchContentState?, lastSequence: Int?, lastAdvance = Date(), adSince: Date?, firstContent: Date?
        var contentCount = 0, discontinuityCount = 0, pendingDiscontinuity = false
        var endReason = "stopped"
        var entries: [(number: Int, duration: Double, discontinuity: Bool)] = []
        var retained: [Int] = []
        func log(_ fields: [String: Any]) throws {
            var row = fields
            row["at"] = ISO8601DateFormatter().string(from: Date())
            row["elapsedSeconds"] = Date().timeIntervalSince(start)
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
            if !FileManager.default.fileExists(atPath: events.path) { FileManager.default.createFile(atPath: events.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: events); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        func event(_ state: TwitchContentState, seconds: Double? = nil) async throws {
            guard state != lastState else { return }
            lastState = state
            var fields: [String: Any] = ["state": state.rawValue]
            if let seconds { fields["unavailableSeconds"] = seconds }
            try log(fields)
            await onState(state)
        }
        func publish(ended: Bool = false) throws {
            guard !entries.isEmpty else { return }
            var text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(ceil(entries.map(\.duration).max() ?? 2)))\n#EXT-X-MEDIA-SEQUENCE:\(entries[0].number)\n#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuityCount)\n"
            for e in entries {
                if e.discontinuity { text += "#EXT-X-DISCONTINUITY\n" }
                text += "#EXTINF:\(e.duration),\n\(e.number).ts\n"
            }
            if ended { text += "#EXT-X-ENDLIST\n" }
            try text.write(to: playlist, atomically: true, encoding: .utf8)
        }
        func fetch(_ url: URL, kind: String, limit: Int) async throws -> Data {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            for (key, value) in track.headers where key.lowercased() == "user-agent" { request.setValue(value, forHTTPHeaderField: key) }
            for attempt in 1...3 {
                try Task.checkCancellation()
                if shouldStop || Date() >= deadline { throw CancellationError() }
                var retryable = false
                var reason = "invalidResponse"
                do {
                    let (temporary, response) = try await session.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let status = (response as? HTTPURLResponse)?.statusCode else { throw LiveMonitorError.invalidResponse }
                    guard status == 200 else {
                        reason = "HTTP " + String(status)
                        retryable = [408, 429, 500, 502, 503, 504].contains(status)
                        throw LiveMonitorError.request("Twitch " + kind + "请求失败（" + reason + "）。")
                    }
                    let bytes = LiveRecordingEngine.fileSize(temporary.path)
                    guard bytes > 0, bytes <= Int64(limit) else { throw LiveMonitorError.invalidResponse }
                    return try Data(contentsOf: temporary)
                } catch {
                    if let network = error as? URLError {
                        reason = "URL " + String(network.errorCode)
                        retryable = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                     .cannotFindHost, .dnsLookupFailed].contains(network.code)
                    }
                    try log(["state": "requestFailed", "request": kind, "attempt": attempt, "reason": reason])
                    guard retryable, attempt < 3 else {
                        if error is URLError { throw LiveMonitorError.request("Twitch " + kind + "连接失败（" + reason + "）。") }
                        throw error
                    }
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                }
            }
            throw LiveMonitorError.invalidResponse
        }
        defer {
            var row: [String: Any] = ["state": "ended", "reason": endReason]
            if let adSince { row["unavailableSeconds"] = Date().timeIntervalSince(adSince) }
            try? log(row)
            try? FileManager.default.removeItem(at: spool)
        }
        var inputError: Error?
        do {
            while !shouldStop && Date() < deadline {
                try Task.checkCancellation()
                if lock.withLock({ workerFinished }) { endReason = "muxerExit"; break }
                try LiveRecordingEngine.checkSpace(spool, minimum: 250_000_000)
                let manifest = try await fetch(track.url, kind: "清单", limit: 1_048_576)
                let remote = try TwitchPlaylist(String(decoding: manifest, as: UTF8.self), base: track.url)
                // Begin at the same small live edge as a player. Never replay a whole stale window.
                let fresh = remote.segments.filter { $0.sequence > (lastSequence ?? max(-1, (remote.segments.last?.sequence ?? 0) - 3)) }
                if let first = fresh.first, let lastSequence, first.sequence > lastSequence + 1 {
                    pendingDiscontinuity = true
                    try log(["state": "gap", "missingSegments": first.sequence - lastSequence - 1])
                }
                for segment in fresh {
                    if shouldStop || Date() >= deadline { break }
                    try Task.checkCancellation()
                    if segment.advertisement {
                        if adSince == nil { adSince = Date() }
                        pendingDiscontinuity = true
                        try await event(.advertisement)
                    } else {
                        let data = try await fetch(segment.url, kind: "分片", limit: 32 * 1_048_576)
                        guard !data.isEmpty else { throw LiveMonitorError.invalidResponse }
                        try data.write(to: spool.appendingPathComponent("\(contentCount).ts"), options: .atomic)
                        entries.append((contentCount, segment.duration, pendingDiscontinuity || segment.discontinuity))
                        retained.append(contentCount); contentCount += 1; pendingDiscontinuity = false
                        if adSince != nil || lastState == nil {
                            try await event(.receiving, seconds: adSince.map { Date().timeIntervalSince($0) }); adSince = nil
                        }
                        if firstContent == nil { firstContent = Date() }
                        // Keep 60 advertised entries and another 60 files for a reader already using an older list.
                        while entries.count > 60 { if entries.removeFirst().discontinuity { discontinuityCount += 1 } }
                        while retained.count > 120 { try? FileManager.default.removeItem(at: spool.appendingPathComponent("\(retained.removeFirst()).ts")) }
                        try publish()
                        lock.withLock { downloadedSeconds += segment.duration }
                        if worker == nil {
                            var args = ["-hide_banner", "-loglevel", "error", "-nostats", "-n", "-progress", progressURL.path,
                                        "-stats_period", "0.5", "-protocol_whitelist", "file", "-live_start_index", "0",
                                        "-max_reload", "1000", "-m3u8_hold_counters", "1000", "-dts_delta_threshold", "1", "-i", playlist.path,
                                        "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy"]
                            if let segmentSeconds {
                                args += ["-f", "segment", "-segment_time", String(segmentSeconds), "-reset_timestamps", "1",
                                         "-segment_list", output.deletingPathExtension().appendingPathExtension("csv").path, "-segment_list_type", "csv"]
                                if output.pathExtension == "mp4" { args += ["-segment_format_options", "movflags=+frag_keyframe+empty_moov"] }
                            } else if output.pathExtension == "mp4" { args += ["-movflags", "+frag_keyframe+empty_moov"] }
                            args += [output.path]
                            let command = args
                            worker = Task {
                                defer { self.markFinished() }
                                return try await self.process.run("ffmpeg", arguments: command, timeout: max(1, deadline.timeIntervalSinceNow) + 10)
                            }
                        }
                    }
                    lastSequence = segment.sequence; lastAdvance = Date()
                }
                _ = progress.poll(progressURL)
                if progress.hasVideo, adSince == nil {
                    lock.withLock { verifiedVideo = true }
                    try await event(.recording)
                }
                if let adSince, Date().timeIntervalSince(adSince) > advertisementTimeout { throw LiveMonitorError.unavailable("Twitch 广告占位已持续 6 分钟，仍未取得主播画面；正在刷新播放地址。") }
                if Date().timeIntervalSince(lastAdvance) > stallTimeout { throw LiveMonitorError.unavailable("Twitch 清单停滞 30 秒，正在重新连接。") }
                if let firstContent, !progress.hasVideo, Date().timeIntervalSince(firstContent) > 20, adSince == nil {
                    throw LiveMonitorError.unavailable("Twitch 非广告分片未能生成画面，正在重新连接。")
                }
                if remote.ended { endReason = "endList"; break }
                try await Task.sleep(nanoseconds: UInt64(min(2, max(0.25, remote.targetDuration / 2)) * 1_000_000_000))
            }
        } catch {
            if (!shouldStop && Date() < deadline) || Task.isCancelled {
                inputError = error
                endReason = "inputError"
            }
        }
        if Date() >= deadline && endReason == "stopped" { endReason = "timeLimit" }
        // FFmpeg is reading a local live playlist. Give it EOF even when the
        // remote request fails, so it consumes buffered packets and writes the trailer.
        do { try publish(ended: true) }
        catch { inputError = inputError ?? error; process.requestStop() }
        let fallback = Task {
            try await Task.sleep(nanoseconds: 12_000_000_000)
            process.requestStop()
        }
        defer { fallback.cancel() }
        guard let worker else {
            if let inputError { throw inputError }
            return LiveToolOutput(status: 0, data: Data(), error: "")
        }
        let muxResult = await worker.result
        fallback.cancel()
        try await Self.finalizeMKV(output: output, segmented: segmentSeconds != nil)
        let result = try muxResult.get()
        if result.status != 0 { endReason = "muxerError" }
        if let inputError { throw inputError }
        return result
    }
}
