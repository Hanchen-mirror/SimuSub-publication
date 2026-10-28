import Foundation

struct ExtractedLiveMedia: Decodable, Sendable {
    var id: String?
    var title: String?
    var channel: String?
    var channel_id: String?
    var channel_url: String?
    var uploader: String?
    var uploader_id: String?
    var webpage_url: String?
    var url: String?
    var is_live: Bool?
    var live_status: String?
    var timestamp: Double?
    var release_timestamp: Double?
    var vcodec: String?
    var acodec: String?
    var http_headers: [String: String]?
    var entries: [ExtractedLiveMedia]?
    var requested_formats: [ExtractedLiveMedia]?
    var categories: [String]?
    var thumbnail: String?
    struct Thumbnail: Decodable, Sendable {
        var url: String
        var id: String?
        var width: Int?
        var height: Int?
    }
    var thumbnails: [Thumbnail]?
    var profileAvatar: String? {
        if let exact = thumbnails?.first(where: { $0.id == "avatar_uncropped" }) { return exact.url }
        return thumbnails?.first(where: { ($0.width ?? 0) > 0 && $0.width == $0.height })?.url
    }
}

protocol LiveExtracting: Sendable {
    func metadata(_ address: String, cookies: String?, flat: Bool) async throws -> ExtractedLiveMedia
}

struct YTDLPLiveExtractor: LiveExtracting {
    func metadata(_ address: String, cookies: String?, flat: Bool = false) async throws -> ExtractedLiveMedia {
        let lease = try cookies.map(LiveCookieLease.init)
        var arguments = ["--ignore-config", "--no-warnings", "--skip-download", "--dump-single-json",
            "--socket-timeout", "15", "--retries", "1", "--extractor-retries", "1", "--no-cache-dir",
            "--js-runtimes", "deno:" + LiveTools.root.appendingPathComponent("deno").path,
            "--playlist-end", flat ? "8" : "1", "--ignore-no-formats-error"]
        if flat { arguments.append("--flat-playlist") }
        else {
            arguments += ["--no-playlist", "--format", "best[height<=1080]/bestvideo[height<=1080]+bestaudio/best"]
        }
        if let lease { arguments += ["--cookies", lease.file.path] }
        arguments += ["--", address]
        let result = try await LiveTools.run("yt-dlp", arguments: arguments, timeout: flat ? 45 : 55)
        withExtendedLifetime(lease) { }
        guard result.status == 0 else {
            if Self.isOffline(result.error) { throw LiveExtractionError.offline }
            throw LiveMonitorError.request(Self.friendlyError(result.error))
        }
        guard let value = try? JSONDecoder().decode(ExtractedLiveMedia.self, from: result.data) else {
            throw LiveMonitorError.invalidResponse
        }
        return value
    }
    static func isOffline(_ error: String) -> Bool {
        let text = error.lowercased()
        return ["not currently live", "is offline", "not currently streaming", "no live streams",
                "is not live", "user is not live"].contains { text.contains($0) }
    }
    static func friendlyError(_ message: String) -> String {
        let text = message.lowercased()
        if text.contains("sign in") || text.contains("login") || text.contains("cookies") || text.contains("private") || text.contains("members") {
            return "平台要求登录或当前内容受限。可连接自己的会话后重试；未将此次错误判断为下播。"
        }
        if text.contains("429") || text.contains("too many requests") || text.contains("412") {
            return "平台暂时限制了访问，请稍后重试或连接自己的账号。"
        }
        if text.contains("404") || text.contains("not exist") || text.contains("not found") {
            return "没有找到该频道，请核对主播链接。"
        }
        if text.contains("ssl") || text.contains("timed out") || text.contains("network") || text.contains("resolve") {
            return "无法连接该平台，请检查网络后刷新。"
        }
        return "暂时无法读取该直播。请稍后刷新、连接会话，或在官网确认链接是否可访问。"
    }
}

enum LiveExtractionError: Error { case offline }

struct ResolvedLiveInput: Sendable {
    struct Track: Sendable {
        let url: URL
        let headers: [String: String]
        let hasVideo: Bool
        let hasAudio: Bool
    }
    let tracks: [Track]
    let title: String
}

protocol LivePlatformServing: Sendable {
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate]
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput
}

actor LivePlatformService: LivePlatformServing {
    private let session: URLSession
    private let extractor: LiveExtracting
    private var biliGuestCookie: String?
    private var twitchValidatedToken: String?
    private var twitchValidatedClientID: String?
    private var twitchValidationUntil = Date.distantPast
    init(session: URLSession? = nil, extractor: LiveExtracting = YTDLPLiveExtractor()) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: config)
        self.extractor = extractor
    }

    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= (query.contains("://") ? 500 : 100) else { throw LiveMonitorError.invalidInput("请输入 1–100 个字符的主播名称或链接。") }
        if query.contains("://") || (platform == .bilibili && query.allSatisfy(\.isNumber)) || query.hasPrefix("@") {
            return [try await resolve(query, platform: platform, access: access)]
        }
        switch platform {
        case .bilibili:
            let json = try await bili("https://api.bilibili.com/x/web-interface/search/type",
                                      items: ["search_type": "live_user", "keyword": query, "page": "1"], access: access)
            let data = json["data"] as? [String: Any]
            let rows = data?["result"] as? [[String: Any]] ?? []
            return rows.prefix(20).compactMap { row in
                let id = string(row["roomid"] ?? row["room_id"])
                guard !id.isEmpty, id != "0" else { return nil }
                return CreatorCandidate(platform: .bilibili, address: "https://live.bilibili.com/" + id,
                    name: plain(string(row["uname"])), avatarURL: imageURL(string(row["face"])), description: plain(string(row["title"])))
            }
        case .youtube:
            if let key = access.apiKey {
                let json = try await get("https://www.googleapis.com/youtube/v3/search",
                    items: ["part": "snippet", "type": "channel", "maxResults": "10", "q": query, "key": key])
                return (json["items"] as? [[String: Any]] ?? []).compactMap { row in
                    guard let id = row["id"] as? [String: Any], let channel = id["channelId"] as? String,
                          let snippet = row["snippet"] as? [String: Any] else { return nil }
                    let thumbnails = snippet["thumbnails"] as? [String: [String: Any]]
                    return CreatorCandidate(platform: .youtube, address: "https://www.youtube.com/channel/" + channel,
                        name: plain(string(snippet["title"])), avatarURL: thumbnails?["default"]?["url"] as? String,
                        description: plain(string(snippet["description"])))
                }
            }
            let result = try await extractor.metadata("ytsearch8:" + query, cookies: access.cookies, flat: true)
            var seen: Set<String> = []
            return (result.entries ?? []).compactMap { entry in
                let channel = entry.channel_url ?? entry.channel_id.map { "https://www.youtube.com/channel/" + $0 }
                guard let channel, let canonical = try? LiveAddress.normalize(channel, platform: .youtube),
                      seen.insert(canonical).inserted else { return nil }
                return CreatorCandidate(platform: .youtube, address: canonical, name: entry.channel ?? entry.uploader ?? query,
                                        description: entry.title ?? "")
            }
        case .twitch:
            guard let token = access.accessToken, let clientID = access.clientID else {
                if let address = try? LiveAddress.normalize(query, platform: .twitch) {
                    return [try await resolve(address, platform: .twitch, access: access)]
                }
                throw LiveMonitorError.unavailable("Twitch 访客可按英文频道名或链接添加；关键词搜索可使用官网搜索，或在连接设置保存自己的 Twitch 接口凭证。")
            }
            try await validateTwitch(token: token, clientID: clientID)
            let json = try await get("https://api.twitch.tv/helix/search/channels", items: ["query": query, "first": "12"],
                headers: ["Client-Id": clientID, "Authorization": "Bearer " + token])
            return (json["data"] as? [[String: Any]] ?? []).compactMap { row in
                guard let login = row["broadcaster_login"] as? String,
                      let address = try? LiveAddress.normalize(login, platform: .twitch) else { return nil }
                return CreatorCandidate(platform: .twitch, address: address, name: string(row["display_name"]),
                                        avatarURL: imageURL(string(row["thumbnail_url"])), description: plain(string(row["title"])))
            }
        }
    }

    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate {
        let address = try LiveAddress.normalize(input, platform: platform)
        switch platform {
        case .bilibili:
            let room = try await bili("https://api.live.bilibili.com/room/v1/Room/get_info",
                                     items: ["room_id": URL(string: address)!.lastPathComponent], access: access)
            guard let data = room["data"] as? [String: Any] else { throw LiveMonitorError.invalidResponse }
            let roomID = string(data["room_id"]), uid = string(data["uid"])
            guard !roomID.isEmpty, roomID != "0" else { throw LiveMonitorError.invalidInput("没有找到该 Bilibili 直播间。") }
            let anchor = try? await bili("https://api.live.bilibili.com/live_user/v1/Master/info", items: ["uid": uid], access: access)
            let info = (anchor?["data"] as? [String: Any])?["info"] as? [String: Any]
            return CreatorCandidate(platform: platform, address: "https://live.bilibili.com/" + roomID,
                name: (info?["uname"] as? String) ?? plain(string(data["title"])), avatarURL: imageURL(string(info?["face"])),
                description: plain(string(data["title"])))
        case .youtube:
            let media = try await extractor.metadata(address, cookies: access.cookies, flat: !address.contains("/watch?"))
            let channelID = media.channel_id ?? (media.id?.hasPrefix("UC") == true ? media.id : nil)
            let channel = media.channel_url ?? channelID.map { "https://www.youtube.com/channel/" + $0 } ?? address
            guard !channel.contains("/watch?") else { throw LiveMonitorError.invalidInput("请使用主播的频道链接，暂时无法从这个视频确定频道。") }
            let canonical = try LiveAddress.normalize(channel, platform: platform)
            let channelProfile = address.contains("/watch?") ? try await extractor.metadata(canonical, cookies: access.cookies, flat: true) : media
            return CreatorCandidate(platform: platform, address: canonical,
                name: channelProfile.channel ?? channelProfile.uploader ?? channelProfile.title ?? URL(string: channel)!.lastPathComponent,
                avatarURL: channelProfile.profileAvatar)
        case .twitch:
            let login = URL(string: address)!.lastPathComponent
            if let token = access.accessToken, let clientID = access.clientID {
                try await validateTwitch(token: token, clientID: clientID)
                let json = try await get("https://api.twitch.tv/helix/users", items: ["login": login],
                    headers: ["Client-Id": clientID, "Authorization": "Bearer " + token])
                guard let row = (json["data"] as? [[String: Any]])?.first else { throw LiveMonitorError.invalidInput("没有找到该 Twitch 频道。") }
                return CreatorCandidate(platform: platform, address: address, name: string(row["display_name"]), avatarURL: imageURL(string(row["profile_image_url"])))
            }
            // Public channel profile query, independent of whether the channel
            // is live. Uses the same public client as pinned yt-dlp, no user token.
            if let profile = try? await twitchPublicProfile(login: login, cookies: access.cookies) { return profile }
            do {
                let media = try await extractor.metadata(address, cookies: access.cookies, flat: false)
                return CreatorCandidate(platform: platform, address: address, name: media.uploader ?? media.channel ?? login, avatarURL: nil, description: media.title ?? "")
            } catch LiveExtractionError.offline {
                return CreatorCandidate(platform: platform, address: address, name: login, avatarURL: nil, description: "频道当前未开播")
            }
        }
    }

    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot {
        if creator.platform == .bilibili {
            let json = try await bili("https://api.live.bilibili.com/room/v1/Room/get_info",
                                     items: ["room_id": URL(string: creator.address)!.lastPathComponent], access: access)
            guard let data = json["data"] as? [String: Any], let live = data["live_status"] as? Int else { throw LiveMonitorError.invalidResponse }
            let start = string(data["live_time"])
            return LiveSnapshot(state: live == 1 ? .live : .offline, title: plain(string(data["title"])),
                                sessionID: live == 1 ? creator.address + ":" + start : nil, liveURL: creator.address,
                                coverURL: imageURL(string(data["user_cover"])) ?? imageURL(string(data["keyframe"])), category: data["area_name"] as? String)
        }
        if creator.platform == .twitch, let token = access.accessToken, let clientID = access.clientID {
            try await validateTwitch(token: token, clientID: clientID)
            let json = try await get("https://api.twitch.tv/helix/streams",
                items: ["user_login": URL(string: creator.address)!.lastPathComponent],
                headers: ["Client-Id": clientID, "Authorization": "Bearer " + token])
            guard let rows = json["data"] as? [[String: Any]] else { throw LiveMonitorError.invalidResponse }
            guard let row = rows.first else { return LiveSnapshot(state: .offline) }
            return LiveSnapshot(state: .live, title: plain(string(row["title"])), sessionID: string(row["id"]),
                startedAt: ISO8601DateFormatter().date(from: string(row["started_at"])), liveURL: creator.address,
                coverURL: imageURL(string(row["thumbnail_url"]).replacingOccurrences(of: "{width}", with: "640").replacingOccurrences(of: "{height}", with: "360")), category: row["game_name"] as? String)
        }
        do {
            let media = try await extractor.metadata(LiveAddress.liveURL(creator.address, platform: creator.platform), cookies: access.cookies, flat: false)
            let state: LiveState
            if media.is_live == true || media.live_status == "is_live" { state = .live }
            else if media.live_status == "is_upcoming" { state = .upcoming }
            else if ["not_live", "was_live", "post_live"].contains(media.live_status ?? "") { state = .offline }
            else { throw LiveMonitorError.unavailable("平台没有返回明确直播状态，稍后再确认。") }
            return LiveSnapshot(state: state, title: media.title ?? "", sessionID: media.id,
                startedAt: (media.release_timestamp ?? media.timestamp).map(Date.init(timeIntervalSince1970:)),
                liveURL: media.webpage_url ?? creator.address, coverURL: imageURL(media.thumbnail ?? ""), category: media.categories?.first)
        } catch LiveExtractionError.offline { return LiveSnapshot(state: .offline) }
    }

    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        let media = try await extractor.metadata(LiveAddress.liveURL(creator.address, platform: creator.platform), cookies: access.cookies, flat: false)
        guard media.is_live == true || media.live_status == "is_live" else { throw LiveMonitorError.unavailable("主播当前没有可录制的直播，未下载过去的视频。") }
        let sources = media.requested_formats ?? [media]
        let tracks = sources.compactMap { source -> ResolvedLiveInput.Track? in
            guard let text = source.url, let url = URL(string: text), ["https", "http"].contains(url.scheme),
                  url.user == nil, url.password == nil else { return nil }
            var headers = media.http_headers ?? [:]
            headers.merge(source.http_headers ?? [:]) { _, new in new }
            if let cookie = LiveCookie.header(access.cookies, platform: creator.platform, url: url) { headers["Cookie"] = cookie }
            headers = headers.filter { ["user-agent", "referer", "origin", "cookie", "authorization"].contains($0.key.lowercased())
                && !$0.key.contains(where: \.isNewline) && !$0.value.contains(where: \.isNewline) }
            return .init(url: url, headers: headers, hasVideo: source.vcodec != nil && source.vcodec != "none",
                         hasAudio: source.acodec != nil && source.acodec != "none")
        }
        guard !tracks.isEmpty, tracks.count <= 2, tracks.contains(where: \.hasVideo) else {
            throw LiveMonitorError.unavailable("平台暂时没有返回可用的视频直播流。")
        }
        return ResolvedLiveInput(tracks: tracks, title: media.title ?? creator.snapshot.title)
    }

    private func twitchPublicProfile(login: String, cookies: String?) async throws -> CreatorCandidate {
        let url = URL(string: "https://gql.twitch.tv/gql")!
        var request = URLRequest(url: url, timeoutInterval: 15); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ue6666qo983tsx6so1t0vnawi233wa", forHTTPHeaderField: "Client-ID")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Only explicitly imported Twitch cookies can be used for this host.
        if let header = LiveCookie.header(cookies, platform: .twitch, url: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": "query SimuSubAvatar($login:String!){user(login:$login){displayName profileImageURL(width:300)}}",
            "variables": ["login": login]])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 1_048_576,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fields = json["data"] as? [String: Any], let user = fields["user"] as? [String: Any],
              let name = user["displayName"] as? String else { throw LiveMonitorError.invalidResponse }
        return CreatorCandidate(platform: .twitch, address: "https://www.twitch.tv/" + login, name: name,
                                avatarURL: imageURL(string(user["profileImageURL"])))
    }

    private func bili(_ base: String, items: [String: String], access: LivePlatformAccess) async throws -> [String: Any] {
        var headers = ["Referer": "https://www.bilibili.com/", "User-Agent": Self.userAgent]
        if let cookies = access.cookies, let url = URL(string: base) {
            headers["Cookie"] = LiveCookie.header(cookies, platform: .bilibili, url: url)
        } else if base.contains("api.bilibili.com/x/web-interface/search") {
            if biliGuestCookie == nil {
                let finger = try await get("https://api.bilibili.com/x/frontend/finger/spi", headers: headers)
                if let data = finger["data"] as? [String: Any], let a = data["b_3"] as? String, let b = data["b_4"] as? String {
                    biliGuestCookie = "buvid3=" + a + "; buvid4=" + b
                }
            }
            headers["Cookie"] = biliGuestCookie
        }
        let json = try await get(base, items: items, headers: headers)
        guard (json["code"] as? Int) == 0 else {
            if (json["code"] as? Int) == -412 { biliGuestCookie = nil }
            throw LiveMonitorError.request("Bilibili 暂时无法读取，可能是访客限制或会话过期。可稍后重试，或连接自己的账号。")
        }
        return json
    }
    private func validateTwitch(token: String, clientID: String) async throws {
        guard token != twitchValidatedToken || clientID != twitchValidatedClientID || Date() >= twitchValidationUntil else { return }
        let json = try await get("https://id.twitch.tv/oauth2/validate", headers: ["Authorization": "OAuth " + token])
        guard json["client_id"] as? String == clientID, (json["expires_in"] as? Int ?? 0) > 0 else {
            throw LiveMonitorError.unavailable("Twitch 凭证已过期或 Client ID 不匹配，请重新连接。")
        }
        twitchValidatedToken = token; twitchValidatedClientID = clientID; twitchValidationUntil = Date().addingTimeInterval(3_600)
    }
    private func get(_ base: String, items: [String: String] = [:], headers: [String: String] = [:]) async throws -> [String: Any] {
        var url = URLComponents(string: base)!
        if !items.isEmpty { url.queryItems = items.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiveMonitorError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw LiveMonitorError.unavailable("接口凭证已过期或无效，请重新连接。") }
            if [403, 412, 429].contains(http.statusCode) { throw LiveMonitorError.request("平台限制了当前请求（\(http.statusCode)）。可稍后重试、连接账号，或在官网搜索后粘贴主播链接。") }
            throw LiveMonitorError.request("平台暂时不可用（HTTP \(http.statusCode)），未将此次错误当作下播。")
        }
        guard data.count < 8_388_608, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveMonitorError.invalidResponse }
        return json
    }
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private func string(_ value: Any?) -> String { value as? String ?? (value as? NSNumber)?.stringValue ?? "" }
    private func imageURL(_ value: String) -> String? { value.isEmpty ? nil : value.hasPrefix("//") ? "https:" + value : value }
    private func plain(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
