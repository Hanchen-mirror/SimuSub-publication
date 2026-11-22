import AppKit
import SwiftUI

@MainActor
enum ThemeChecks {
    private static var started = false
    static func runIfRequested(model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore, clips: ClipStore, subtitles: SubtitlePanelController) async -> Bool {
        if let index = CommandLine.arguments.firstIndex(of: "--theme-reload-check"), CommandLine.arguments.count > index + 2 {
            let suite = CommandLine.arguments[index + 1]
            let defaults = UserDefaults(suiteName: suite)!
            let wallpaper = FileManager.default.temporaryDirectory.appendingPathComponent("theme-no-wallpaper.png")
            let restored = HomeAppearance(defaults: defaults, backgroundFile: wallpaper)
            let offDefaults = UserDefaults(suiteName: suite + ".SheenOff")!
            let sheenPassed: Bool
            if defaults.object(forKey: HomeAppearance.wordmarkSheenKey) == nil {
                // Earlier theme-check fixtures have no wordmark preference.
                sheenPassed = !restored.wordmarkSheen && offDefaults.object(forKey: HomeAppearance.wordmarkSheenKey) == nil
            } else {
                let restoredOff = HomeAppearance(defaults: offDefaults, backgroundFile: wallpaper)
                sheenPassed = restored.wordmarkSheen && !restoredOff.wordmarkSheen
                    && offDefaults.object(forKey: HomeAppearance.wordmarkSheenKey) as? Bool == false
            }
            let passed = sheenPassed && restored.theme == .green && restored.mode == .light && restored.japaneseFont == "Hiragino Sans" && restored.chineseFont == "PingFang SC" && restored.japaneseSize == 18 && restored.chineseSize == 24 && restored.reduceMotion && restored.restorePage && restored.lastPage == "subtitle"
            try? JSONSerialization.data(withJSONObject: ["passed": passed, "check": "theme_mode_and_fonts_restored_in_new_process", "wordmarkSheenPassed": sheenPassed, "wordmarkSheen": restored.wordmarkSheen, "processID": ProcessInfo.processInfo.processIdentifier], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
            NSApp.terminate(nil); return true
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--theme-check"), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }; started = true
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [String] = []
        var windows: [(String, NSWindow)] = []
        func require(_ value: Bool, _ name: String) throws {
            if !value { throw NSError(domain: "ThemeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func host<V: View>(_ name: String, _ root: V) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: root.environmentObject(model).environmentObject(model.permissions).environmentObject(appearance).environmentObject(monitor).environmentObject(clips).environmentObject(subtitles).appTheme().environmentObject(appearance))
            w.orderFront(nil); windows.append((name, w))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suite = "SimuSub.ThemePersistence." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            try suite.write(to: directory.appendingPathComponent("persistence-suite.txt"), atomically: true, encoding: .utf8)
            let wallpaper = directory.appendingPathComponent("no-wallpaper.png")
            do {
                let saved = HomeAppearance(defaults: defaults, backgroundFile: wallpaper)
                try require(!saved.wordmarkSheen, "wordmark_sheen_is_off_on_first_launch")
                saved.wordmarkSheen = true
                let offDefaults = UserDefaults(suiteName: suite + ".SheenOff")!
                let savedOff = HomeAppearance(defaults: offDefaults, backgroundFile: wallpaper)
                savedOff.hideTheme(.purple)
                try require(savedOff.theme == .blue && !savedOff.visibleThemes.contains(.purple),
                            "removing_an_inactive_theme_preserves_current_appearance")
                for theme in savedOff.visibleThemes { savedOff.hideTheme(theme) }
                let emptyPalette = HomeAppearance(defaults: offDefaults, backgroundFile: wallpaper)
                try require(emptyPalette.visibleThemes.isEmpty && emptyPalette.theme == .yellow,
                            "removing_all_theme_choices_keeps_the_last_theme_on_relaunch")
                emptyPalette.restoreTheme(.purple)
                let restoredPalette = HomeAppearance(defaults: offDefaults, backgroundFile: wallpaper)
                try require(restoredPalette.visibleThemes == [.purple] && restoredPalette.theme == .purple,
                            "restoring_one_hidden_theme_selects_and_persists_it")
                savedOff.wordmarkSheen = true
                savedOff.wordmarkSheen = false
                try require(!HomeAppearance(defaults: offDefaults, backgroundFile: wallpaper).wordmarkSheen, "wordmark_sheen_restores_off_after_being_disabled")
                saved.theme = .green; saved.mode = .light; saved.japaneseFont = "Hiragino Sans"; saved.chineseFont = "PingFang SC"
                let legacyStyle = LiveCaptionStyle(fill: "#FFF4DB", outline: "#29221F", width: 1, shadow: 0.8)
                defaults.set(try JSONEncoder().encode(legacyStyle), forKey: "subtitle.captionStyle.v158")
                let migrated = HomeAppearance(defaults: defaults, backgroundFile: wallpaper)
                try require(migrated.captionStyle == LiveCaptionStyles(both: legacyStyle)
                    && migrated.captionStyle.original.effectiveShadowHeight == 1.4,
                    "both_live_rows_preserve_legacy_outline_and_shadow")
                saved.captionStyle = .blue
                saved.japaneseSize = 18; saved.chineseSize = 24; saved.reduceMotion = true; saved.restorePage = true; saved.lastPage = "subtitle"
                let restored = HomeAppearance(defaults: defaults, backgroundFile: wallpaper)
                try require(restored.theme == .green && restored.mode == .light && restored.japaneseFont == saved.japaneseFont && restored.chineseFont == saved.chineseFont, "theme_mode_fonts_restore_from_saved_defaults")
                try require(restored.wordmarkSheen, "wordmark_sheen_restores_on_when_enabled")
                try require(restored.captionStyle == .blue, "live_caption_fill_outline_and_shadow_persist")
                saved.captionStyle.original.width = 2.2
                saved.captionStyle.original.shadow = 0.35
                saved.captionStyle.original.shadowHeight = -3
                saved.captionStyle.translation.shadowHeight = 4
                let edited = HomeAppearance(defaults: defaults, backgroundFile: wallpaper)
                try require(edited.captionStyle == saved.captionStyle && edited.captionStyle.translation.width == 1.3
                    && edited.captionStyle.translation.shadow == 0.65,
                    "live_source_and_translation_independently_restore_outline_strength_and_shadow_height")
                try require(restored.japaneseSize == 18 && restored.chineseSize == 24 && restored.reduceMotion && restored.restorePage && restored.lastPage == "subtitle", "font_sizes_and_workspace_preferences_persist")
            }
            let imported = try ClipSubtitleImport.parse("1\n00:00:01,000 --> 00:00:03,000\nテスト字幕です。\n这是测试字幕。\n", extension: "srt", layout: .automatic, offset: 0, duration: 10)
            try require(imported.count == 1 && imported[0].original == "テスト字幕です。" && imported[0].translated == "这是测试字幕。", "v130_direct_import_detects_bilingual_text")
            let chinese = try ClipSubtitleImport.parse("1\n00:00:01,000 --> 00:00:03,000\n只有中文字幕。\n", extension: "srt", layout: .automatic, offset: 0, duration: 10)
            try require(chinese[0].original.isEmpty && chinese[0].translated == "只有中文字幕。", "v130_direct_import_detects_chinese_only")
            appearance.apply()
            host("settings", HStack(spacing: 0) { WorkspaceSidebar(selected: .settings, onSelect: { _ in }).frame(width: DesignV23.sidebar); SettingsWindow() })
            for (name, category) in [("permissions", "权限"), ("platforms", "平台"), ("recording-settings", "录制")] {
                host(name, HStack(spacing: 0) { WorkspaceSidebar(selected: .settings, onSelect: { _ in }).frame(width: DesignV23.sidebar); SettingsWindow(initialCategory: category) })
            }
            host("subtitle", HStack(spacing: 0) { WorkspaceSidebar(selected: .subtitle, onSelect: { _ in }).frame(width: DesignV23.sidebar); SubtitleConfiguration(onServices: {}) })
            host("recording", HStack(spacing: 0) { WorkspaceSidebar(selected: .recording, onSelect: { _ in }).frame(width: DesignV23.sidebar); RecordingWorkspace(onSettings: {}, onClips: { _ in }) })
            host("add-creator", AddCreatorSheet(presentation: CreatorSearchState(), onDone: {}))
            host("services", HStack(spacing: 0) { WorkspaceSidebar(selected: .services, onSelect: { _ in }).frame(width: DesignV23.sidebar); AdvancedServiceSettings() })
            host("controls", TextField("主题输入框", text: .constant("保留编辑内容")).textFieldStyle(ClipFieldStyle()).frame(width: 400))
            let emptyClips = ClipStore(root: directory.appendingPathComponent("empty-import-store"))
            host("import", ClipWorkspace(onBack: {}).environmentObject(emptyClips))
            if let fixtureIndex = CommandLine.arguments.firstIndex(of: "--theme-fixture"), CommandLine.arguments.count > fixtureIndex + 1 {
                let projectID = try await clips.importVideo(URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1]))
                clips.update(projectID) { project in
                    project.captions = [Caption(start: 1, end: 4, original: "今日は日本語の字幕をテストしています。", translated: "今天正在测试日语字幕。")]
                    project.ranges = [ClipRange(title: "选段 1", start: 0, end: 5), ClipRange(title: "选段 2", start: 5, end: 10)]
                }
                host("editor", ClipWorkspace(onBack: {}))
            }
            host("source-picker", ApplicationDockPicker(applications: [], selectedBundleID: nil, isRefreshing: false, onRefresh: {}, onSelect: { _ in }, onCancel: {}))
            model.captions = (0..<8).map { Caption(start: Double($0 * 4), end: Double($0 * 4 + 3), original: "今日は日本語の字幕をテストしています。", translated: "今天正在测试日语字幕。") }
            model.isSubtitleOnly = true; subtitles.show(); subtitles.openSubtitleSettings()
            guard let panel = subtitles.panel, let settings = subtitles.settingsWindow else { throw LiveMonitorError.invalidResponse }
            panel.setFrame(NSRect(x: 50, y: 100, width: 860, height: 440), display: true)
            let originalCount = model.captions.count
            var pixels: [String: String] = [:]
            for theme in AppTheme.allCases {
                for mode in [AppearanceMode.light, .dark] {
                    appearance.theme = theme; appearance.mode = mode
                    try await Task.sleep(nanoseconds: 400_000_000)
                    let key = theme.rawValue + "-" + mode.rawValue
                    for (name, window) in windows { try snapshot(window, to: directory.appendingPathComponent(key + "-" + name + ".png")) }
                    try snapshot(panel, to: directory.appendingPathComponent(key + "-floating.png"))
                    try snapshot(settings, to: directory.appendingPathComponent(key + "-quick-settings.png"))
                    try require(subtitles.panel === panel && subtitles.settingsWindow === settings && model.captions.count == originalCount, key + "_existing_windows_and_caption_state_preserved")
                    let bitmap = try bitmap(windows[0].1)
                    // Compare encoded screenshot bytes against the token converted to the
                    // bitmap ICC profile; colorAt mislabels these bytes as calibrated RGB.
                    let pixel = bitmap.colorAt(x: bitmap.pixelsWide - 12, y: 12)!
                    let expected = ThemePalette.color(theme, dark: mode == .dark, role: .background).usingColorSpace(bitmap.colorSpace)!
                    let error = abs(pixel.redComponent - expected.redComponent) + abs(pixel.greenComponent - expected.greenComponent) + abs(pixel.blueComponent - expected.blueComponent)
                    try require(error < 0.04, key + "_rendered_background_matches_design")
                    pixels[key] = String(format: "%.3f,%.3f,%.3f", pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
                    let controls = try Self.bitmap(windows.first { $0.0 == "controls" }!.1)
                    let input = controls.colorAt(x: controls.pixelsWide / 2 + 350, y: controls.pixelsHigh / 2)!
                    let controlColor = ThemePalette.color(theme, dark: mode == .dark, role: .control).usingColorSpace(controls.colorSpace)!
                    let controlError = abs(input.redComponent - controlColor.redComponent) + abs(input.greenComponent - controlColor.greenComponent) + abs(input.blueComponent - controlColor.blueComponent)
                    try require(controlError < 0.04, key + "_input_control_updates_live")
                }
            }
            try require(Set(pixels.values).count == 8, "all_eight_rendered_backgrounds_distinct")
            appearance.mode = .system
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(NSApp.appearance == nil && appearance.isDark == (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "follow_system_releases_forced_appearance")
            NSApp.appearance = NSAppearance(named: appearance.isDark ? .aqua : .darkAqua)
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(appearance.isDark == (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua), "effective_appearance_change_propagates_without_reopening")
            appearance.apply()
            for rows in [2, 4, 6, 8] {
                panel.setFrame(NSRect(x: 50, y: 100, width: 860, height: CGFloat(rows * 42 + 34)), display: true)
                try await Task.sleep(nanoseconds: 100_000_000)
                try snapshot(panel, to: directory.appendingPathComponent("floating-\(rows)-rows.png"))
                try require(model.captions.count == originalCount, "resizing_\(rows)_rows_keeps_history")
            }
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "pixels": pixels], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("theme-checks.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "error": error.localizedDescription], options: [.prettyPrinted]).write(to: directory.appendingPathComponent("theme-checks.json"))
            print("FAIL: " + error.localizedDescription)
        }
        for (_, window) in windows { window.close() }
        NSApp.terminate(nil)
        return true
    }
    private static func bitmap(_ window: NSWindow) throws -> NSBitmapImageRep {
        guard let view = window.contentView else { throw LiveMonitorError.invalidResponse }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let data = try bitmap(window).representation(using: .png, properties: [:]) else { throw LiveMonitorError.invalidResponse }
        try data.write(to: url)
    }
}
