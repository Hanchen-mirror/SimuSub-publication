import Foundation

enum LivePlatform: String, Codable, CaseIterable, Identifiable {
    case bilibili, youtube, twitch
    var id: String { rawValue }
    var title: String {
        switch self { case .bilibili: "Bilibili"; case .youtube: "YouTube"; case .twitch: "Twitch" }
    }
    var symbol: String {
        switch self { case .bilibili: "play.tv"; case .youtube: "play.rectangle"; case .twitch: "bubble.left.and.bubble.right" }
    }
    var loginURL: URL {
        switch self {
        case .bilibili: URL(string: "https://passport.bilibili.com/login")!
        case .youtube: URL(string: "https://accounts.google.com/ServiceLogin?service=youtube")!
        case .twitch: URL(string: "https://www.twitch.tv/login")!
        }
    }
    var cookieDomain: String {
        switch self { case .bilibili: "bilibili.com"; case .youtube: "youtube.com"; case .twitch: "twitch.tv" }
    }
    func searchURL(_ query: String) -> URL {
        var url = URLComponents(string: self == .bilibili ? "https://search.bilibili.com/live" :
            self == .youtube ? "https://www.youtube.com/results" : "https://www.twitch.tv/search")!
        url.queryItems = [URLQueryItem(name: self == .bilibili ? "keyword" : self == .youtube ? "search_query" : "term", value: query)]
        return url.url!
    }
}

enum LiveState: String, Codable {
    case unknown, offline, upcoming, live
    var title: String {
        switch self { case .unknown: "尚未确认"; case .offline: "未开播"; case .upcoming: "等待开播"; case .live: "直播中" }
    }
}

struct LiveSnapshot: Codable, Equatable {
    var state: LiveState
    var title = ""
    var sessionID: String?
    var startedAt: Date?
    var checkedAt = Date()
    var liveURL: String?
    var coverURL: String?
    var category: String?
}

struct CreatorCandidate: Identifiable, Equatable {
    let platform: LivePlatform
    var address: String
    var name: String
    var avatarURL: String?
    var description = ""
    var id: String { platform.rawValue + ":" + address }
}

struct WatchedCreator: Identifiable, Codable, Equatable {
    var id = UUID()
    let platform: LivePlatform
    var address: String
    var name: String
    var avatarURL: String?
    var monitoring = true
    var notify = false
    var autoRecord = false
    var snapshot = LiveSnapshot(state: .unknown)
    var lastError: String?
    var failureCount = 0
    var offlineConfirmations = 0
    var nextCheckAt: Date?
    var lastNotifiedSession: String?
    var stableState: LiveState = .unknown
    var acceptedSessionID: String?
    var suppressedRecordingSession: String?
    var recordingRetryAt: Date?
    var identity: String { platform.rawValue + ":" + address }
    init(_ candidate: CreatorCandidate) {
        platform = candidate.platform; address = candidate.address; name = candidate.name; avatarURL = candidate.avatarURL
    }
}

enum RecordingContainer: String, Codable, CaseIterable, Identifiable {
    case mkv, mp4
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}
enum LiveRecordingState: String, Codable {
    case preparing, recording, paused, stopping, completed, interrupted, failed, cancelled
    var title: String {
        switch self {
        case .paused: "已暂停"; case .preparing: "连接中"; case .recording: "正在录制"; case .stopping: "正在保存"
        case .completed: "已保存"; case .interrupted: "录制中断"; case .failed: "未能录制"; case .cancelled: "已取消连接"
        }
    }
    var isActive: Bool { self == .preparing || self == .recording || self == .paused || self == .stopping }
    var controlTitle: String {
        switch self { case .preparing: "连接中"; case .recording: "保存"; case .stopping: "保存中"; default: "录制" }
    }
}

enum LiveRecordingStopReason: String, Codable {
    case user, applicationExit, broadcasterOffline, lowDisk, creatorRemoved
    var explanation: String {
        switch self {
        case .user: "已手动停止"
        case .applicationExit: "应用退出，录制已停止"
        case .broadcasterOffline: "已确认主播下播"
        case .lowDisk: "保存磁盘空间不足，录制已停止"
        case .creatorRemoved: "主播已移除，录制已停止"
        }
    }
}

struct LiveRecording: Identifiable, Codable, Equatable {
    var id = UUID()
    let creatorID: UUID
    let platform: LivePlatform
    let creatorName: String
    var title: String
    var state: LiveRecordingState = .preparing
    var startedAt = Date()
    var pausedAt: Date?
    var pausedSeconds: Double?
    var elapsed: Double { max(0, (pausedAt ?? endedAt ?? Date()).timeIntervalSince(startedAt) - (pausedSeconds ?? 0)) }
    var endedAt: Date?
    var path: String
    var bytes: Int64 = 0
    var message: String?
    var stopReason: LiveRecordingStopReason?
    // Optional additions keep recordings saved by v1.09 readable.
    var segmentFolder: String?
    var mediaURLs: [URL] {
        guard let segmentFolder else { return FileManager.default.fileExists(atPath: path) ? [URL(fileURLWithPath: path)] : [] }
        return ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: segmentFolder), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mkv", "mp4"].contains($0.pathExtension) && LiveRecordingEngine.fileSize($0.path) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var savedBytes: Int64 { mediaURLs.reduce(0) { $0 + LiveRecordingEngine.fileSize($1.path) } }
    /// The active writer's last file is never handed to the clip engine.
    var closedMediaURLs: [URL] {
        guard let segmentFolder, state.isActive else { return state.isActive ? [] : mediaURLs }
        let folder = URL(fileURLWithPath: segmentFolder)
        let lists = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "csv" }
        let closed = lists.flatMap { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").components(separatedBy: "\n") }
            .compactMap { $0.split(separator: ",").first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) } }
        return mediaURLs.filter { closed.contains($0.path) || closed.contains($0.lastPathComponent) }
    }
}

struct LiveMonitorSettings: Codable, Equatable {
    var intervalSeconds = 180
    var maximumRecordings = 2
    var container: RecordingContainer = .mkv
    var outputFolder: String = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SimuSub/Recordings", isDirectory: true).path
}

enum LiveMonitorError: LocalizedError {
    case invalidInput(String), unavailable(String), request(String), invalidResponse, timeout, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .unavailable(let message), .request(let message): message
        case .invalidResponse: "平台返回的数据暂时无法识别，请稍后刷新。"
        case .timeout: "平台响应超时，请稍后刷新或检查网络。"
        case .cancelled: "操作已取消。"
        }
    }
}

enum LiveAddress {
    static func normalize(_ input: String, platform: LivePlatform) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { throw LiveMonitorError.invalidInput("请输入主播频道链接或标识。") }
        if platform == .bilibili, text.allSatisfy(\.isNumber), UInt64(text).map({ $0 > 0 }) == true {
            return "https://live.bilibili.com/\(text)"
        }
        if platform == .twitch, text.range(of: #"^[A-Za-z0-9_]{3,25}$"#, options: .regularExpression) != nil {
            return "https://www.twitch.tv/\(text.lowercased())"
        }
        if platform == .youtube, text.hasPrefix("@"), !text.contains(where: \.isWhitespace), !text.contains("/") {
            return "https://www.youtube.com/\(text)"
        }
        guard var url = URLComponents(string: text.hasPrefix("https://") ? text : "https://" + text),
              url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased() else { throw LiveMonitorError.invalidInput("请使用该平台的 HTTPS 主播链接。") }
        let parts = url.path.split(separator: "/").map(String.init)
        switch platform {
        case .bilibili:
            guard ["live.bilibili.com", "www.live.bilibili.com"].contains(host),
                  let first = parts.first, UInt64(first).map({ $0 > 0 }) == true else {
                throw LiveMonitorError.invalidInput("请输入 Bilibili 直播间链接或房间号，例如 live.bilibili.com/12345。")
            }
            return "https://live.bilibili.com/\(first)"
        case .twitch:
            guard ["twitch.tv", "www.twitch.tv", "m.twitch.tv"].contains(host), parts.count == 1,
                  let first = parts.first, first.range(of: #"^[A-Za-z0-9_]{3,25}$"#, options: .regularExpression) != nil,
                  !["directory", "search", "settings", "login", "signup", "downloads", "videos", "subscriptions"].contains(first.lowercased()) else {
                throw LiveMonitorError.invalidInput("请输入 Twitch 主播频道链接或英文频道名。")
            }
            return "https://www.twitch.tv/\(first.lowercased())"
        case .youtube:
            if ["youtu.be", "www.youtu.be"].contains(host), let first = parts.first {
                return "https://www.youtube.com/watch?v=\(first)"
            }
            guard ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) else {
                throw LiveMonitorError.invalidInput("请输入 YouTube 频道、@名称或视频链接。")
            }
            url.host = "www.youtube.com"; url.fragment = nil
            if let first = parts.first, first.hasPrefix("@") { return "https://www.youtube.com/\(first)" }
            if parts.count >= 2, ["channel", "c", "user"].contains(parts[0]) {
                return "https://www.youtube.com/\(parts[0])/\(parts[1])"
            }
            if parts.first == "watch", let video = url.queryItems?.first(where: { $0.name == "v" })?.value,
               video.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil {
                return "https://www.youtube.com/watch?v=\(video)"
            }
            throw LiveMonitorError.invalidInput("请粘贴 YouTube 频道、@名称或视频链接。")
        }
    }
    static func liveURL(_ address: String, platform: LivePlatform) -> String {
        platform == .youtube && !address.contains("/watch?") ? address + "/live" : address
    }
}

/// A single app-owned directory. Session cookies and API credentials are never
/// serialized here; only creator preferences, state and recording metadata.
final class LiveMonitorStorage {
    let root: URL
    private var unreadable: Set<String> = []
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimuSub/LiveMonitor", isDirectory: true)
    }
    func load<T: Decodable>(_ type: T.Type, name: String, fallback: T) -> (T, String?) {
        let file = root.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: file.path) else { return (fallback, nil) }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return (try decoder.decode(type, from: Data(contentsOf: file)), nil)
        } catch { unreadable.insert(name); return (fallback, "无法读取\(name)；原文件已保留，请不要覆盖后再尝试恢复。") }
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        guard !unreadable.contains(name) else { throw LiveMonitorError.unavailable("读取失败的索引已保护，未覆盖原文件：" + name) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let target = root.appendingPathComponent(name + ".json")
        // Keep one recoverable copy before replacing an existing index.
        if FileManager.default.fileExists(atPath: target.path) {
            let backup = target.appendingPathExtension("bak")
            if let data = try? Data(contentsOf: target) { try data.write(to: backup, options: .atomic) }
        }
        try encoder.encode(value).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}
