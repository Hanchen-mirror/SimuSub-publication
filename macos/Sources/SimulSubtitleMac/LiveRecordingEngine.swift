import Foundation

enum LiveRecordingEngine {
    static func safeName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let clean = String(text.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" })
        return String(clean.prefix(50)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    static func outputURL(creator: WatchedCreator, settings: LiveMonitorSettings) throws -> URL {
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
        let name = safeName(creator.name)
        let folder = URL(fileURLWithPath: settings.outputFolder, isDirectory: true)
            .appendingPathComponent((name.isEmpty ? "主播" : name) + "-" + creator.platform.title, isDirectory: true)
            .appendingPathComponent(date.string(from: creator.snapshot.startedAt ?? Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try checkSpace(folder, minimum: 1_000_000_000)
        date.dateFormat = "HHmmss"
        return folder.appendingPathComponent("\(date.string(from: Date()))-\(creator.platform.rawValue)-\(safeName(creator.name))-\(UUID().uuidString.prefix(8)).\(settings.container.rawValue)")
    }
    static func checkSpace(_ folder: URL, minimum: Int64) throws {
        let values = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        if let free = values[.systemFreeSize] as? NSNumber, free.int64Value < minimum {
            throw LiveMonitorError.unavailable("保存磁盘空间不足，请释放空间或更换录制目录。")
        }
    }
    static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    static func arguments(input: ResolvedLiveInput, output: URL, segmentSeconds: Int? = nil, progressURL: URL? = nil) throws -> [String] {
        guard !input.tracks.isEmpty, input.tracks.count <= 2,
              let video = input.tracks.firstIndex(where: \.hasVideo) else { throw LiveMonitorError.invalidResponse }
        var arguments = ["-hide_banner", "-loglevel", "error", "-nostats", "-n"]
        if let progressURL {
            guard progressURL.isFileURL else { throw LiveMonitorError.invalidInput("录制进度必须保存在本机。") }
            arguments += ["-progress", progressURL.path, "-stats_period", "0.5"]
        }
        for track in input.tracks {
            guard ["http", "https"].contains(track.url.scheme ?? ""), track.url.user == nil, track.url.password == nil else {
                throw LiveMonitorError.invalidInput("直播流地址无效。")
            }
            arguments += ["-rw_timeout", "8000000", "-reconnect", "1", "-reconnect_streamed", "1",
                          "-reconnect_on_network_error", "1", "-reconnect_delay_max", "2",
                          "-reconnect_max_retries", "2", "-reconnect_delay_total_max", "6"]
            let headers = track.headers.filter {
                ["user-agent", "referer", "origin", "cookie", "authorization"].contains($0.key.lowercased())
                    && !$0.key.contains(where: \.isNewline) && !$0.value.contains(where: \.isNewline)
            }.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value + "\r\n" }.joined()
            if !headers.isEmpty { arguments += ["-headers", headers] }
            arguments += ["-i", track.url.absoluteString]
        }
        arguments += ["-map", "\(video):v:0?"]
        // Extractors may omit (or misreport) audio codec metadata for muxed
        // live FLV/HLS. Let FFmpeg discover the real audio stream instead of
        // silently dropping it. Prefer an explicit/separate audio input.
        let audio = input.tracks.firstIndex(where: \.hasAudio)
            ?? input.tracks.firstIndex(where: { !$0.hasVideo }) ?? video
        arguments += ["-map", "\(audio):a:0?"]
        arguments += ["-c", "copy"]
        if let segmentSeconds {
            arguments += ["-f", "segment", "-segment_time", String(max(1, segmentSeconds)), "-reset_timestamps", "1",
                          "-segment_list", output.deletingPathExtension().appendingPathExtension("csv").path, "-segment_list_type", "csv"]
            if output.pathExtension == "mp4" { arguments += ["-segment_format_options", "movflags=+frag_keyframe+empty_moov"] }
        } else if output.pathExtension == "mp4" { arguments += ["-movflags", "+frag_keyframe+empty_moov"] }
        arguments += [output.path]
        return arguments
    }

    /// Classify stderr without persisting signed URLs, headers or credentials.
    static func failureMessage(_ stderr: String) -> String {
        let text = stderr.lowercased()
        if text.contains("progress url") || text.contains("error parsing global options") { return "录制组件初始化失败，请更新应用后重试。" }
        if text.contains("no space left") { return "保存磁盘空间不足。" }
        if text.contains("permission denied") || text.contains("read-only file system") { return "无法写入保存目录，请检查目录权限。" }
        if text.contains("401") || text.contains("403") || text.contains("forbidden") { return "平台拒绝直播流请求（会话或流地址可能已失效）。" }
        if text.contains("404") || text.contains("not found") { return "直播流地址已失效或不可用。" }
        if text.contains("timed out") || text.contains("timeout") { return "读取直播流超时。" }
        if text.contains("connection") || text.contains("network") || text.contains("resolve hostname") || text.contains("input/output error") { return "直播流网络连接中断或无法建立。" }
        if text.contains("invalid data") || text.contains("codec") { return "直播流数据损坏或格式暂不支持。" }
        return "录制进程异常退出，平台未提供可识别的错误原因。"
    }
}

/// FFmpeg reports progress only after muxing output frames. Chunk boundaries
/// need not match line boundaries; retained input stays bounded.
final class LiveRecordingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var receivedFrame = false
    private var offset: UInt64 = 0
    var hasVideo: Bool { lock.withLock { receivedFrame } }
    /// Called by one recording task. Read only appended bytes in bounded chunks;
    /// this also works with the bundled FFmpeg's file-only progress protocol.
    func poll(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            for _ in 0..<8 {
                guard let chunk = try handle.read(upToCount: 8192), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                if consume(chunk) { return true }
            }
        } catch { /* A partially written/missing progress file is not video. */ }
        return false
    }
    func consume(_ data: Data) -> Bool {
        lock.withLock {
            guard !receivedFrame else { return false }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                if line.hasPrefix("frame="), let frame = Int(line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)), frame > 0 {
                    receivedFrame = true; pending.removeAll(); return true
                }
            }
            if pending.count > 4096 { pending.removeAll() }
            return false
        }
    }
}
