import AppKit
import Foundation

struct LivePlatformAccess: Sendable {
    var cookies: String?
    var browserAllowed = true
    var recordingQuality: RecordingQuality = .original
    var apiKey: String?
    var clientID: String?
    var accessToken: String?
}

struct LiveCookie: Sendable {
    let domain: String
    let path: String
    let secure: Bool
    let expires: TimeInterval
    let name: String
    let value: String
    let original: String
    static func parse(_ text: String, platform: LivePlatform, now: Date = Date()) -> [LiveCookie] {
        text.components(separatedBy: .newlines).compactMap { source in
            let line = source.hasPrefix("#HttpOnly_") ? String(source.dropFirst(10)) : source
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 7 else { return nil }
            let domain = fields[0].trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard domain == platform.cookieDomain || domain.hasSuffix("." + platform.cookieDomain),
                  let expires = Double(fields[4]), expires <= 0 || expires > now.timeIntervalSince1970,
                  !fields[5].isEmpty, fields[5].count <= 256, fields[6].count <= 16_384 else { return nil }
            return LiveCookie(domain: domain, path: fields[2], secure: fields[3].uppercased() == "TRUE",
                              expires: expires, name: fields[5], value: fields[6], original: source)
        }
    }
    static func header(_ text: String?, platform: LivePlatform, url: URL) -> String? {
        guard let text, let host = url.host?.lowercased() else { return nil }
        let values = parse(text, platform: platform).filter {
            (host == $0.domain || host.hasSuffix("." + $0.domain)) && url.path.hasPrefix($0.path)
                && (!$0.secure || url.scheme == "https")
        }.map { $0.name + "=" + $0.value }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }
    static func browserSession(_ result: [String: Any]?, platform: LivePlatform) -> String? {
        let rows = result?["cookies"] as? [[String: Any]] ?? []
        let text = "# Netscape HTTP Cookie File\n" + rows.compactMap { row -> String? in
            guard let domain = row["domain"] as? String, let name = row["name"] as? String,
                  let value = row["value"] as? String, let path = row["path"] as? String,
                  ![domain, name, value, path].contains(where: { $0.contains(where: { $0 == "\t" || $0.isNewline }) }) else { return nil }
            return [domain, domain.hasPrefix(".") ? "TRUE" : "FALSE", path, row["secure"] as? Bool == true ? "TRUE" : "FALSE",
                    String(max(0, Int(row["expires"] as? Double ?? 0))), name, value].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        let filtered = "# Netscape HTTP Cookie File\n" + parse(text, platform: platform).map(\.original).joined(separator: "\n") + "\n"
        return hasLoginSession(filtered, platform: platform) ? filtered : nil
    }
    static func hasLoginSession(_ text: String, platform: LivePlatform) -> Bool {
        let names: Set<String>
        switch platform {
        case .youtube: names = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
        case .bilibili: names = ["SESSDATA"]
        case .twitch: names = ["auth-token"]
        }
        return parse(text, platform: platform).contains { names.contains($0.name) && !$0.value.isEmpty }
    }
}

final class LiveCookieLease {
    let directory: URL
    let file: URL
    init(_ text: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-session-" + UUID().uuidString)
        file = directory.appendingPathComponent("cookies.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            try? FileManager.default.removeItem(at: directory)
            throw LiveMonitorError.unavailable("无法创建临时会话文件。")
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum LiveAccountSource { case guest, browser, cookies }

@MainActor
final class LiveCredentials: ObservableObject {
    @Published private(set) var revision = 0
    private let store = SecureCredentialStore()
    private let defaults: UserDefaults
    private let enabled: Bool
    private let browser: any LiveBrowserReading
    @Published private var browserSessions: [LivePlatform: String] = [:]
    private var probes: [LivePlatform: Task<[String: Any]?, Never>] = [:]
    init(defaults: UserDefaults = .standard, enabled: Bool = true, browser: any LiveBrowserReading = LiveBrowserConnection()) {
        self.defaults = defaults; self.enabled = enabled; self.browser = browser
    }
    func allowsBrowser(_ platform: LivePlatform) -> Bool { !defaults.bool(forKey: key(platform.rawValue + ".browserDisabled")) }
    func selectedSource(_ platform: LivePlatform) -> LiveAccountSource {
        if allowsBrowser(platform), let session = browserSessions[platform], LiveCookie.hasLoginSession(session, platform: platform) { return .browser }
        return usesAccount(platform) ? .cookies : .guest
    }
    func refreshBrowserSession(_ platform: LivePlatform) async {
        guard enabled else { return }
        if let existing = probes[platform] {
            let result = await existing.value
            guard !Task.isCancelled else { return }
            browserSessions[platform] = LiveCookie.browserSession(result, platform: platform)
            return
        }
        let browser = self.browser
        let url = URL(string: "https://www." + platform.cookieDomain + "/")!
        let task = Task { await browser.page(url, player: false) }
        probes[platform] = task
        let result = await task.value
        probes[platform] = nil
        guard !Task.isCancelled else { return }
        browserSessions[platform] = LiveCookie.browserSession(result, platform: platform)
    }
    func openLogin(_ platform: LivePlatform) {
        defaults.set(false, forKey: key(platform.rawValue + ".browserDisabled")); revision += 1
        // Open the browser whose local bridge can supply the session when it is running.
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.citrolabs.ego.lite" })?.bundleURL {
            NSWorkspace.shared.open([platform.loginURL], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(platform.loginURL) }
    }
    private func key(_ name: String) -> String { "liveMonitor.v106." + name }
    func usesAccount(_ platform: LivePlatform) -> Bool { defaults.bool(forKey: key(platform.rawValue + ".useAccount")) }
    func hasCookies(_ platform: LivePlatform) -> Bool { enabled && store.contains(account: key(platform.rawValue + ".cookies")) }
    func hasAPIKey(_ platform: LivePlatform) -> Bool {
        guard enabled else { return false }
        return platform == .youtube ? store.contains(account: key("youtube.apiKey"))
            : platform == .twitch && store.contains(account: key("twitch.token")) && store.contains(account: key("twitch.clientID"))
    }
    func useGuest(_ platform: LivePlatform) { defaults.set(true, forKey: key(platform.rawValue + ".browserDisabled")); defaults.set(false, forKey: key(platform.rawValue + ".useAccount")); revision += 1 }
    func useSavedAccount(_ platform: LivePlatform) throws {
        guard hasCookies(platform) else { throw LiveMonitorError.unavailable("请先导入该平台的 Cookies 会话文件。") }
        defaults.set(true, forKey: key(platform.rawValue + ".browserDisabled"))
        defaults.set(true, forKey: key(platform.rawValue + ".useAccount")); revision += 1
    }
    func importCookies(_ url: URL, platform: LivePlatform) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard enabled, size > 0 && size <= 2_097_152 else { throw LiveMonitorError.invalidInput("请选择小于 2 MB 的 Netscape Cookies 文本文件。") }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = LiveCookie.parse(text, platform: platform)
        guard !entries.isEmpty else { throw LiveMonitorError.invalidInput("文件中没有该平台有效的 Netscape Cookies；请重新导出自己的会话。") }
        let filtered = "# Netscape HTTP Cookie File\n" + entries.map(\.original).joined(separator: "\n") + "\n"
        try store.save(filtered, account: key(platform.rawValue + ".cookies"))
        defaults.set(true, forKey: key(platform.rawValue + ".browserDisabled"))
        defaults.set(true, forKey: key(platform.rawValue + ".useAccount")); revision += 1
    }
    func disconnect(_ platform: LivePlatform) throws {
        guard enabled else { return }
        try store.delete(account: key(platform.rawValue + ".cookies"))
        useGuest(platform)
    }
    func saveAPIKey(_ value: String, platform: LivePlatform, clientID: String = "") throws {
        guard enabled else { return }
        let secret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty, secret.count <= 1024, !secret.contains(where: \.isWhitespace) else {
            throw LiveMonitorError.invalidInput("接口凭证不能为空或包含空白。")
        }
        if platform == .youtube { try store.save(secret, account: key("youtube.apiKey")) }
        else if platform == .twitch {
            let identifier = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier.count < 256, !identifier.contains(where: \.isWhitespace) else { throw LiveMonitorError.invalidInput("请同时填写 Twitch Client ID。") }
            try store.save(secret.hasPrefix("oauth:") ? String(secret.dropFirst(6)) : secret, account: key("twitch.token"))
            try store.save(identifier, account: key("twitch.clientID"))
        }
        revision += 1
    }
    func removeAPIKey(_ platform: LivePlatform) throws {
        guard enabled else { return }
        for name in platform == .youtube ? ["youtube.apiKey"] : ["twitch.token", "twitch.clientID"] {
            try store.delete(account: key(name))
        }
        revision += 1
    }
    func context(_ platform: LivePlatform) throws -> LivePlatformAccess {
        guard enabled else { return .init() }
        var result = LivePlatformAccess(browserAllowed: allowsBrowser(platform))
        if usesAccount(platform) {
            if let text = try? store.read(account: key(platform.rawValue + ".cookies"), allowInteraction: false), LiveCookie.hasLoginSession(text, platform: platform) {
                result.cookies = text
            } // An expired optional session must not disable public access.
        }
        if selectedSource(platform) == .browser { result.cookies = browserSessions[platform] }
        if hasAPIKey(platform) {
            if platform == .youtube { result.apiKey = try? store.read(account: key("youtube.apiKey"), allowInteraction: false) }
            if platform == .twitch {
                result.clientID = try store.read(account: key("twitch.clientID"))
                result.accessToken = try store.read(account: key("twitch.token"))
            }
        }
        return result
    }
}
