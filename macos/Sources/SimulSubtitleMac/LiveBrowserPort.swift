import Foundation

protocol LiveBrowserReading: Sendable {
    func page(_ url: URL, player: Bool) async -> [String: Any]?
}

/// Optional standard Chromium DevTools connection. Never starts a browser.
actor LiveBrowserPort: LiveBrowserReading {
    private let session: URLSession
    private let socketSession: URLSession
    private var cachedEndpoint: URL?
    private var cachedSocket: URL?
    private var retryAfter = Date.distantPast
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.6
        config.timeoutIntervalForResource = 1
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config)
        let socketConfig = URLSessionConfiguration.ephemeral
        socketConfig.timeoutIntervalForRequest = 15
        socketConfig.timeoutIntervalForResource = 30
        socketConfig.httpCookieAcceptPolicy = .never
        socketSession = URLSession(configuration: socketConfig)
    }
    static func isLoopback(_ url: URL) -> Bool {
        ["http", "ws"].contains(url.scheme ?? "") && ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
            && url.user == nil && url.password == nil
    }
    static func supports(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.host == "www.youtube.com" || (url.path == "/" && ["www.bilibili.com", "www.twitch.tv"].contains(url.host ?? "")))
    }
    private func endpoint() async -> URL? {
        if let cachedEndpoint { return cachedEndpoint }
        guard Date() > retryAfter else { return nil }
        retryAfter = Date().addingTimeInterval(15)
        var candidates: [URL] = []
        if let configured = UserDefaults.standard.string(forKey: "liveMonitor.browserEndpoint"), let url = URL(string: configured), Self.isLoopback(url) { candidates.append(url) }
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        for path in ["Google/Chrome", "Chromium", "Microsoft Edge", "BraveSoftware/Brave-Browser"] {
            let file = support.appendingPathComponent(path + "/DevToolsActivePort")
            if let text = try? String(contentsOf: file), let first = text.split(separator: "\n").first,
               let port = Int(first), (1024...65535).contains(port), let url = URL(string: "http://127.0.0.1:\(port)") { candidates.append(url) }
        }
        candidates += [9222, 9223, 9333].compactMap { URL(string: "http://127.0.0.1:\($0)") }
        for candidate in candidates {
            guard let (data, _) = try? await session.data(from: candidate.appendingPathComponent("json/version")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let socket = object["webSocketDebuggerUrl"] as? String,
                  let url = URL(string: socket), Self.isLoopback(url) else { continue }
            cachedEndpoint = candidate; cachedSocket = url
            return candidate
        }
        return nil
    }
    func captureSocket() async -> URL? { guard await endpoint() != nil else { return nil }; return cachedSocket }
    /// Reads a background, app-owned tab; existing tabs and the default browser remain untouched.
    func page(_ url: URL, player: Bool = false) async -> [String: Any]? {
        guard Self.supports(url), let endpoint = await endpoint() else { return nil }
        guard let socketURL = cachedSocket else { return nil }
        let socket = socketSession.webSocketTask(with: socketURL)
        socket.maximumMessageSize = 16 * 1024 * 1024
        socket.resume()
        let timeout = Task { try? await Task.sleep(nanoseconds: 12_000_000_000); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        var sequence = 0
        var targetID: String?
        var pageSession: String?
        func command(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            sequence += 1
            let expected = sequence
            var payload: [String: Any] = ["id": expected, "method": method, "params": params]
            if let pageSession, !method.hasPrefix("Target.") { payload["sessionId"] = pageSession }
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
            while true {
                let message = try await socket.receive()
                let bytes: Data
                switch message { case .data(let value): bytes = value; case .string(let value): bytes = Data(value.utf8); @unknown default: continue }
                guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], reply["id"] as? Int == expected else { continue }
                guard reply["error"] == nil else { throw LiveMonitorError.invalidResponse }
                return reply["result"] as? [String: Any] ?? [:]
            }
        }
        let result: [String: Any]?
        do {
            let target = try await command("Target.createTarget", ["url": "about:blank", "background": true])
            guard let id = target["targetId"] as? String else { throw LiveMonitorError.invalidResponse }
            targetID = id
            let attached = try await command("Target.attachToTarget", ["targetId": id, "flatten": true])
            guard let attachedSession = attached["sessionId"] as? String else { throw LiveMonitorError.invalidResponse }
            pageSession = attachedSession
            if url.path == "/" && !player {
                // Login probes read only the selected site's session, without navigating or playing media.
                let cookies = try await command("Network.getCookies", ["urls": [url.absoluteString]])
                result = ["cookies": cookies["cookies"] ?? [], "data": [String: Any]()]
            } else {
                _ = try await command("Page.enable")
                _ = try await command("Page.addScriptToEvaluateOnNewDocument", ["source": "(()=>{const p=HTMLMediaElement.prototype.play;HTMLMediaElement.prototype.play=function(){this.muted=true;return p.call(this)}})();"])
                _ = try await command("Page.navigate", ["url": url.absoluteString])
                var document: [String: Any]?
                let urlJSON = String(decoding: try JSONSerialization.data(withJSONObject: url.absoluteString, options: .fragmentsAllowed), as: UTF8.self)
                for _ in 0..<35 {
                    let expression = "(()=>{if(location.href!==\(urlJSON)&&!location.href.startsWith('https://www.youtube.com/'))return null;const d=\(player ? "document.getElementById('movie_player')?.getPlayerResponse?.() || window.ytInitialPlayerResponse" : "window.ytInitialData");return d?{data:d,userAgent:navigator.userAgent,capture:typeof document.querySelector('video')?.captureStream==='function',transport:'port'}:null})()"
                    let evaluated = try await command("Runtime.evaluate", ["expression": expression, "returnByValue": true])
                    if let value = (evaluated["result"] as? [String: Any])?["value"] as? [String: Any], value["data"] is [String: Any] { document = value; break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                if player {
                    var value = document ?? ["data": [String: Any]()]

                    let cookies = try await command("Network.getCookies", ["urls": ["https://www.youtube.com/"]])
                    value["cookies"] = cookies["cookies"]
                    document = value
                }
                result = document
            }
        } catch { result = nil; cachedEndpoint = nil }
        if let targetID { _ = try? await command("Target.closeTarget", ["targetId": targetID]) }
        timeout.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        if let targetID { _ = try? await session.data(from: endpoint.appendingPathComponent("json/close/" + targetID)) }
        return result
    }
}
