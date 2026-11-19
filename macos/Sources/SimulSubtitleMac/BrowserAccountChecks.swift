import Foundation

private actor AccountBrowserFixture: LiveBrowserReading {
    var rows: [[String: Any]] = []
    func set(_ rows: [[String: Any]]) { self.rows = rows }
    func page(_ url: URL, player: Bool) async -> [String: Any]? { ["cookies": rows] }
}

@MainActor
enum BrowserAccountChecks {
    static func run() async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw LiveMonitorError.unavailable("CHECK FAILED: " + name) }
            checks.append(name)
        }
        let suite = "SimuSub.BrowserAccountChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = AccountBrowserFixture()
        let credentials = LiveCredentials(defaults: defaults, browser: browser)
        for (platform, name) in [(LivePlatform.youtube, "SAPISID"), (.bilibili, "SESSDATA")] {
            let row: [String: Any] = ["domain": "." + platform.cookieDomain, "path": "/", "name": name,
                                      "value": "fixture-not-real", "secure": true, "expires": 0.0]
            await browser.set([row])
            await credentials.refreshBrowserSession(platform)
            try require(credentials.selectedSource(platform) == .browser, platform.rawValue + "_browser_login_selected")
            credentials.useGuest(platform)
            try require(credentials.selectedSource(platform) == .guest && !credentials.allowsBrowser(platform), platform.rawValue + "_explicit_guest_disables_browser")
            defaults.removeObject(forKey: "liveMonitor.v106." + platform.rawValue + ".browserDisabled")
            await browser.set([])
            await credentials.refreshBrowserSession(platform)
            try require(credentials.selectedSource(platform) == .guest, platform.rawValue + "_logout_clears_highlight")
            var expired = row; expired["expires"] = 1.0
            try require(LiveCookie.browserSession(["cookies": [expired]], platform: platform) == nil, platform.rawValue + "_expired_browser_session_rejected")
            try require(LiveCookie.browserSession(["cookies": [row]], platform: platform == .youtube ? .bilibili : .youtube) == nil, platform.rawValue + "_browser_session_scoped_to_platform")
        }
        try require(!LiveBrowserPort.supports(URL(string: "https://www.bilibili.com.evil.example/")!), "browser_probe_rejects_foreign_domain")
        return checks
    }
}
