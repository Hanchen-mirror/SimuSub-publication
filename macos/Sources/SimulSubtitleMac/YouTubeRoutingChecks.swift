import Foundation

private let channelFixture: [String: Any] = [
    "channelRenderer": ["channelId": "UCfixture", "title": ["simpleText": "Fixture {channel}"], "thumbnail": ["thumbnails": [["url": "//yt3.googleusercontent.com/avatar.jpg"]]]],
    "channelMetadataRenderer": ["externalId": "UCfixture", "title": "Fixture", "avatar": ["thumbnails": [["url": "https://yt3.googleusercontent.com/profile.jpg"]]]],
    "videoRenderer": ["videoId": "live12345", "title": ["runs": [["text": "Live fixture"]]], "thumbnailOverlays": [["thumbnailOverlayTimeStatusRenderer": ["style": "LIVE"]]]]
]

private actor RoutingBrowserFixture: LiveBrowserReading {
    let available: Bool
    let playable: Bool
    private(set) var calls = 0
    init(available: Bool, playable: Bool = true) { self.available = available; self.playable = playable }
    func page(_ url: URL, player: Bool) async -> [String: Any]? {
        calls += 1
        guard available else { return nil }
        if player {
            if !playable { return ["data": ["playabilityStatus": ["status": "LOGIN_REQUIRED"]]] }
            return ["data": ["microformat": ["playerMicroformatRenderer": ["liveBroadcastDetails": ["isLiveNow": true]]],
                             "streamingData": ["hlsManifestUrl": "https://example.invalid/live.m3u8"], "videoDetails": ["title": "Browser stream"]],
                    "userAgent": "Browser fixture", "cookies": []]
        }
        return ["data": channelFixture]
    }
}

private final class RoutingHTTPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests.append(request) }
        let json = try! JSONSerialization.data(withJSONObject: channelFixture)
        let data = Data("<script>var ytInitialData = ".utf8) + json + Data(";</script>".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor RoutingExtractorFixture: LiveExtracting {
    private(set) var calls = 0
    private(set) var cookies: String?
    func metadata(_ address: String, cookies: String?, flat: Bool) async throws -> ExtractedLiveMedia {
        calls += 1; self.cookies = cookies
        return try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"id":"live12345","is_live":true,"live_status":"is_live","url":"https://example.invalid/fallback.m3u8","vcodec":"h264","acodec":"aac"}"#.utf8))
    }
}

@MainActor
enum YouTubeRoutingChecks {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }
            checks.append(name)
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RoutingHTTPFixture.self]
        let session = URLSession(configuration: config)
        let browser = RoutingBrowserFixture(available: true)
        let connected = YouTubePublicClient(session: session, browser: browser)
        RoutingHTTPFixture.lock.withLock { RoutingHTTPFixture.requests = [] }
        let cookie = ".youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tfixture-not-real\n"
        let found = try await connected.search("fixture", cookies: cookie)
        try require(found.first?.avatarURL == "https://yt3.googleusercontent.com/avatar.jpg", "youtube_search_contains_real_channel_avatar")
        try require(RoutingHTTPFixture.lock.withLock { RoutingHTTPFixture.requests.isEmpty }, "browser_port_precedes_cookie_and_guest_http")
        let absent = RoutingBrowserFixture(available: false)
        let fallback = YouTubePublicClient(session: session, browser: absent)
        _ = try await fallback.search("fixture", cookies: cookie)
        try require(RoutingHTTPFixture.lock.withLock { RoutingHTTPFixture.requests.last?.value(forHTTPHeaderField: "Cookie") == "SAPISID=fixture-not-real" }, "missing_browser_uses_provided_cookie")
        _ = try await fallback.search("fixture", cookies: nil)
        try require(RoutingHTTPFixture.lock.withLock { RoutingHTTPFixture.requests.last?.value(forHTTPHeaderField: "Cookie") == nil }, "missing_browser_and_cookie_use_guest")
        try require(try await fallback.profile("https://www.youtube.com/channel/UCfixture", cookies: nil).avatarURL?.contains("profile.jpg") == true, "channel_profile_avatar_not_video_thumbnail")
        try require(try await fallback.status("https://www.youtube.com/channel/UCfixture", cookies: nil).state == .live, "public_live_badge_detected_without_player_request")
        func modern(_ style: String, _ text: String) -> [String: Any] {
            ["lockupViewModel": ["contentType": "LOCKUP_CONTENT_TYPE_VIDEO", "contentId": "modern12345",
                "contentImage": ["thumbnailViewModel": ["overlays": [["thumbnailBadgeViewModel": ["badgeStyle": style, "text": text]]]]],
                "metadata": ["lockupMetadataViewModel": ["title": ["content": "Modern fixture"]]]]]
        }
        try require(try YouTubePublicClient.snapshot(modern("THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE", "LIVE")).state == .live, "modern_youtube_live_badge")
        try require(try YouTubePublicClient.snapshot(modern("THUMBNAIL_OVERLAY_BADGE_STYLE_DEFAULT", "1:12:51")).state == .offline, "modern_youtube_finished_stream")
        try require(try YouTubePublicClient.snapshot(modern("THUMBNAIL_OVERLAY_BADGE_STYLE_UPCOMING", "UPCOMING")).state == .upcoming, "modern_youtube_upcoming")
        try require((try? YouTubePublicClient.snapshot(modern("UNKNOWN", "Unknown"))) == nil, "modern_unknown_not_misreported_offline")
        let genericPort = RoutingBrowserFixture(available: true), optionalBridge = RoutingBrowserFixture(available: true)
        _ = await LiveBrowserConnection(port: genericPort, bridge: optionalBridge).page(URL(string: "https://www.youtube.com/")!, player: false)
        let skippedBridge = await optionalBridge.calls
        try require(skippedBridge == 0, "generic_browser_port_precedes_optional_adapter")
        _ = await LiveBrowserConnection(port: absent, bridge: optionalBridge).page(URL(string: "https://www.youtube.com/")!, player: false)
        let usedBridge = await optionalBridge.calls
        try require(usedBridge == 1, "running_browser_bridge_used_when_standard_port_absent")
        let noBrowser = await LiveBrowserConnection(port: absent, bridge: absent).page(URL(string: "https://www.youtube.com/")!, player: false)
        try require(noBrowser == nil, "unavailable_browsers_preserve_cookie_guest_fallback")
        let extractor = RoutingExtractorFixture()
        let service = LivePlatformService(extractor: extractor, youtube: connected)
        var creator = WatchedCreator(CreatorCandidate(platform: .youtube, address: "https://www.youtube.com/channel/UCfixture", name: "Fixture"))
        creator.snapshot = .init(state: .live, liveURL: "https://www.youtube.com/watch?v=live12345")
        let input = try await service.recordingInput(creator, access: .init(cookies: cookie))
        let calls = await extractor.calls
        try require(input.tracks.first?.url.host == "example.invalid" && calls == 0, "connected_browser_stream_does_not_launch_external_parser")
        let blockedExtractor = RoutingExtractorFixture()
        let blockedService = LivePlatformService(extractor: blockedExtractor, youtube: YouTubePublicClient(session: session, browser: RoutingBrowserFixture(available: true, playable: false)))
        var blocked = false
        do { _ = try await blockedService.recordingInput(creator, access: .init()) } catch { blocked = true }
        let blockedCalls = await blockedExtractor.calls
        try require(blocked && blockedCalls == 0, "connected_browser_failure_never_silently_launches_parser")
        let fallbackService = LivePlatformService(extractor: extractor, youtube: fallback)
        _ = try await fallbackService.recordingInput(creator, access: .init(cookies: cookie))
        let supplied = await extractor.cookies
        try require(supplied == cookie, "recording_without_browser_falls_back_to_cookie")
        _ = try await fallbackService.recordingInput(creator, access: .init())
        let guest = await extractor.cookies
        try require(guest == nil, "recording_without_browser_or_cookie_falls_back_to_guest")
        try require(!LiveBrowserPort.isLoopback(URL(string: "http://example.com:9222")!), "browser_port_rejects_remote_endpoints")
        return checks
    }
}
