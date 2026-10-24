import AppKit
import Foundation
import SwiftUI

/// Explicit opt-in UI checks. No audio, model downloads or authorization prompts.
@MainActor
enum SubtitlePanelChecks {
    private static var started = false

    static func runIfRequested(model: AppModel, controller: SubtitlePanelController,
                               flag: String = "--subtitle-panel-check") async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }
        started = true
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(nanoseconds: 400_000_000)
            model.isSubtitleOnly = true
            model.isSubtitlePinned = true
            controller.show()
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let panel = controller.panel, let home = controller.homeWindow else { throw CheckFailure("missing_windows") }
            try require(panel.isVisible && !home.isVisible, "independent_panel_home_hidden", &checks)
            try require(panel.frame.height == 96 && panel.frame.width <= 800, "initial_two_line_size", &checks)
            try require(panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate,
                        "nonactivating_panel_survives_deactivation", &checks)
            try require(panel.collectionBehavior.contains(.canJoinAllSpaces)
                        && panel.collectionBehavior.contains(.fullScreenAuxiliary)
                        && panel.collectionBehavior.contains(.canJoinAllApplications), "fullscreen_collection_flags", &checks)
            try require(panel.level == .statusBar && !panel.canBecomeMain, "overlay_level_without_main_focus", &checks)

            let caption = Caption(start: 0, end: 2, original: "今日は一緒に配信を楽しみましょう。", translated: "今天也一起开心地看直播吧。")
            model.captions = [caption]
            model.subtitleDisplayMode = .bilingual
            try await Task.sleep(nanoseconds: 200_000_000)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-双语-800x96.png"))
            guard let native = findNativeControls(panel.contentView) else { throw CheckFailure("missing_native_controls") }
            try require(native.buttons.count == 3, "native_traffic_light_controls", &checks)
            native.buttons[2].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(panel.frame.height > 96, "native_green_zoom", &checks)
            native.buttons[2].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(panel.frame.height == 96, "native_green_restore", &checks)
            panel.setContentSize(NSSize(width: 500, height: 48))
            try await Task.sleep(nanoseconds: 180_000_000)
            try require(SubtitleDensity.forSize(panel.frame.size) == .compact, "compact_single_row_density", &checks)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-单行-500x48.png"))
            panel.setContentSize(NSSize(width: 800, height: 96))
            controller.beginUserResize()
            panel.setContentSize(NSSize(width: 200, height: 36))
            controller.finishUserResize()
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(controller.isBubble && panel.frame.size == NSSize(width: 48, height: 48)
                        && model.captions == [caption], "shrink_to_bubble_keeps_session", &checks)
            try require(!panel.hasShadow && containsBubbleDragView(panel.contentView), "bubble_uses_native_drag_without_shadow", &checks)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-悬浮图标-48x48.png"))
            controller.restoreFromBubble()
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(!controller.isBubble && panel.frame.size == NSSize(width: 800, height: 96), "bubble_restores_previous_frame", &checks)
            try require(panel.hasShadow, "expanded_panel_restores_shadow", &checks)
            findNativeControls(panel.contentView)?.buttons[1].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(panel.isMiniaturized, "native_yellow_minimizes_to_dock", &checks)
            controller.openHomeFromDock()
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(!panel.isMiniaturized && panel.isVisible && !home.isVisible, "dock_restores_subtitle_panel", &checks)
            for size in [NSSize(width: 320, height: 84), NSSize(width: 800, height: 96), NSSize(width: 1000, height: 320)] {
                panel.setContentSize(size)
                try require(model.subtitleDisplayMode == .bilingual, "resize_\(Int(size.width))x\(Int(size.height))_keeps_bilingual", &checks)
            }
            model.subtitleDisplayMode = .chinese
            panel.setContentSize(NSSize(width: 800, height: 96))
            try await Task.sleep(nanoseconds: 180_000_000)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-仅中文-800x96.png"))
            try require(SubtitlePresentation(size: NSSize(width: 1000, height: 500), subtitleOnly: true, displayMode: .chinese) == .single,
                        "large_window_keeps_chinese_only", &checks)
            model.isSubtitlePinned = false
            controller.updatePin()
            try require(panel.level == .normal && panel.frame.height == 96, "unpin_does_not_resize", &checks)
            model.isSubtitlePinned = true
            controller.updatePin()

            // State simulation only: there is no capture engine and no recording.
            model.selectedAppBundleID = "com.apple.Safari"
            model.selectedAppName = "Safari"
            model.isCapturing = true
            model.toggleSubtitlePlayback()
            try await Task.sleep(nanoseconds: 180_000_000)
            try require(!model.isCapturing && model.isSubtitlePaused && model.captions == [caption]
                        && model.selectedAppBundleID == "com.apple.Safari", "pause_retains_captions_and_source_simulated", &checks)
            model.asrInstalled = true
            model.translationInstalled = true
            try require(model.subtitlePlaybackIntent == .resume, "resume_reuses_selected_app_intent", &checks)
            model.isCapturing = true
            findNativeControls(panel.contentView)?.buttons[0].performClick(nil)
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(!model.isCapturing && !model.isSubtitleOnly && !panel.isVisible && !home.isVisible,
                        "close_stops_simulated_capture_without_home", &checks)
            controller.openHomeFromDock()
            try require(home.isVisible, "dock_reopen_returns_home", &checks)

            checks += try await SubtitleV105Checks.run()
            model.captions = [Caption(start: 0, end: 8,
                original: "今日は配信を見たいけど、明日は朝が早いので、少しだけにします。",
                translated: "今天很想继续看直播，但是明天还要早起，所以只看一会儿。", isDraft: true)]
            model.subtitleDisplayMode = .bilingual
            model.isSubtitleOnly = true
            controller.show()
            for size in [NSSize(width: 800, height: 96), NSSize(width: 1000, height: 300), NSSize(width: 500, height: 48)] {
                panel.setContentSize(size)
                try await Task.sleep(nanoseconds: 180_000_000)
                try snapshot(panel, to: directory.appendingPathComponent("短语换行-\(Int(size.width))x\(Int(size.height)).png"))
            }
            controller.returnHome()

            let permissionProbe = CapturePermissionCenter(readScreen: { false }, probeScreen: { })
            permissionProbe.repairScreenFromUI()
            for _ in 0..<30 where permissionProbe.isRepairing { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(permissionProbe.screenGranted && !permissionProbe.needsResetConfirmation
                        && permissionProbe.screenAccessError.isEmpty,
                        "permission_repair_success_does_not_request_reset_mocked", &checks)
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            for scheme in [ColorScheme.light, ColorScheme.dark] {
                let view = NSHostingView(rootView: SettingsWindow().environmentObject(model)
                    .environmentObject(permissionProbe).environmentObject(HomeAppearance())
                    .preferredColorScheme(scheme))
                settings.contentView = view
                try await Task.sleep(nanoseconds: 180_000_000)
                try snapshot(settings, to: directory.appendingPathComponent(scheme == .light ? "字幕设置-浅色.png" : "字幕设置-深色.png"))
            }
            settings.close()
            try require(true, "subtitle_settings_light_dark_rendered", &checks)

            let report: [String: Any] = ["passed": true, "checks": checks, "processID": ProcessInfo.processInfo.processIdentifier,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "",
                "audioTested": false, "realSafariFullscreenTested": false, "permissionsReset": false]
            try write(report, to: directory.appendingPathComponent("panel-checks.json"))
            if CommandLine.arguments.contains("--hold-panel") {
                model.subtitleDisplayMode = .bilingual
                model.isSubtitleOnly = true
                controller.show()
                panel.setContentSize(NSSize(width: 800, height: 96))
                if CommandLine.arguments.contains("--hold-bubble") { controller.collapseToBubble() }
                for _ in 0..<1200 {
                    let observation = windowObservation(panel)
                    try write(observation, to: directory.appendingPathComponent("fullscreen-observation.json"))
                    if observation["panelAboveForeground"] as? Bool == true,
                       observation["foregroundCoverage"] as? Double ?? 0 >= 0.9,
                       let app = observation["frontmostBundleID"] as? String {
                        try write(observation, to: directory.appendingPathComponent("fullscreen-success-" + app + ".json"))
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        } catch {
            try? write(["passed": false, "checks": checks, "error": error.localizedDescription, "frame": controller.panel.map { NSStringFromRect($0.frame) } ?? "none"], to: directory.appendingPathComponent("panel-checks.json"))
        }
        NSApp.terminate(nil)
        return true
    }

    private static func findNativeControls(_ view: NSView?) -> SubtitleNativeControls.NativeControlsView? {
        guard let view else { return nil }
        if let native = view as? SubtitleNativeControls.NativeControlsView { return native }
        for child in view.subviews { if let result = findNativeControls(child) { return result } }
        return nil
    }

    private static func containsBubbleDragView(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return view is SubtitleBubbleInteraction.DragView || view.subviews.contains { containsBubbleDragView($0) }
    }

    private static func windowObservation(_ panel: NSPanel) -> [String: Any] {
        let front = NSWorkspace.shared.frontmostApplication
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let panelIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }
        let indices = windows.enumerated().compactMap { index, window -> Int? in
            guard (window[kCGWindowOwnerPID as String] as? Int) == front.map({ Int($0.processIdentifier) }),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return index
        }
        let screenArea = NSScreen.screens.map { $0.frame.width * $0.frame.height }.max() ?? 1
        let coverage = indices.map { index -> Double in
            let bounds = windows[index][kCGWindowBounds as String] as? [String: Any] ?? [:]
            return ((bounds["Width"] as? Double ?? 0) * (bounds["Height"] as? Double ?? 0)) / max(1, screenArea)
        }.max() ?? 0
        let above = panelIndex.map { pi in !indices.isEmpty && indices.allSatisfy { pi < $0 } } ?? false
        return ["panelVisible": panel.isVisible, "panelOnActiveSpace": panel.isOnActiveSpace,
                "panelWindowNumber": panel.windowNumber, "panelZIndex": panelIndex ?? -1,
                "foregroundZIndices": indices, "frontmostBundleID": front?.bundleIdentifier ?? "",
                "foregroundLayers": indices.map { windows[$0][kCGWindowLayer as String] as? Int ?? -1 },
                "panelFrame": NSStringFromRect(panel.frame), "observedAt": ISO8601DateFormatter().string(from: Date()),
                "foregroundCoverage": coverage,
                "panelAboveForeground": above && panel.isOnActiveSpace && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                "pinEnabled": panel.level == .statusBar, "panelLevel": panel.level.rawValue]
    }

    private static func require(_ value: Bool, _ name: String, _ checks: inout [String]) throws {
        guard value else { throw CheckFailure(name) }
        checks.append(name)
    }
    private static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw CheckFailure("no_content_view") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure("no_bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("no_png") }
        try data.write(to: url)
    }
    private static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private struct CheckFailure: LocalizedError {
        var name: String
        init(_ name: String) { self.name = name }
        var errorDescription: String? { name }
    }
}
