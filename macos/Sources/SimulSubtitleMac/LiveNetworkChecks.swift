import Foundation

private final class Network138Protocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var playbackRequest: URLRequest?
    static var playbackBody = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var status = 200
        var data: Data
        if url.host == "usher.ttvnw.net" {
            data = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=640x360\nhttps://video.example/low.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=6000,RESOLUTION=1920x1080\nhttps://video.example/source.m3u8\n".utf8)
        } else {
            let json: [String: Any]
            if url.host == "gql.twitch.tv" {
                // URLSession may carry POST payload via httpBodyStream.
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(contentsOf: buffer.prefix(n)) }
                }
                let text = String(decoding: body, as: UTF8.self)
                if text.contains("SimuSubPlayback") { Self.lock.withLock { Self.playbackRequest = request; Self.playbackBody = text }; json = ["data": ["streamPlaybackAccessToken": ["value": "fixture", "signature": "fixture"]]] }
                else if text.contains("offline") { json = ["data": ["user": ["stream": NSNull()]]] }
                else if text.contains("broken") { json = ["errors": [["message": "fixture"]], "data": ["user": NSNull()]] }
                else { json = ["data": ["user": ["stream": ["id": "stream138", "title": "Fixture", "type": "live"]]]] }
            } else if url.path.contains("getRoomPlayInfo") {
                json = ["code": 0, "data": ["live_status": 1, "playurl_info": ["playurl": ["stream": [["format": [["codec": [["current_qn": 10000, "base_url": "/source.m3u8", "url_info": [
                    ["host": "https://bad.bilivideo.com", "extra": ""], ["host": "https://good.bilivideo.com", "extra": ""], ["host": "https://alternate.bilivideo.com", "extra": ""]
                ]]]]]]]]]]]
            } else { json = [:]; if url.host == "bad.bilivideo.com" { status = 503 } }
            data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct Network138ForbiddenExtractor: LiveExtracting {
    func metadata(_ address: String, cookies: String?, flat: Bool) async throws -> ExtractedLiveMedia {
        throw LiveMonitorError.unavailable("Unexpected external extractor")
    }
}

private actor Concurrent138Service: LivePlatformServing {
    private var active = 0
    private(set) var peak = 0
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] { [] }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate { .init(platform: platform, address: input, name: input) }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput { throw LiveMonitorError.invalidResponse }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot {
        active += 1; peak = max(peak, active); defer { active -= 1 }
        try await Task.sleep(nanoseconds: creator.name == "slow" ? 500_000_000 : 20_000_000)
        return .init(state: .live, sessionID: creator.address)
    }
}

@MainActor
enum LiveNetworkChecks {
    static func run() async throws {
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw LiveMonitorError.unavailable("v138: " + message) }
            print("CHECK: v138_" + message)
        }
        try require(YouTubePublicClient.unavailablePlaybackState(["playabilityStatus": ["status": "LIVE_STREAM_OFFLINE"]]) == .offline, "youtube_stopped_broadcast_is_offline")
        try require(YouTubePublicClient.unavailablePlaybackState(["playabilityStatus": ["status": "LOGIN_REQUIRED"]]) == nil, "youtube_login_failure_is_not_offline")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Network138Protocol.self]
        let service = LivePlatformService(session: URLSession(configuration: config), extractor: Network138ForbiddenExtractor())
        var bili = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "Bili"))
        bili.snapshot = .init(state: .live, sessionID: "session")
        let first = try await service.recordingInput(bili, access: .init())
        try require(first.tracks.count == 1 && first.tracks[0].url.host != "bad.bilivideo.com", "bili_failed_cdn_skipped_without_extractor")
        let cached = try await service.recordingInput(bili, access: .init())
        try require(cached.tracks[0].url == first.tracks[0].url, "bili_warm_cache_reused")
        await service.invalidateRecordingInput(bili)
        let retry = try await service.recordingInput(bili, access: .init())
        try require(retry.tracks[0].url.host != first.tracks[0].url.host, "bili_failure_rotates_cdn")
        let twitch = WatchedCreator(.init(platform: .twitch, address: "https://www.twitch.tv/live", name: "Twitch"))
        try require(try await service.status(twitch, access: .init()).state == .live, "twitch_status_without_extractor")
        let input = try await service.recordingInput(twitch, access: .init())
        try require(input.tracks[0].url.path == "/source.m3u8", "twitch_native_source_quality")
        try require(input.twitchHLS, "twitch_content_aware_route")
        let playback = Network138Protocol.lock.withLock { (Network138Protocol.playbackRequest, Network138Protocol.playbackBody) }
        try require(playback.0?.value(forHTTPHeaderField: "Client-ID") == "kimne78kx3ncx6brgo4mv6wki5h1ko" && playback.1.contains("embed"), "twitch_verified_client_parameters")
        _ = try await service.recordingInput(twitch, access: .init(cookies: ".twitch.tv\tTRUE\t/\tTRUE\t0\tauth-token\tfixture-session\n"))
        let auth = Network138Protocol.lock.withLock { Network138Protocol.playbackRequest?.value(forHTTPHeaderField: "Authorization") }
        try require(auth == "OAuth fixture-session", "twitch_selected_session_authorization")
        try require(!input.tracks[0].headers.keys.contains { ["cookie", "authorization"].contains($0.lowercased()) }, "twitch_no_account_credentials_to_cdn")
        for name in ["offline", "broken"] {
            let creator = WatchedCreator(.init(platform: .twitch, address: "https://www.twitch.tv/" + name, name: name))
            if name == "offline" { try require(try await service.status(creator, access: .init()).state == .offline, "twitch_explicit_null_is_offline") }
            else { var failed = false; do { _ = try await service.status(creator, access: .init()) } catch { failed = true }; try require(failed, "twitch_error_is_not_offline") }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("network138-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LiveMonitorStorage(root: root)
        let creators = (0..<5).map { WatchedCreator(.init(platform: .twitch, address: "https://www.twitch.tv/test\($0)", name: $0 == 0 ? "slow" : "fast")) }
        try storage.save(creators, name: "creators")
        var oldSettings = LiveMonitorSettings(); oldSettings.intervalSeconds = 180; oldSettings.pollingRevision = nil
        try storage.save(oldSettings, name: "settings")
        let concurrent = Concurrent138Service()
        let suite = "SimuSub.NetworkChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveMonitorStore(storage: storage, service: concurrent, credentials: LiveCredentials(defaults: defaults, enabled: false), notificationsEnabled: false)
        try require(store.settings.intervalSeconds == 15, "legacy_default_migrates_to_15_seconds")
        let task = Task { await store.refresh(force: true) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(store.creators[0].snapshot.state != .live && store.creators[1].snapshot.state == .live, "fast_creator_updates_before_slow_creator")
        await task.value
        let peak = await concurrent.peak
        try require(peak == 3 && store.creators.allSatisfy { $0.snapshot.state == .live }, "status_concurrency_bounded_to_three")
        store.applySnapshot(.init(state: .offline), to: creators[0].id)
        try require(store.creators[0].stableState == .live && (store.creators[0].nextCheckAt?.timeIntervalSinceNow ?? 100) <= 5, "offline_requires_fast_second_confirmation")
        store.applySnapshot(.init(state: .offline), to: creators[0].id)
        try require(store.creators[0].stableState == .offline, "second_offline_confirmation_ends_live")
        await store.shutdown()
    }
}
