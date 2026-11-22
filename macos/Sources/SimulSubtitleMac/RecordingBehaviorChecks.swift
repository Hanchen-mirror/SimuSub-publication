import Foundation

actor RecordingServiceFixture: LivePlatformServing {
    let preserveStates: Bool
    init(preserveStates: Bool = false) { self.preserveStates = preserveStates }
    func search(_ query: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> [CreatorCandidate] {
        try await Task.sleep(nanoseconds: 120_000_000)
        return [.init(platform: platform, address: "https://live.bilibili.com/6", name: query)]
    }
    func resolve(_ input: String, platform: LivePlatform, access: LivePlatformAccess) async throws -> CreatorCandidate {
        .init(platform: platform, address: input, name: "Fixture")
    }
    func status(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> LiveSnapshot {
        try await Task.sleep(nanoseconds: 40_000_000)
        return preserveStates ? creator.snapshot : .init(state: .live, sessionID: creator.address)
    }
    func recordingInput(_ creator: WatchedCreator, access: LivePlatformAccess) async throws -> ResolvedLiveInput {
        throw LiveMonitorError.unavailable("Recording must remain opt-in")
    }
}

@MainActor
enum RecordingBehaviorChecks {
    static func run(directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        let legacySnapshot = Data(#"{"state":"live","title":"旧主播","checkedAt":0}"#.utf8)
        let migrated = try JSONDecoder().decode(LiveSnapshot.self, from: legacySnapshot)
        try require(migrated.coverURL == nil && migrated.category == nil && migrated.title == "旧主播",
                    "dashboard_legacy_snapshot_decodes_without_cover_or_category")
        var enriched = migrated
        enriched.coverURL = "https://example.com/cover.jpg"; enriched.category = "杂谈"
        let restored = try JSONDecoder().decode(LiveSnapshot.self, from: JSONEncoder().encode(enriched))
        try require(restored == enriched, "dashboard_cover_and_category_survive_storage_roundtrip")
        let suite = "SimuSub.HomeBehavior." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = LiveCredentials(defaults: defaults, enabled: false)
        for platform in LivePlatform.allCases {
            try require(!credentials.usesAccount(platform), "first_launch_guest_selected_" + platform.rawValue)
        }
        defaults.set(true, forKey: "liveMonitor.v106.youtube.useAccount")
        credentials.useGuest(.bilibili)
        try require(credentials.usesAccount(.youtube) && !credentials.usesAccount(.bilibili), "account_mode_independent_per_platform")
        credentials.useGuest(.youtube)
        let store = LiveMonitorStore(storage: LiveMonitorStorage(root: directory.appendingPathComponent("add-monitor-behavior")),
                                     service: RecordingServiceFixture(), credentials: credentials, notificationsEnabled: false)
        let candidate = CreatorCandidate(platform: .bilibili, address: "https://live.bilibili.com/6", name: "Fixture")
        try require(store.addAndMonitor(candidate) && store.isMonitoring && store.creators[0].monitoring,
                    "adding_creator_starts_monitoring_by_default")
        try require(!store.creators[0].autoRecord && !store.creators[0].notify && store.recordings.isEmpty,
                    "add_does_not_enable_recording_or_notifications")
        for _ in 0..<50 {
            if store.creators[0].snapshot.state == .live { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(store.creators[0].snapshot.state == .live, "added_creator_checked_immediately")
        // Force an in-flight refresh while a second creator is added.
        store.refreshNow()
        try await Task.sleep(nanoseconds: 10_000_000)
        let second = CreatorCandidate(platform: .bilibili, address: "https://live.bilibili.com/7", name: "Fixture 2")
        try require(store.addAndMonitor(second), "add_while_refresh_in_progress")
        for _ in 0..<100 {
            if store.creators[1].snapshot.state == .live { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try require(store.creators[1].snapshot.state == .live, "new_creator_not_delayed_until_next_poll")
        try require(!store.addAndMonitor(candidate) && store.creators.count == 2, "duplicate_add_has_no_monitoring_side_effect")
        store.pauseMonitoring()
        let third = CreatorCandidate(platform: .bilibili, address: "https://live.bilibili.com/8", name: "Fixture 3")
        try require(store.addAndMonitor(third) && store.isMonitoring, "adding_after_pause_resumes_monitoring")
        let search = Task { await store.search("stale", platform: .bilibili) }
        try await Task.sleep(nanoseconds: 20_000_000)
        store.clearSearch()
        await search.value
        try require(store.results.isEmpty && store.searchError == nil && !store.isSearching, "cancelled_search_cannot_reopen_old_results")
        await store.shutdown()
        return checks
    }
}
