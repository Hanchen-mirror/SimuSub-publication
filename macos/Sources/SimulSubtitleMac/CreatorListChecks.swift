import AppKit
import SwiftUI

/// Uses isolated stores and platform fixtures; never starts real monitoring.
@MainActor
enum CreatorListChecks {
    static func run(directory: URL, credentials: LiveCredentials) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        var creator = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "Fixture"))
        try require(CreatorBadge(creator) == .unknown, "unverified_creator_is_unknown")
        for state in [LiveState.live, .offline, .upcoming] {
            creator.snapshot = .init(state: state); creator.stableState = state
            try require(CreatorBadge(creator).title == state.title, "clear_live_state_badge_" + state.rawValue)
        }
        creator.stableState = .live; creator.snapshot = .init(state: .offline); creator.offlineConfirmations = 1
        try require(CreatorBadge(creator) == .confirming, "one_offline_observation_shows_checking")
        creator.lastError = "Fixture request failed"
        try require(CreatorBadge(creator) == .error, "request_failure_shows_error_not_offline")

        let profile = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"thumbnail":"https://example.invalid/cover.jpg","thumbnails":[{"id":"avatar_uncropped","url":"https://example.invalid/avatar.jpg"}]}"#.utf8))
        let cover = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"thumbnail":"https://example.invalid/cover.jpg","thumbnails":[{"width":1920,"height":1080,"url":"https://example.invalid/cover.jpg"}]}"#.utf8))
        try require(profile.profileAvatar == "https://example.invalid/avatar.jpg" && cover.profileAvatar == nil, "youtube_avatar_excludes_video_cover")
        let storage = LiveMonitorStorage(root: directory.appendingPathComponent("home-storage"))
        let store = LiveMonitorStore(storage: storage, service: RecordingServiceFixture(preserveStates: true), credentials: credentials, notificationsEnabled: false)
        let candidates: [CreatorCandidate] = [
            .init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "Bilibili fixture"),
            .init(platform: .youtube, address: "https://www.youtube.com/@fixture", name: "YouTube fixture"),
            .init(platform: .twitch, address: "https://www.twitch.tv/fixture", name: "Twitch fixture"),
            .init(platform: .bilibili, address: "https://live.bilibili.com/7", name: "Offline fixture"),
            .init(platform: .youtube, address: "https://www.youtube.com/@fixture2", name: "Upcoming fixture")
        ]
        for candidate in candidates { store.follow(candidate) }
        let first = store.creators[0].id, last = store.creators[4].id
        store.moveCreator(first, to: last)
        let restored = LiveMonitorStore(storage: storage, service: RecordingServiceFixture(preserveStates: true), credentials: credentials, notificationsEnabled: false)
        try require(restored.creators.map(\.id) == store.creators.map(\.id) && restored.creators.last?.id == first,
                    "drag_reorder_survives_relaunch")
        store.shiftCreator(first, by: -4)
        try require(store.creators.first?.id == first, "keyboard_menu_reorder")
        store.follow(.init(platform: .twitch, address: "https://www.twitch.tv/samename", name: candidates[0].name))
        try require(store.creators.count == 6, "same_name_cross_platform_accounts_stay_distinct")
        await store.removeCreator(store.creators.last!.id)
        await store.shutdown()
        await restored.shutdown()
        return checks
    }
}
