import AppKit
import SwiftUI
import Darwin

private struct ForbiddenDiscoveryExtractor: LiveExtracting {
    func metadata(_ address: String, cookies: String?, flat: Bool) async throws -> ExtractedLiveMedia {
        throw LiveMonitorError.unavailable("Discovery must not launch the external parser")
    }
}

private actor LiveFixtureExtractor: LiveExtracting {
    var text: String
    private var lastRequest: (address: String, authenticated: Bool, flat: Bool)?
    func lastCall() -> (address: String, authenticated: Bool, flat: Bool)? { lastRequest }
    init(_ text: String) { self.text = text }
    func metadata(_ address: String, cookies: String?, flat: Bool) async throws -> ExtractedLiveMedia {
        lastRequest = (address, cookies != nil, flat)
        return try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(text.utf8))
    }
}

private actor LiveRecordingFixtureService: LivePlatformServing {
    let url: URL
    let delay: UInt64
    init(url: URL, delay: UInt64 = 0) { self.url = url; self.delay = delay }
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }; return []
    }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate {
        CreatorCandidate(platform: platform, address: input, name: "夹具主播")
    }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }; return .init(state: .live, sessionID: "fixture")
    }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return .init(tracks: [.init(url: url, headers: [:], hasVideo: true, hasAudio: false)], title: "本地无声音录像夹具")
    }
}

private actor FlakyRecordingFixtureService: LivePlatformServing {
    var attempts = 0
    let url: URL
    init(url: URL) { self.url = url }
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] { [] }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate { .init(platform: platform, address: input, name: "重连夹具") }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot { .init(state: attempts < 2 ? .live : .offline) }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        attempts += 1
        if attempts == 1 { throw LiveMonitorError.unavailable("测试瞬时断流") }
        return .init(tracks: [.init(url: url, headers: [:], hasVideo: true, hasAudio: false)], title: "重连恢复")
    }
}

private actor RejectedRecordingFixtureService: LivePlatformServing {
    var attempts = 0
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] { [] }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate { .init(platform: platform, address: input, name: "拒绝访问夹具") }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot { .init(state: .live) }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        attempts += 1
        throw LiveMonitorError.request("平台拒绝直播流请求（403）。")
    }
}

private final class LiveFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let url = request.url!, path = url.path
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var code = 200
        let json: [String: Any]
        if query["room_id"] == "999" { code = 429; json = ["error": "limited"] }
        else if path.contains("finger/spi") { json = ["code": 0, "data": ["b_3": "fixture-guest", "b_4": "fixture-device"]] }
        else if path.contains("search/type") {
            json = ["code": 0, "data": ["result": [["roomid": 6, "uname": "<em>夹具主播</em>", "face": "//example.invalid/avatar.png", "title": "夹具直播"]]]]
        } else if path.contains("get_info"), query["room_id"] == "8" {
            json = ["code": 0, "data": ["room_id": 8, "uid": 404, "title": "Profile unavailable", "user_cover": "https://example.invalid/stream-cover.jpg"]]
        } else if path.contains("Master/info"), query["uid"] == "404" { code = 503; json = [:] }
        else if path.contains("get_info") {
            json = ["code": 0, "data": ["room_id": 6, "uid": 1, "live_status": 1, "live_time": "2026-10-22 12:00:00", "title": "夹具直播"]]
        } else if path.contains("Master/info") { json = ["code": 0, "data": ["info": ["uname": "夹具主播", "face": "https://example.invalid/a.png"]]] }
        else if path.contains("youtube/v3/search") { json = ["items": [["id": ["channelId": "UCfixture"], "snippet": ["title": "YouTube 夹具", "description": "channel"]]]] }
        else if path.contains("oauth2/validate") {
            if request.value(forHTTPHeaderField: "Authorization")?.contains("bad") == true { code = 401; json = [:] }
            else { json = ["client_id": "fixture-client", "expires_in": 3600] }
        } else if path.contains("search/channels") { json = ["data": [["broadcaster_login": "fixture", "display_name": "Twitch 夹具", "title": "stream"]]] }
        else if path.contains("helix/users") { json = ["data": [["display_name": "Twitch 夹具"]]] }
        else if path.contains("helix/streams") {
            json = query["user_login"] == "offline" ? ["data": []] : ["data": [["id": "stream1", "title": "夹具直播", "started_at": "2026-10-22T04:00:00Z"]]]
        } else { code = 404; json = [:] }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
enum LiveMonitorChecks {
    private static var started = false
    static func runIfRequested(monitor: LiveMonitorStore, appearance: HomeAppearance) async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--live-monitor-check"), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }; started = true
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }; checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if CommandLine.arguments.contains("--twitch-check-only") {
                try await TwitchChecks.run(directory: directory); Darwin.exit(0)
            }
            if CommandLine.arguments.contains("--connectivity-platform") {
                do { try await LiveConnectivityChecks.run(directory: directory); Darwin.exit(0) }
                catch { print("Connectivity check: " + error.localizedDescription); Darwin.exit(1) }
            }
            if CommandLine.arguments.contains("--browser-login-check") {
                let suite = "SimuSub.RealBrowserLogin." + UUID().uuidString
                let defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let credentials = LiveCredentials(defaults: defaults)
                for platform in [LivePlatform.youtube, .bilibili] {
                    await credentials.refreshBrowserSession(platform)
                    try require(credentials.selectedSource(platform) == .browser, "real_" + platform.rawValue + "_browser_login_highlight")
                }
                try await render(VStack(spacing: 20) {
                    PlatformConnectionCard(platform: .bilibili, credentials: credentials)
                    PlatformConnectionCard(platform: .youtube, credentials: credentials)
                }.padding(28).environmentObject(appearance).preferredColorScheme(.dark), name: "浏览器登录高亮", directory: directory)
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
                Darwin.exit(0)
            }
            if let captureIndex = CommandLine.arguments.firstIndex(of: "--browser-recording-check"), captureIndex + 1 < CommandLine.arguments.count {
                let address = try LiveAddress.normalize(CommandLine.arguments[captureIndex + 1], platform: .youtube)
                let service = LivePlatformService(extractor: ForbiddenDiscoveryExtractor(), youtube: YouTubePublicClient())
                let store = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("store")), service: service, credentials: monitor.credentials, notificationsEnabled: false)
                store.updateSettings { $0.outputFolder = directory.appendingPathComponent("videos").path; $0.container = .mp4 }
                store.follow(.init(platform: .youtube, address: "https://www.youtube.com/channel/UCSJ4gkVC6NrvII8umztf0Ow", name: "浏览器真实直播录制验证"))
                let creatorID = store.creators[0].id
                store.applySnapshot(.init(state: .live, title: "浏览器直连验证", liveURL: address), to: creatorID)
                let started = Date()
                store.startRecording(creatorID)
                for _ in 0..<500 {
                    if store.recordings.first?.state == .recording || !store.hasActiveRecordings { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let connectedSeconds = Date().timeIntervalSince(started)
                if store.recordings.first?.state != .recording { print("CAPTURE: " + (store.recordings.first?.message ?? "missing state")) }
                try require(store.recordings.first?.state == .recording, "browser_real_record_button_reaches_recording")
                try await Task.sleep(nanoseconds: 10_000_000_000)
                let id = store.recordings[0].id
                store.stopRecording(id)
                for _ in 0..<300 { if !store.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                let saved = store.recordings[0]
                try require(saved.state == .completed && saved.savedBytes > 10_000, "browser_real_stop_preserves_video")
                guard let file = saved.closedMediaURLs.first else { throw LiveMonitorError.invalidResponse }
                let result = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height", "-of", "json", file.path])
                let media = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] ?? [:]
                let streams = media["streams"] as? [[String: Any]] ?? []
                try require(streams.contains { $0["codec_type"] as? String == "video" } && streams.contains { $0["codec_type"] as? String == "audio" }, "browser_real_saved_video_and_audio")
                await store.shutdown()
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "connectedSeconds": connectedSeconds, "media": media, "file": file.path, "externalParserLaunched": false], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
                Darwin.exit(0)
            }
            if let realIndex = CommandLine.arguments.firstIndex(of: "--live-real-url"), CommandLine.arguments.count > realIndex + 1 {
                let address = try LiveAddress.normalize(CommandLine.arguments[realIndex + 1], platform: .youtube)
                let access = LivePlatformAccess()
                try require(access.cookies == nil, "real_public_access_without_browser_or_cookies")
                let noExtractor = CommandLine.arguments.contains("--public-discovery-only")
                let service = noExtractor ? LivePlatformService(extractor: ForbiddenDiscoveryExtractor(), youtube: YouTubePublicClient()) : LivePlatformService()
                let creator = WatchedCreator(CreatorCandidate(platform: .youtube, address: address, name: "YouTube 真实直播验证"))
                let snapshot = try await service.status(creator, access: access)
                try require(noExtractor ? snapshot.state != .unknown : snapshot.state == .live, "real_youtube_explicit_state")
                if CommandLine.arguments.contains("--public-discovery-only") {
                    let searchStart = Date()
                    let results = try await service.search("家長むぎ", platform: .youtube, access: access)
                    let searchSeconds = Date().timeIntervalSince(searchStart)
                    try require(results.contains { $0.address == address }, "real_public_search_finds_followed_creator")
                    let resolved = try await service.resolve("@IenagaMugi", platform: .youtube, access: access)
                    try require(resolved.address == address, "real_public_handle_resolves_to_channel")
                    guard let avatar = results.first(where: { $0.address == address })?.avatarURL, let avatarURL = URL(string: avatar) else { throw LiveMonitorError.invalidResponse }
                    let (imageData, _) = try await URLSession.shared.data(from: avatarURL)
                    try require(NSImage(data: imageData) != nil, "real_channel_avatar_downloads_and_decodes")
                    try imageData.write(to: directory.appendingPathComponent("channel-avatar.jpg"))
                    monitor.follow(resolved)
                    if let id = monitor.creators.first?.id { monitor.applySnapshot(snapshot, to: id) }
                    try await render(RecordingWorkspace(onSettings: {}, onClips: { _ in }).environmentObject(monitor).environmentObject(appearance), name: "真实主播头像与直播", directory: directory, delay: 2)
                    try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "realCredentialsUsed": false, "recordingVerified": false, "searchSeconds": searchSeconds, "state": snapshot.state.rawValue, "externalParserLaunched": false], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
                    Darwin.exit(0)
                }
                let input = try await service.recordingInput(creator, access: access)
                let output = directory.appendingPathComponent("youtube-live.mkv")
                var args = try LiveRecordingEngine.arguments(input: input, output: output)
                args.insert(contentsOf: ["-t", "20"], at: args.count - 1)
                let result = try await LiveTools.run("ffmpeg", arguments: args, timeout: 65)
                try require(result.status == 0 && LiveRecordingEngine.fileSize(output.path) > 10_000, "real_youtube_recording_saved")
                let probe = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-show_entries", "format=duration,size:stream=codec_type,codec_name,width,height", "-of", "json", output.path])
                let fields = try JSONSerialization.jsonObject(with: probe.data) as? [String: Any]
                let streams = fields?["streams"] as? [[String: Any]] ?? []
                try require(streams.contains { $0["codec_type"] as? String == "video" } && streams.contains { $0["codec_type"] as? String == "audio" }, "real_recording_has_video_and_audio")
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "media": fields ?? [:], "realCredentialsUsed": false, "credentialsPersisted": false], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
                Darwin.exit(0)
            }
            try await TwitchChecks.run(directory: directory)
            try await LiveNetworkChecks.run()
            try require(try LiveAddress.normalize("6", platform: .bilibili) == "https://live.bilibili.com/6", "bili_room_number")
            try require(try LiveAddress.normalize("https://live.bilibili.com/6?broadcast_type=0", platform: .bilibili) == "https://live.bilibili.com/6", "bili_url_canonical")
            try require(try LiveAddress.normalize("Test_Name", platform: .twitch) == "https://www.twitch.tv/test_name", "twitch_login_canonical")
            try require(try LiveAddress.normalize("@fixture", platform: .youtube) == "https://www.youtube.com/@fixture", "youtube_handle")
            try require(try LiveAddress.normalize("https://youtu.be/abcdef12345", platform: .youtube).contains("watch?v=abcdef12345"), "youtube_video_to_resolvable_url")
            try require(try LiveAddress.normalize("https://www.youtube.com/live/abcdef12345?si=share", platform: .youtube) == "https://www.youtube.com/watch?v=abcdef12345", "youtube_live_share_url")
            for text in ["file:///etc/passwd", "http://live.bilibili.com/6", "https://evil.example/6", "https://user:pass@live.bilibili.com/6", "https://live.bilibili.com:123/6"] {
                try require((try? LiveAddress.normalize(text, platform: .bilibili)) == nil, "reject_untrusted_address_\(checks.count)")
            }
            let future = Int(Date().addingTimeInterval(86_400).timeIntervalSince1970)
            let cookies = "# Netscape HTTP Cookie File\n#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t\(future)\tSID\tfixture-not-real\n.evil.example\tTRUE\t/\tTRUE\t\(future)\tBAD\tx\n.youtube.com\tTRUE\t/\tTRUE\t1\tEXPIRED\tx\n"
            try require(LiveCookie.parse(cookies, platform: .youtube).count == 1, "cookies_expired_and_foreign_filtered")
            try require(LiveCookie.header(cookies, platform: .youtube, url: URL(string: "https://www.youtube.com/live")!) == "SID=fixture-not-real", "cookie_header_matching_domain")
            try require(LiveCookie.header(cookies, platform: .youtube, url: URL(string: "https://evil.example/live")!) == nil, "cookie_never_sent_other_domain")
            let loginCookies = cookies.replacingOccurrences(of: "\tSID\t", with: "\tSAPISID\t")
            try require(LiveCookie.hasLoginSession(loginCookies, platform: .youtube), "youtube_auth_cookie_recognized")
            try require(!LiveCookie.hasLoginSession(loginCookies.replacingOccurrences(of: "\tSAPISID\t", with: "\tPREF\t"), platform: .youtube), "youtube_preferences_are_not_login")
            try require(!LiveCookie.hasLoginSession(loginCookies.replacingOccurrences(of: String(future), with: "1"), platform: .youtube), "expired_login_rejected")
            try require(!LiveCookie.hasLoginSession(loginCookies, platform: .twitch), "login_is_platform_scoped")
            var lease: LiveCookieLease? = try LiveCookieLease(cookies)
            let leaseFile = lease!.file
            let attributes = try FileManager.default.attributesOfItem(atPath: leaseFile.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "temporary_cookie_mode_0600")
            lease = nil
            try require(!FileManager.default.fileExists(atPath: leaseFile.path), "temporary_cookie_removed")

            checks += try await YouTubeRoutingChecks.run()
            checks += try await BrowserAccountChecks.run()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LiveFixtureProtocol.self]
            let extractor = LiveFixtureExtractor(#"{"id":"video1","channel_id":"UCfixture","channel":"YouTube 夹具","title":"夹具直播","is_live":true,"live_status":"is_live","url":"https://example.invalid/live.m3u8","vcodec":"h264","acodec":"aac","entries":[{"id":"video1","live_status":"is_live","title":"夹具直播","channel_id":"UCfixture","channel":"YouTube 夹具"},{"channel_id":"UCfixture","channel":"重复"}]}"#)
            let service = LivePlatformService(session: URLSession(configuration: config), extractor: extractor)
            let guest = LivePlatformAccess()
            let bili = try await service.search("夹具", platform: .bilibili, access: guest)
            try require(bili.count == 1 && bili[0].name == "夹具主播", "bili_guest_search_and_html_cleanup")
            try require(LiveFixtureProtocol.lock.withLock { LiveFixtureProtocol.requests.contains { $0.value(forHTTPHeaderField: "Cookie")?.contains("buvid3=fixture-guest") == true } }, "bili_guest_handshake")
            let resolved = try await service.resolve("6", platform: .bilibili, access: guest)
            try require(resolved.name == "夹具主播" && resolved.address.hasSuffix("/6"), "bili_resolve_canonical_anchor")
            try require(resolved.avatarURL == "https://example.invalid/a.png", "bili_avatar_from_profile")
            let missingProfile = try await service.resolve("8", platform: .bilibili, access: guest)
            try require(missingProfile.avatarURL == nil, "bili_missing_profile_never_uses_stream_cover")
            let live = try await service.status(WatchedCreator(resolved), access: guest)
            try require(live.state == .live && live.sessionID != nil, "bili_real_status_decode")
            let youtube = try await service.search("夹具", platform: .youtube, access: guest)
            try require(youtube.count == 1 && youtube[0].address.contains("/channel/UCfixture"), "youtube_guest_channel_search_dedup")
            let ytOfficial = try await service.search("夹具", platform: .youtube, access: .init(apiKey: "fixture-key"))
            try require(ytOfficial.count == 1, "youtube_official_search")
            let ytCreator = try await service.resolve("@fixture", platform: .youtube, access: guest)
            try require(ytCreator.address.contains("/channel/UCfixture"), "youtube_channel_resolve")
            try require(try await service.status(WatchedCreator(ytCreator), access: guest).state == .live, "youtube_live_decode")
            _ = try await service.status(WatchedCreator(ytCreator), access: .init(cookies: "expired optional session"))
            let publicStatusCall = await extractor.lastCall()
            try require(publicStatusCall?.flat == true && publicStatusCall?.authenticated == false && publicStatusCall?.address.hasSuffix("/streams") == true, "youtube_status_does_not_require_video_playback_or_login")
            let past = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"entries":[{"id":"past001","live_status":"was_live"}]}"#.utf8))
            try require(try LivePlatformService.youtubeSnapshot(past, channel: ytCreator.address).state == .offline, "youtube_public_archive_is_offline")
            let unknown = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"entries":[{"id":"unknown1"}]}"#.utf8))
            try require((try? LivePlatformService.youtubeSnapshot(unknown, channel: ytCreator.address)) == nil, "youtube_missing_public_status_not_assumed_offline")
            let upcoming = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"entries":[{"id":"upcoming1","live_status":"is_upcoming"}]}"#.utf8))
            try require(try LivePlatformService.youtubeSnapshot(upcoming, channel: ytCreator.address).state == .upcoming, "youtube_public_scheduled_stream_detected")

            let twitchAccess = LivePlatformAccess(clientID: "fixture-client", accessToken: "fixture-token")
            let twitch = try await service.search("夹具", platform: .twitch, access: twitchAccess)
            try require(twitch.count == 1 && twitch[0].name == "Twitch 夹具", "twitch_official_search")
            try require(try await service.status(WatchedCreator(twitch[0]), access: twitchAccess).state == .live, "twitch_live_decode")
            let offline = WatchedCreator(CreatorCandidate(platform: .twitch, address: "https://www.twitch.tv/offline", name: "Offline"))
            try require(try await service.status(offline, access: twitchAccess).state == .offline, "twitch_explicit_offline")
            var unauthorized = false
            do { _ = try await service.search("夹具", platform: .twitch, access: .init(clientID: "fixture-client", accessToken: "bad")) } catch { unauthorized = true }
            try require(unauthorized, "invalid_token_not_offline")
            let limited = WatchedCreator(CreatorCandidate(platform: .bilibili, address: "https://live.bilibili.com/999", name: "Limited"))
            var rateLimited = false
            do { _ = try await service.status(limited, access: guest) } catch { rateLimited = true }
            try require(rateLimited, "http_429_not_offline")

            let storage = LiveMonitorStorage(root: directory.appendingPathComponent("storage"))
            let store = LiveMonitorStore(storage: storage, service: service, credentials: monitor.credentials, notificationsEnabled: false)
            store.follow(resolved); store.follow(resolved)
            try require(store.creators.count == 1 && !store.creators[0].autoRecord, "follow_dedup_autorecord_opt_in")
            let id = store.creators[0].id
            try require(store.applySnapshot(live, to: id), "initial_live_event")
            try require(!store.applySnapshot(live, to: id), "duplicate_live_event_suppressed")
            try require(!store.applySnapshot(.init(state: .unknown), to: id) && store.creators[0].stableState == .live, "unknown_preserves_live")
            store.applySnapshot(.init(state: .offline), to: id)
            try require(store.creators[0].stableState == .live, "one_offline_not_end")
            store.applySnapshot(.init(state: .offline), to: id)
            try require(store.creators[0].stableState == .offline, "two_offline_confirm_end")
            try require(store.applySnapshot(live, to: id), "new_broadcast_event")
            let reloaded = LiveMonitorStore(storage: storage, service: service, credentials: monitor.credentials, notificationsEnabled: false)
            try require(!reloaded.applySnapshot(live, to: id) && reloaded.creators.count == 1, "relaunch_persistence_and_dedup")
            let saved = try String(contentsOf: storage.root.appendingPathComponent("creators.json"))
            try require(!saved.contains("fixture-token") && !saved.contains("fixture-not-real"), "no_credentials_in_json")
            store.updateSettings { $0.maximumRecordings = 100; $0.intervalSeconds = 1 }
            try require(store.settings.maximumRecordings == 3 && store.settings.intervalSeconds == 15, "settings_bounds")
            store.follow(.init(platform: .bilibili, address: limited.address, name: "Limited"))
            await store.refresh(force: true)
            try require(store.creators[1].lastError != nil && store.creators[1].failureCount == 1 && (store.creators[1].nextCheckAt ?? .distantPast) > Date(), "failure_backoff_and_error_visible")
            let corrupt = directory.appendingPathComponent("corrupt")
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            let corruptFile = corrupt.appendingPathComponent("creators.json")
            try Data("broken".utf8).write(to: corruptFile)
            let corruptStorage = LiveMonitorStorage(root: corrupt)
            _ = corruptStorage.load([WatchedCreator].self, name: "creators", fallback: [])
            try? corruptStorage.save([WatchedCreator](), name: "creators")
            try require(try String(contentsOf: corruptFile) == "broken", "corrupt_index_not_overwritten")

            let input = try await service.recordingInput(WatchedCreator(ytCreator), access: guest)
            let args = try LiveRecordingEngine.arguments(input: input, output: directory.appendingPathComponent("capture.mp4"))
            try require(args.contains("+frag_keyframe+empty_moov") && args.contains("copy"), "recording_copy_and_fragmented_mp4")
            let segmented = try LiveRecordingEngine.arguments(input: input, output: URL(fileURLWithPath: "/tmp/attempt01-%06d.mkv"), segmentSeconds: 300)
            try require(segmented.contains("segment") && segmented.contains("300") && segmented.contains("-reset_timestamps"), "recording_segment_muxer_and_media_clock")
            let unknownAudio = ResolvedLiveInput(tracks: [.init(url: URL(string: "https://example.invalid/live.flv")!, headers: [:], hasVideo: true, hasAudio: false)], title: "Unknown codec metadata")
            let optionalAudio = try LiveRecordingEngine.arguments(input: unknownAudio, output: directory.appendingPathComponent("unknown.mkv"))
            try require(optionalAudio.contains("0:a:0?"), "muxed_live_unknown_audio_metadata_maps_optional_audio")
            let splitUnknown = ResolvedLiveInput(tracks: [unknownAudio.tracks[0], .init(url: URL(string: "https://example.invalid/audio")!, headers: [:], hasVideo: false, hasAudio: false)], title: "Split audio")
            try require(try LiveRecordingEngine.arguments(input: splitUnknown, output: directory.appendingPathComponent("split.mkv")).contains("1:a:0?"), "separate_unknown_audio_input_preferred_over_video_input")
            try require(!LiveRecordingEngine.safeName("../../危险/名称").contains("/"), "recording_filename_sanitized")
            try require(LiveTools.available, "all_recording_tools_bundled")
            let progress = LiveRecordingProgress()
            try require(!progress.consume(Data("frame=0\nprogress=continue\nfra".utf8)) && !progress.hasVideo, "recording_no_save_before_actual_video_frame")
            try require(progress.consume(Data("me= 1\nprogress=continue\n".utf8)) && progress.hasVideo && !progress.consume(Data("frame=2\n".utf8)), "recording_progress_handles_split_lines_once")
            try require(LiveRecordingState.preparing.controlTitle == "连接中" && LiveRecordingState.recording.controlTitle == "保存", "recording_controls_distinguish_connecting_and_saving")
            let secretError = "https://live.invalid/stream?token=secret Cookie: private HTTP error 403 Forbidden"
            try require(LiveRecordingEngine.failureMessage(secretError).contains("平台拒绝") && !LiveRecordingEngine.failureMessage(secretError).contains("secret"), "recording_failure_reason_redacts_stream_urls_and_credentials")
            try require(LiveRecordingEngine.failureMessage("Connection timed out").contains("超时") && LiveRecordingEngine.failureMessage("No space left on device").contains("磁盘空间不足"), "recording_failure_distinguishes_timeout_and_disk")
            for name in ["yt-dlp", "deno", "ffmpeg"] {
                let result = try await LiveTools.run(name, arguments: [name == "ffmpeg" ? "-version" : "--version"])
                try require(result.status == 0 && !result.data.isEmpty, "tool_runs_" + name)
            }
            weak var releasedJob: LiveToolProcess?
            do {
                let temporaryJob = LiveToolProcess(); releasedJob = temporaryJob
                _ = try await temporaryJob.run("deno", arguments: ["--version"])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(releasedJob == nil, "completed_tool_job_released_without_cycle")
            let job = LiveToolProcess()
            let silentFile = directory.appendingPathComponent("silent-stop.mkv")
            let task = Task {
                try await job.run("ffmpeg", arguments: ["-hide_banner", "-loglevel", "error", "-n", "-re", "-f", "lavfi", "-i", "color=c=black:s=160x90:r=10", "-t", "30", "-an", "-c:v", "mpeg4", silentFile.path], timeout: 15)
            }
            for _ in 0..<50 { if job.isRunning { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let pid = job.processID
            job.requestStop()
            let output = try await task.value
            try require(output.status == 0 && LiveRecordingEngine.fileSize(silentFile.path) > 0, "silent_ffmpeg_graceful_stop_saves_video")
            try await Task.sleep(nanoseconds: 100_000_000)
            try require(!job.isRunning && pid.map { kill(-$0, 0) != 0 } == true, "no_recording_process_after_stop")
            let cancelledJob = LiveToolProcess()
            let cancelledTask = Task { try await cancelledJob.run("deno", arguments: ["eval", "await new Promise(r=>setTimeout(r,30000));"], timeout: 20) }
            for _ in 0..<30 { if cancelledJob.isRunning { break }; try await Task.sleep(nanoseconds: 100_000_000) }
            cancelledJob.cancel()
            var cancelled = false
            do { _ = try await cancelledTask.value } catch is CancellationError { cancelled = true }
            try require(cancelled && !cancelledJob.isRunning, "metadata_process_cancelled_without_orphan")
            let longProgress = LiveRecordingProgress()
            let longProgressFile = directory.appendingPathComponent("long.progress")
            var longData = Data(repeating: 120, count: 9 * 1024 * 1024); longData.append(Data("\nframe=1\n".utf8))
            try longData.write(to: longProgressFile)
            for _ in 0..<160 { if longProgress.poll(longProgressFile) { break } }
            try require(longProgress.hasVideo && !longProgress.poll(longProgressFile), "long_recording_progress_file_is_read_incrementally_without_stdout_limit")

            if let fixtureFlag = CommandLine.arguments.firstIndex(of: "--recording-fixture"), CommandLine.arguments.count > fixtureFlag + 1,
               let fixtureURL = URL(string: CommandLine.arguments[fixtureFlag + 1]), fixtureURL.host == "127.0.0.1" {
                let recordStorage = LiveMonitorStorage(root: directory.appendingPathComponent("recording-lifecycle"))
                let recordStore = LiveMonitorStore(storage: recordStorage, service: LiveRecordingFixtureService(url: fixtureURL), credentials: monitor.credentials, notificationsEnabled: false)
                recordStore.updateSettings { $0.outputFolder = directory.appendingPathComponent("recorded-videos").path; $0.maximumRecordings = 1 }
                recordStore.follow(resolved); recordStore.follow(twitch[0])
                recordStore.startRecording(recordStore.creators[0].id)
                recordStore.startRecording(recordStore.creators[1].id)
                try require(recordStore.activeRecordings.count == 1, "recording_concurrency_gate")
                for _ in 0..<150 { if !recordStore.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                try require(recordStore.recordings.first?.state == .completed && (recordStore.recordings.first?.bytes ?? 0) > 0, "recording_store_real_http_remux_and_completion")
                try require(!recordStore.hasActiveRecordings && recordStore.activeRecordings.isEmpty, "recording_store_task_cleanup")
                let saved = recordStore.recordings[0]
                try require(saved.segmentFolder != nil && saved.mediaURLs.count == 1 && saved.closedMediaURLs.count == 1, "recording_segment_history_discoverable")
                var active = saved; active.state = .recording
                try require(active.closedMediaURLs.count == 1, "recording_closed_csv_segment_safe_during_recording")
                let legacy = LiveRecording(creatorID: saved.creatorID, platform: .bilibili, creatorName: "Legacy", title: "Old", state: .completed, path: saved.mediaURLs[0].path)
                var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
                encoded.removeValue(forKey: "segmentFolder")
                let decoded = try JSONDecoder().decode(LiveRecording.self, from: JSONSerialization.data(withJSONObject: encoded))
                try require(decoded.mediaURLs.count == 1, "recording_v109_json_migration")
                var interrupted = recordStore.recordings[0]; interrupted.state = .recording
                try recordStorage.save([interrupted], name: "recordings")
                let restored = LiveMonitorStore(storage: recordStorage, credentials: monitor.credentials, notificationsEnabled: false)
                try require(restored.recordings[0].state == .interrupted && restored.recordings[0].bytes > 0, "crash_recovery_preserves_recorded_file")
                let parts = directory.appendingPathComponent("keyframe-segments")
                try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
                let segmentedInput = ResolvedLiveInput(tracks: [.init(url: fixtureURL, headers: [:], hasVideo: true, hasAudio: false)], title: "Segments")
                let partResult = try await LiveTools.run("ffmpeg", arguments: LiveRecordingEngine.arguments(input: segmentedInput, output: parts.appendingPathComponent("part-%06d.mkv"), segmentSeconds: 1))
                let partFiles = try FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mkv" }
                try require(partResult.status == 0 && partFiles.count >= 2, "recording_real_keyframe_segment_rotation")
                let flaky = FlakyRecordingFixtureService(url: fixtureURL)
                let retryStore = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("retry-store")), service: flaky, credentials: monitor.credentials, notificationsEnabled: false)
                retryStore.updateSettings { $0.outputFolder = directory.appendingPathComponent("retry-videos").path }
                retryStore.follow(resolved); retryStore.startRecording(retryStore.creators[0].id)
                for _ in 0..<150 { if !retryStore.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                let retryAttempts = await flaky.attempts
                try require(retryAttempts == 2 && retryStore.recordings[0].state == .completed && retryStore.recordings[0].mediaURLs[0].lastPathComponent.hasPrefix("attempt02"), "recording_reconnect_resolves_fresh_stream_and_keeps_attempts_separate")
                await retryStore.shutdown()
                let cancelledFlaky = FlakyRecordingFixtureService(url: fixtureURL)
                let cancelledRetry = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("cancel-retry-store")), service: cancelledFlaky, credentials: monitor.credentials, notificationsEnabled: false)
                cancelledRetry.updateSettings { $0.outputFolder = directory.appendingPathComponent("cancel-retry-videos").path }
                cancelledRetry.follow(resolved); cancelledRetry.startRecording(cancelledRetry.creators[0].id)
                for _ in 0..<30 { if cancelledRetry.recordings[0].message?.contains("重连") == true { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                cancelledRetry.stopRecording(cancelledRetry.recordings[0].id)
                await cancelledRetry.shutdown()
                let cancelledAttempts = await cancelledFlaky.attempts
                try require(cancelledAttempts == 1 && !cancelledRetry.hasActiveRecordings, "recording_manual_stop_during_backoff_prevents_reconnect")
                try require(cancelledRetry.recordings[0].state == .cancelled && cancelledRetry.recordings[0].stopReason == .user && cancelledRetry.recordings[0].message?.contains("已手动停止") == true, "cancelled_reconnect_is_not_reported_as_recording_interruption")
                let waitingStorage = LiveMonitorStorage(root: directory.appendingPathComponent("waiting-cancel-store"))
                let waiting = LiveMonitorStore(storage: waitingStorage, service: LiveRecordingFixtureService(url: fixtureURL, delay: 30_000_000_000), credentials: monitor.credentials, notificationsEnabled: false)
                waiting.updateSettings { $0.outputFolder = directory.appendingPathComponent("waiting-cancel-videos").path }
                waiting.follow(resolved); waiting.startRecording(waiting.creators[0].id)
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(waiting.recordings[0].state == .preparing && waiting.recordings[0].savedBytes == 0, "metadata_connection_stays_preparing_without_video")
                let connectingDefaults = UserDefaults(suiteName: "SimuSub.ConnectingRender." + UUID().uuidString)!
                connectingDefaults.set(true, forKey: "home.dark.v099")
                let connectingAppearance = HomeAppearance(defaults: connectingDefaults, backgroundFile: directory.appendingPathComponent("no-state-background.png"))
                try await render(RecordingWorkspace(onSettings: {}, onClips: { _ in }).environmentObject(connectingAppearance).environmentObject(waiting).preferredColorScheme(.dark), name: "连接中-等待画面", directory: directory)
                waiting.stopRecording(waiting.recordings[0].id)
                for _ in 0..<50 { if !waiting.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                try require(waiting.recordings[0].state == .cancelled && waiting.recordings[0].message?.contains("未生成录像") == true, "metadata_cancel_has_explicit_no_file_explanation")
                let waitingReloaded = LiveMonitorStore(storage: waitingStorage, credentials: monitor.credentials, notificationsEnabled: false)
                try require(waitingReloaded.recordings[0].stopReason == .user && waitingReloaded.recordings[0].message == waiting.recordings[0].message, "recording_stop_reason_survives_relaunch")
                await waiting.shutdown()
                let rejectedService = RejectedRecordingFixtureService()
                let rejected = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("rejected-store")), service: rejectedService, credentials: monitor.credentials, notificationsEnabled: false)
                rejected.updateSettings { $0.outputFolder = directory.appendingPathComponent("rejected-videos").path }
                rejected.follow(resolved); rejected.startRecording(rejected.creators[0].id)
                for _ in 0..<600 { if !rejected.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                let rejectedAttempts = await rejectedService.attempts
                try require(rejectedAttempts == 4 && rejected.recordings[0].state == .failed && rejected.recordings[0].message?.contains("403") == true && rejected.recordings[0].message?.contains("已重试 3 次") == true, "exhausted_retries_preserve_actual_platform_failure_and_count")
                await rejected.shutdown()
                if let connectFlag = CommandLine.arguments.firstIndex(of: "--recording-connect-fixture"), CommandLine.arguments.count > connectFlag + 1,
                   let connectURL = URL(string: CommandLine.arguments[connectFlag + 1]), connectURL.host == "127.0.0.1" {
                    let connecting = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("connecting-process-store")), service: LiveRecordingFixtureService(url: connectURL), credentials: monitor.credentials, notificationsEnabled: false)
                    connecting.updateSettings { $0.outputFolder = directory.appendingPathComponent("connecting-process-videos").path }
                    connecting.follow(resolved); connecting.startRecording(connecting.creators[0].id)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try require(connecting.recordings[0].state == .preparing && connecting.recordings[0].savedBytes == 0 && connecting.recordings[0].message?.contains("等待画面") == true, "ffmpeg_connection_without_packets_does_not_show_save")
                    let cancelStart = Date(); connecting.stopRecording(connecting.recordings[0].id)
                    for _ in 0..<240 { if !connecting.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                    try require(!connecting.hasActiveRecordings && Date().timeIntervalSince(cancelStart) < 12 && connecting.recordings[0].state == .cancelled, "cancel_waiting_ffmpeg_process_without_orphan_or_false_interruption")
                    await connecting.shutdown()
                }
                if let slowFlag = CommandLine.arguments.firstIndex(of: "--recording-stop-fixture"), CommandLine.arguments.count > slowFlag + 1,
                   let slowURL = URL(string: CommandLine.arguments[slowFlag + 1]), slowURL.host == "127.0.0.1" {
                    let stopping = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("stop-live-store")), service: LiveRecordingFixtureService(url: slowURL), credentials: monitor.credentials, notificationsEnabled: false)
                    stopping.updateSettings { $0.outputFolder = directory.appendingPathComponent("stopped-live-videos").path }
                    stopping.follow(resolved); stopping.startRecording(stopping.creators[0].id)
                    for _ in 0..<200 { if (stopping.recordings.first?.savedBytes ?? 0) > 1024 { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                    try require(stopping.recordings[0].savedBytes > 1024 && stopping.hasActiveRecordings, "recording_receives_real_slow_http_live_packets")
                    for _ in 0..<50 { if stopping.recordings[0].state == .recording { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                    try require(stopping.recordings[0].state == .recording && stopping.recordings[0].state.controlTitle == "保存", "real_video_frames_switch_connecting_to_save")
                    try await render(RecordingWorkspace(onSettings: {}, onClips: { _ in }).environmentObject(connectingAppearance).environmentObject(stopping).preferredColorScheme(.dark), name: "录制中-可以保存", directory: directory)
                    let pausedID = stopping.recordings[0].id
                    stopping.pauseRecording(pausedID)
                    for _ in 0..<240 { if !stopping.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 50_000_000) }
                    try require(stopping.recordings[0].state == .paused && stopping.recordings[0].savedBytes > 0, "v120_pause_flushes_real_live_stream_into_playable_segment")
                    let preservedPaths = stopping.recordings[0].mediaURLs.map(\.path)
                    let resumedStore = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("stop-live-store")), service: LiveRecordingFixtureService(url: slowURL), credentials: monitor.credentials, notificationsEnabled: false)
                    try require(resumedStore.recordings[0].state == .paused, "v120_paused_recording_survives_store_reload")
                    stopping.resumeRecording(pausedID)
                    for _ in 0..<200 { if stopping.recordings[0].state == .recording && stopping.recordings[0].mediaURLs.count > preservedPaths.count { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                    try require(stopping.recordings[0].state == .recording && stopping.recordings[0].mediaURLs.count > preservedPaths.count && preservedPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "v120_resume_creates_new_attempt_without_overwriting_previous_segment")
                    let stopTime = Date(); stopping.stopRecording(stopping.recordings[0].id); await stopping.shutdown()
                    try require(Date().timeIntervalSince(stopTime) < 12 && stopping.recordings[0].state == .completed, "recording_manual_stop_flushes_and_finishes_promptly")
                    try require(stopping.recordings[0].stopReason == .user && stopping.recordings[0].message?.contains("已手动停止") == true, "normal_recording_save_records_user_stop_reason")
                    let playable = try await ClipMediaEngine.inspect(stopping.recordings[0].mediaURLs[0])
                    try require(playable.duration > 0 && playable.width == 640, "recording_stopped_segment_is_decodable_for_clipping")
                }
                if let audioFlag = CommandLine.arguments.firstIndex(of: "--recording-audio-fixture"), CommandLine.arguments.count > audioFlag + 1,
                   let audioURL = URL(string: CommandLine.arguments[audioFlag + 1]), audioURL.host == "127.0.0.1" {
                    let audioStore = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("unknown-audio-store")), service: LiveRecordingFixtureService(url: audioURL), credentials: monitor.credentials, notificationsEnabled: false)
                    audioStore.updateSettings { $0.outputFolder = directory.appendingPathComponent("unknown-audio-videos").path }
                    audioStore.follow(resolved); audioStore.startRecording(audioStore.creators[0].id)
                    for _ in 0..<150 { if !audioStore.hasActiveRecordings { break }; try await Task.sleep(nanoseconds: 100_000_000) }
                    let recorded = try await ClipMediaEngine.inspect(audioStore.recordings[0].mediaURLs[0])
                    try require(audioStore.recordings[0].state == .completed && recorded.hasAudio, "recording_real_muxed_audio_preserved_when_extractor_metadata_unknown")
                    let sample = directory.appendingPathComponent("recorded-audio-clip.mp4")
                    try await ClipMediaEngine.cut(media: recorded, range: ClipRange(title: "Audio regression", start: 0.5, end: 3.5), output: sample)
                    let clipped = try await ClipMediaEngine.inspect(sample)
                    try require(clipped.hasAudio && abs(clipped.duration - 3) < 0.1, "recorded_unknown_audio_source_clips_to_audible_mp4")
                    await audioStore.shutdown()
                }
                await recordStore.shutdown()
                let pending = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("pending-shutdown")),
                    service: LiveRecordingFixtureService(url: fixtureURL, delay: 30_000_000_000), credentials: monitor.credentials, notificationsEnabled: false)
                pending.updateSettings { $0.outputFolder = directory.appendingPathComponent("pending-videos").path }
                pending.follow(resolved); pending.startMonitoring(); pending.startRecording(pending.creators[0].id)
                let pendingSearch = Task { await pending.search("fixture", platform: .bilibili) }
                try await Task.sleep(nanoseconds: 100_000_000)
                let shutdownStart = Date()
                await pending.shutdown(); await pendingSearch.value
                try require(Date().timeIntervalSince(shutdownStart) < 3 && !pending.hasActiveRecordings && !pending.isMonitoring,
                            "shutdown_cancels_pending_recording_search_and_poll")
                try require(pending.recordings[0].state == .cancelled && pending.recordings[0].stopReason == .applicationExit && pending.recordings[0].message?.contains("应用退出") == true, "application_exit_during_connection_has_clear_reason_without_false_interruption")
            }

            // Clearly labeled fixtures stay inside a temporary diagnostic store.
            for platform in LivePlatform.allCases {
                monitor.follow(CreatorCandidate(platform: platform, address: platform == .bilibili ? "https://live.bilibili.com/6" : platform == .youtube ? "https://www.youtube.com/@fixture" : "https://www.twitch.tv/fixture", name: platform.title + " 演示主播（测试数据）"))
            }
            for creator in monitor.creators { monitor.applySnapshot(.init(state: .live, title: "界面检查专用 · 不是真实开播数据", sessionID: "fixture"), to: creator.id) }
            try await Task.sleep(nanoseconds: 300_000_000)
            for scheme in [ColorScheme.light, .dark] {
                let homeDefaults = UserDefaults(suiteName: "SimuSub.HomeRender." + UUID().uuidString)!
                homeDefaults.set(scheme == .dark, forKey: "home.dark.v099")
                let previewAppearance = HomeAppearance(defaults: homeDefaults, backgroundFile: directory.appendingPathComponent("nonexistent-test-background.png"))
                try await render(RecordingWorkspace(onSettings: {}, onClips: { _ in }).environmentObject(previewAppearance).environmentObject(monitor).preferredColorScheme(scheme),
                                 name: scheme == .light ? "录制页-浅色" : "录制页-深色", directory: directory)
                try await render(LiveRecordingSettings().environmentObject(monitor).padding(28).preferredColorScheme(scheme),
                                 name: scheme == .light ? "录制设置-浅色" : "录制设置-深色", directory: directory)
            }
            checks += try await RecordingBehaviorChecks.run(directory: directory)
            checks += try await CreatorListChecks.run(directory: directory, credentials: monitor.credentials)
            let modelSuite = "SimuSub.ServiceLockChecks." + UUID().uuidString
            let modelDefaults = UserDefaults(suiteName: modelSuite)!
            let lockModel = AppModel(defaults: modelDefaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("empty-models")))
            defer { modelDefaults.removePersistentDomain(forName: modelSuite) }
            try require(lockModel.serviceSelectionLockReason == nil, "idle_model_selection_unlocked")
            lockModel.isCapturing = true
            try require(lockModel.isBusy && lockModel.serviceSelectionLockReason?.contains("停止后") == true, "running_model_selection_locked_with_explanation")
            try await render(AdvancedServiceSettings().environmentObject(lockModel), name: "模型切换限制", directory: directory)
            lockModel.isStopping = true
            try require(lockModel.serviceSelectionLockReason?.contains("最后一段") == true, "stopping_model_selection_explains_pending_subtitles")
            lockModel.isCapturing = false; lockModel.isStopping = false; lockModel.isProcessingFile = true
            try require(lockModel.serviceSelectionLockReason?.contains("处理音频") == true, "file_processing_model_lock_explained")
            lockModel.isProcessingFile = false
            try require(!lockModel.isBusy && lockModel.serviceSelectionLockReason == nil, "model_selection_unlocked_after_work")
            try require(true, "native_light_dark_ui_rendered")
            await store.shutdown()
            let report: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "passed": true, "checks": checks,
                "audioPlayback": false, "systemPermissionsChanged": false, "realCredentialsUsed": false]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
            print("PASS: \(checks.count) live monitor checks; no audio playback or permission changes")
            Darwin.exit(0)
        } catch {
            let report: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
            fputs("FAIL: \(error.localizedDescription)\n", stderr); Darwin.exit(1)
        }
    }
    private static func render<V: View>(_ root: V, name: String, directory: URL, delay: Double = 0.25) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.orderFront(nil)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
