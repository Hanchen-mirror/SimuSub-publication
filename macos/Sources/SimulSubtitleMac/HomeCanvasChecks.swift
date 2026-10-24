import AppKit
import SwiftUI

/// Uses isolated stores and platform fixtures; never starts real monitoring.
@MainActor
enum HomeCanvasChecks {
    static func run(directory: URL, credentials: LiveCredentials, service: any LivePlatformServing) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        let presentation = HomeLivePresentation()
        try require(presentation.searchVisible, "home_search_visible_by_default")
        presentation.query = "fixture"; presentation.resultsVisible = true; presentation.hideSearch()
        try require(!presentation.searchVisible && !presentation.resultsVisible, "eye_hides_search_and_popup")
        for platform in LivePlatform.allCases {
            presentation.select(platform)
            try require(presentation.searchVisible && presentation.platform == platform && !presentation.resultsVisible,
                        "platform_restores_search_" + platform.rawValue)
            presentation.hideSearch()
        }
        for width in [CGFloat(838), 978, 1478] {
            for count in [0, 1, 2, 3, 5, 12, 50] {
                let grid = CreatorGridMetrics(width: width, count: count)
                let rows = grid.rows(count: count)
                try require(rows.flatMap { Array($0) } == Array(0..<count)
                    && CGFloat(grid.columns) * grid.tile + CGFloat(grid.columns - 1) * grid.gap <= width,
                    "grid_fits_\(Int(width))_\(count)")
            }
        }
        for count in [1, 2, 3, 5] {
            let small = CreatorGridMetrics(width: 818, height: 338, count: count)
            let large = CreatorGridMetrics(width: 1458, height: 738, count: count)
            try require(large.tile > small.tile && small.tile >= 104 && large.tile <= 300,
                        "avatars_grow_with_window_\(count)")
        }
        let lower = CreatorGridMetrics(width: 958, height: 330, count: 5)
        let taller = CreatorGridMetrics(width: 958, height: 550, count: 5)
        try require(taller.tile > lower.tile, "avatar_size_responds_to_window_height")
        var creator = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "Fixture"))
        try require(CreatorBadge(creator) == .unknown, "unverified_creator_is_unknown")
        for state in [LiveState.live, .offline, .upcoming] {
            creator.snapshot = .init(state: state); creator.stableState = state
            try require(CreatorBadge(creator).title == state.rawValue.uppercased(), "english_badge_" + state.rawValue)
        }
        creator.stableState = .live; creator.snapshot = .init(state: .offline); creator.offlineConfirmations = 1
        try require(CreatorBadge(creator) == .confirming, "one_offline_observation_shows_checking")
        creator.lastError = "Fixture request failed"
        try require(CreatorBadge(creator) == .error, "request_failure_shows_error_not_offline")

        let profile = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"thumbnail":"https://example.invalid/cover.jpg","thumbnails":[{"id":"avatar_uncropped","url":"https://example.invalid/avatar.jpg"}]}"#.utf8))
        let cover = try JSONDecoder().decode(ExtractedLiveMedia.self, from: Data(#"{"thumbnail":"https://example.invalid/cover.jpg","thumbnails":[{"width":1920,"height":1080,"url":"https://example.invalid/cover.jpg"}]}"#.utf8))
        try require(profile.profileAvatar == "https://example.invalid/avatar.jpg" && cover.profileAvatar == nil, "youtube_avatar_excludes_video_cover")
        let storage = LiveMonitorStorage(root: directory.appendingPathComponent("home-storage"))
        let store = LiveMonitorStore(storage: storage, service: HomeBehaviorFixture(preserveStates: true), credentials: credentials, notificationsEnabled: false)
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
        let restored = LiveMonitorStore(storage: storage, service: HomeBehaviorFixture(preserveStates: true), credentials: credentials, notificationsEnabled: false)
        try require(restored.creators.map(\.id) == store.creators.map(\.id) && restored.creators.last?.id == first,
                    "drag_reorder_survives_relaunch")
        store.shiftCreator(first, by: -4)
        try require(store.creators.first?.id == first, "keyboard_menu_reorder")
        store.follow(.init(platform: .twitch, address: "https://www.twitch.tv/samename", name: candidates[0].name))
        try require(store.creators.count == 6, "same_name_cross_platform_accounts_stay_distinct")
        await store.removeCreator(store.creators.last!.id)
        for (index, item) in store.creators.enumerated() {
            store.applySnapshot(.init(state: index < 3 ? .live : index == 3 ? .offline : .upcoming,
                                      title: "UI fixture only", sessionID: "fixture"), to: item.id)
        }
        store.notice = nil
        store.startMonitoring()
        for scheme in [ColorScheme.light, .dark] {
            let suite = "SimuSub.HomeChecks." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(scheme == .dark, forKey: "home.dark.v099")
            let appearance = HomeAppearance(defaults: defaults, backgroundFile: directory.appendingPathComponent("no-wallpaper.png"))
            let mode = scheme == .dark ? "dark" : "light"
            presentation.select(.bilibili); presentation.query = ""
            try await render(store: store, appearance: appearance, presentation: presentation,
                             size: CGSize(width: 1100, height: 760), name: "home-\(mode)-search", directory: directory)
            for platform in LivePlatform.allCases {
                presentation.select(platform); presentation.showAccounts(platform)
                try await render(store: store, appearance: appearance, presentation: presentation,
                                 size: CGSize(width: 1100, height: 760), name: "home-\(mode)-\(platform.rawValue)-accounts", directory: directory)
                presentation.closeAccounts()
            }
            presentation.select(.bilibili)
            presentation.hideSearch()
            try await render(store: store, appearance: appearance, presentation: presentation,
                             size: CGSize(width: 1100, height: 760), name: "home-\(mode)-hidden", directory: directory)
            presentation.select(.bilibili); presentation.query = "Fixture"
            try await render(store: store, appearance: appearance, presentation: presentation,
                             size: CGSize(width: 960, height: 600), name: "home-\(mode)-compact-results", directory: directory,
                             beforeSnapshot: {
                                 await store.search("Fixture", platform: .bilibili)
                                 presentation.resultsVisible = true
                             })
            store.clearSearch(); presentation.hideSearch()
            try await render(store: store, appearance: appearance, presentation: presentation,
                             size: CGSize(width: 1600, height: 1000), name: "home-\(mode)-large", directory: directory)
        }
        // Render single and two-card layouts, plus overflow in the minimum window.
        while store.creators.count > 2 { await store.removeCreator(store.creators.last!.id) }
        let suite = "SimuSub.HomeChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = HomeAppearance(defaults: defaults, backgroundFile: directory.appendingPathComponent("none.png"))
        presentation.hideSearch()
        try await render(store: store, appearance: appearance, presentation: presentation,
                         size: CGSize(width: 1100, height: 760), name: "home-two-centered", directory: directory)
        await store.removeCreator(store.creators.last!.id)
        try await render(store: store, appearance: appearance, presentation: presentation,
                         size: CGSize(width: 1100, height: 760), name: "home-one-centered", directory: directory)
        for index in 1..<50 { store.follow(.init(platform: .bilibili, address: "https://live.bilibili.com/\(1000 + index)", name: "Fixture \(index)")) }
        presentation.showSearch()
        store.notice = nil
        try await render(store: store, appearance: appearance, presentation: presentation,
                         size: CGSize(width: 960, height: 600), name: "home-fifty-scroll", directory: directory)
        try await renderRemoval(scheme: .dark, directory: directory)
        try await renderRemoval(scheme: .light, directory: directory)
        await store.shutdown(); await restored.shutdown()
        try require(true, "home_native_sizes_search_hidden_results_single_pair_overflow_rendered")
        return checks
    }

    private static func renderRemoval(scheme: ColorScheme, directory: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CreatorRemovalConfirmation(name: "Fixture", onCancel: {}, onRemove: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: scheme == .dark ? 0.15 : 0.97)).preferredColorScheme(scheme))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("removal-" + (scheme == .dark ? "dark" : "light") + ".png"))
    }

    private static func render(store: LiveMonitorStore, appearance: HomeAppearance, presentation: HomeLivePresentation,
                               size: CGSize, name: String, directory: URL,
                               beforeSnapshot: (() async -> Void)? = nil) async throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ModuleHome(presentation: presentation, onSelect: { _ in })
            .environmentObject(store).environmentObject(appearance).preferredColorScheme(appearance.colorScheme))
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 300_000_000)
        if let beforeSnapshot {
            await beforeSnapshot()
            try await Task.sleep(nanoseconds: 300_000_000)
            guard !store.results.isEmpty else { throw LiveMonitorError.unavailable("CHECK FAILED: visible search popup has no results") }
        }
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LiveMonitorError.invalidResponse }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
