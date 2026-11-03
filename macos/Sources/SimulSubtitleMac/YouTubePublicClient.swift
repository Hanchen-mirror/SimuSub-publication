import Foundation

protocol YouTubeDiscovering: Sendable {
    func search(_ query: String, cookies: String?) async throws -> [CreatorCandidate]
    func profile(_ address: String, cookies: String?) async throws -> CreatorCandidate
    func status(_ address: String, cookies: String?) async throws -> LiveSnapshot
    func browserMedia(_ address: String) async -> (input: ResolvedLiveInput?, cookies: String?)?
}

actor YouTubePublicClient: YouTubeDiscovering {
    private let browser: any LiveBrowserReading
    private let session: URLSession
    private var profiles: [String: (Date, CreatorCandidate)] = [:]
    init(session: URLSession? = nil, browser: any LiveBrowserReading = LiveBrowserConnection()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        self.session = session ?? URLSession(configuration: config)
        self.browser = browser
    }
    private func document(_ url: URL, cookies: String?) async throws -> [String: Any] {
        if let connected = await browser.page(url, player: false), let data = connected["data"] as? [String: Any] { return data }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let cookie = LiveCookie.header(cookies, platform: .youtube, url: url) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 16 * 1024 * 1024,
              let result = Self.initialData(String(decoding: data, as: UTF8.self)) else {
            throw LiveMonitorError.request("无法读取 YouTube 公开页面，请稍后重试。")
        }
        return result
    }
    static func initialData(_ html: String) -> [String: Any]? {
        for marker in ["var ytInitialData =", "ytInitialData =", "ytInitialData=", "window[\"ytInitialData\"] ="] {
            guard let range = html.range(of: marker), let start = html[range.upperBound...].firstIndex(of: "{") else { continue }
            let bytes = Array(html[start...].utf8)
            var depth = 0, quoted = false, escaped = false
            for (index, byte) in bytes.enumerated() {
                if quoted { if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }; continue }
                if byte == 34 { quoted = true } else if byte == 123 { depth += 1 } else if byte == 125 {
                    depth -= 1
                    if depth == 0 { return (try? JSONSerialization.jsonObject(with: Data(bytes[...index]))) as? [String: Any] }
                }
            }
        }
        return nil
    }
    static func renderers(_ key: String, in value: Any) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            if let renderer = object[key] as? [String: Any] { return [renderer] }
            return object.values.flatMap { renderers(key, in: $0) }
        }
        if let array = value as? [Any] { return array.flatMap { renderers(key, in: $0) } }
        return []
    }
    static func text(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else { return "" }
        return object["simpleText"] as? String ?? (object["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }
    static func avatar(_ value: Any?) -> String? {
        guard let thumbnails = (value as? [String: Any])?["thumbnails"] as? [[String: Any]],
              var address = thumbnails.last?["url"] as? String else { return nil }
        if address.hasPrefix("//") { address = "https:" + address }
        guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return address
    }
    func search(_ query: String, cookies: String?) async throws -> [CreatorCandidate] {
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [.init(name: "search_query", value: query), .init(name: "sp", value: "EgIQAg%3D%3D")]
        let data = try await document(url.url!, cookies: cookies)
        var seen = Set<String>()
        return Self.renderers("channelRenderer", in: data).compactMap { item in
            guard let id = item["channelId"] as? String, id.hasPrefix("UC"), seen.insert(id).inserted else { return nil }
            return CreatorCandidate(platform: .youtube, address: "https://www.youtube.com/channel/" + id,
                name: Self.text(item["title"]), avatarURL: Self.avatar(item["thumbnail"]), description: Self.text(item["descriptionSnippet"]))
        }
    }
    private func page(_ address: String, cookies: String?) async throws -> [String: Any] {
        let url = URL(string: address + (address.contains("/watch?") ? "" : "/streams"))!
        return try await document(url, cookies: cookies)
    }
    func profile(_ address: String, cookies: String?) async throws -> CreatorCandidate {
        if let (date, profile) = profiles[address], Date().timeIntervalSince(date) < 300 { return profile }
        let data = try await page(address, cookies: cookies)
        guard let item = Self.renderers("channelMetadataRenderer", in: data).first,
              let id = item["externalId"] as? String, id.hasPrefix("UC"), let name = item["title"] as? String else {
            throw LiveMonitorError.invalidResponse
        }
        let profile = CreatorCandidate(platform: .youtube, address: "https://www.youtube.com/channel/" + id,
            name: name, avatarURL: Self.avatar(item["avatar"]))
        profiles[address] = (Date(), profile)
        return profile
    }
    static func snapshot(_ data: [String: Any]) throws -> LiveSnapshot {
        // YouTube serves both legacy renderers and newer lockup view models.
        let selected = renderers("tabRenderer", in: data).first { $0["selected"] as? Bool == true }
        let content = selected?["content"] ?? data
        let modern = renderers("lockupViewModel", in: content).compactMap { item -> [String: Any]? in
            guard item["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO", let id = item["contentId"] as? String else { return nil }
            let badges = renderers("thumbnailBadgeViewModel", in: item["contentImage"] ?? [:])
            let live = badges.contains { ($0["badgeStyle"] as? String)?.hasSuffix("_LIVE") == true }
            let upcoming = badges.contains { ($0["badgeStyle"] as? String)?.hasSuffix("_UPCOMING") == true }
            let duration = badges.contains { ($0["text"] as? String)?.range(of: #"^\d+:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil }
            let metadata = renderers("lockupMetadataViewModel", in: item["metadata"] ?? [:]).first
            let title = (metadata?["title"] as? [String: Any])?["content"] as? String ?? ""
            let thumbnail = renderers("thumbnailViewModel", in: item["contentImage"] ?? [:]).first
            let sources = (thumbnail?["image"] as? [String: Any])?["sources"] ?? []
            var video: [String: Any] = ["videoId": id, "title": ["simpleText": title], "thumbnail": ["thumbnails": sources]]
            if live || upcoming { video["thumbnailOverlays"] = [["thumbnailOverlayTimeStatusRenderer": ["style": live ? "LIVE" : "UPCOMING"]]] }
            else if duration { video["lengthText"] = true }
            return video
        }
        let videos = renderers("videoRenderer", in: content) + modern
        var upcoming: LiveSnapshot?
        for item in videos {
            guard let id = item["videoId"] as? String else { continue }
            let overlays = renderers("thumbnailOverlayTimeStatusRenderer", in: item)
            let badges = renderers("metadataBadgeRenderer", in: item)
            let live = overlays.contains { $0["style"] as? String == "LIVE" } || badges.contains { $0["style"] as? String == "BADGE_STYLE_TYPE_LIVE_NOW" }
            let scheduled = item["upcomingEventData"] != nil || overlays.contains { $0["style"] as? String == "UPCOMING" }
            let value = LiveSnapshot(state: live ? .live : .upcoming, title: text(item["title"]), sessionID: id,
                liveURL: "https://www.youtube.com/watch?v=" + id, coverURL: avatar(item["thumbnail"]))
            if live { return value }
            if scheduled { upcoming = value }
        }
        if let upcoming { return upcoming }
        if !videos.isEmpty && videos.allSatisfy({ $0["lengthText"] != nil }) { return .init(state: .offline) }
        // A successfully loaded channel streams grid without live badges is offline.
        // Keep malformed, consent, restricted and network responses as errors.
        let channel = !renderers("channelMetadataRenderer", in: data).isEmpty
        let grid = !renderers("richGridRenderer", in: content).isEmpty
            || !renderers("gridRenderer", in: content).isEmpty
        let empty = !renderers("messageRenderer", in: content).isEmpty && videos.isEmpty
        if channel && selected != nil && (grid || empty) { return .init(state: .offline) }
        throw LiveMonitorError.unavailable("开播检查失败，请刷新或在官网确认频道状态。")
    }
    func status(_ address: String, cookies: String?) async throws -> LiveSnapshot {
        try Self.snapshot(try await page(address, cookies: cookies))
    }
    func browserMedia(_ address: String) async -> (input: ResolvedLiveInput?, cookies: String?)? {
        guard let url = URL(string: address), let result = await browser.page(url, player: true), let player = result["data"] as? [String: Any] else { return nil }
        let rows = result["cookies"] as? [[String: Any]] ?? []
        let session = "# Netscape HTTP Cookie File\n" + rows.compactMap { row -> String? in
            guard let domain = row["domain"] as? String, let name = row["name"] as? String, let value = row["value"] as? String,
                  let path = row["path"] as? String, ![domain,name,value,path].contains(where: { $0.contains(where: { $0 == "\t" || $0.isNewline }) }) else { return nil }
            return [domain, domain.hasPrefix(".") ? "TRUE" : "FALSE", path, row["secure"] as? Bool == true ? "TRUE" : "FALSE", String(max(0, Int(row["expires"] as? Double ?? 0))), name, value].joined(separator: "\t")
        }.joined(separator: "\n") + "\n"
        let cookie = LiveCookie.hasLoginSession(session, platform: .youtube) ? session : nil
        let micro = (player["microformat"] as? [String: Any])?["playerMicroformatRenderer"] as? [String: Any]
        let live = (micro?["liveBroadcastDetails"] as? [String: Any])?["isLiveNow"] as? Bool == true
        if live, result["capture"] as? Bool == true, let transport = result["transport"] as? String {
            let title = (player["videoDetails"] as? [String: Any])?["title"] as? String ?? "YouTube 直播"
            return (.init(tracks: [], title: title, browserCapture: .init(address: url, transport: transport)), nil)
        }
        guard live, let streaming = player["streamingData"] as? [String: Any], let hls = streaming["hlsManifestUrl"] as? String,
              let stream = URL(string: hls), stream.scheme == "https", stream.user == nil, stream.password == nil else { return (nil, cookie) }
        let title = (player["videoDetails"] as? [String: Any])?["title"] as? String ?? "YouTube 直播"
        return (.init(tracks: [.init(url: stream, headers: ["User-Agent": result["userAgent"] as? String ?? "Mozilla/5.0"], hasVideo: true, hasAudio: true)], title: title), cookie)
    }
}
