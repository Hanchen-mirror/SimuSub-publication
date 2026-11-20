import AppKit
import Foundation
import SwiftUI

/// Explicit opt-in UI checks. No audio, model downloads or authorization prompts.
@MainActor
enum SubtitlePanelChecks {
    private static var started = false

    static func runIfRequested(model: AppModel, controller: SubtitlePanelController,
                               appearance: HomeAppearance? = nil, flag: String = "--subtitle-panel-check") async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }
        started = true
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        var checks: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.sleep(nanoseconds: 400_000_000)
            // Enable SwiftUI accessibility nodes for this diagnostic process, including on Macs without VoiceOver.
            NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
            model.isSubtitleOnly = true
            model.isSubtitlePinned = true
            controller.show()
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let panel = controller.panel, let home = controller.homeWindow else { throw CheckFailure("missing_windows") }
            try require(panel.isVisible && !home.isVisible, "independent_panel_home_hidden", &checks)
            let originalFrame = panel.frame
            controller.openSubtitleSettings()
            try await Task.sleep(nanoseconds: 250_000_000)
            try require(controller.settingsWindow?.isVisible == true && panel.frame == originalFrame && !home.isVisible,
                        "independent_settings_opens_without_resizing_subtitles", &checks)
            if let settings = controller.settingsWindow { try snapshot(settings, to: directory.appendingPathComponent("独立字幕设置.png")); settings.close() }
            try require(panel.isVisible && panel.frame == originalFrame, "v123_closing_settings_keeps_subtitles", &checks)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-浮窗.png"))
            try require(panel.frame.height == 96 && panel.frame.width <= 800, "initial_v127_strip_size", &checks)
            try require(panel.styleMask.contains(.nonactivatingPanel) && !panel.hidesOnDeactivate,
                        "nonactivating_panel_survives_deactivation", &checks)
            try require(panel.collectionBehavior.contains(.canJoinAllSpaces)
                        && panel.collectionBehavior.contains(.fullScreenAuxiliary)
                        && panel.collectionBehavior.contains(.canJoinAllApplications), "fullscreen_collection_flags", &checks)
            try require(panel.level == .statusBar && !panel.canBecomeMain, "overlay_level_without_main_focus", &checks)

            // The idle label must remain centered even in a very short strip.
            for size in [NSSize(width: 500, height: 48), NSSize(width: 800, height: 66), NSSize(width: 800, height: 96)] {
                panel.setContentSize(size)
                try await Task.sleep(nanoseconds: 180_000_000)
                try snapshot(panel, to: directory.appendingPathComponent("idle-\(Int(size.width))x\(Int(size.height)).png"))
            }

            let caption = Caption(start: 0, end: 2, original: "今日は一緒に配信を楽しみましょう。", translated: "今天也一起开心地看直播吧。")
            model.captions = [caption]
            model.subtitleDisplayMode = .bilingual
            try await Task.sleep(nanoseconds: 200_000_000)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-双语-800x96.png"))
            if let appearance {
                try await checkCaptionStyle(appearance, panel: panel, directory: directory, checks: &checks)
            }
            try await checkPendingPair(model, panel: panel, directory: directory, checks: &checks)
            model.captions = (0..<20).map { index in
                Caption(start: Double(index * 4), end: Double(index * 4 + 3),
                    original: "字幕 \(index + 1)：今日は一緒に配信を楽しみましょう。",
                    translated: "字幕 \(index + 1)：今天也一起开心地看直播吧。")
            }
            for height in [96, 180, 320, 480] {
                panel.setContentSize(NSSize(width: 800, height: height))
                try await Task.sleep(nanoseconds: 180_000_000)
                try snapshot(panel, to: directory.appendingPathComponent("history-800x\(height).png"))
                try require(model.captions.count == 20, "expanded_history_preserves_all_captions_\(height)", &checks)
                if let appearance, let scroll = subview(NSScrollView.self, in: panel.contentView),
                   let document = scroll.documentView {
                    let row = SubtitleCueLayout.historyHeight(mode: model.subtitleDisplayMode,
                        japaneseFont: appearance.japaneseFont, chineseFont: appearance.chineseFont,
                        japaneseSize: appearance.japaneseSize, chineseSize: appearance.chineseSize,
                        zoom: appearance.workspaceZoom)
                    let rows = scroll.contentView.bounds.height / row
                    try require(abs(document.bounds.height - 20 * row) <= 1 && abs(rows - rows.rounded()) < 0.04
                                && (height < 180 || rows >= 2),
                                "live_and_history_use_adjacent_complete_rows_\(height)", &checks)
                } else { throw CheckFailure("missing_rendered_history_\(height)") }
            }
            try await checkHistoryScrolling(model, panel: panel, checks: &checks)
            model.captions = [caption]
            // Exercise the real AppKit tracking handlers without moving the
            // user's physical pointer or requiring Accessibility permission.
            for size in [NSSize(width: 800, height: 96), NSSize(width: 500, height: 76), NSSize(width: 540, height: 200)] {
                panel.setContentSize(size)
                try await parkAwayFromPointer(panel)
                let tracking = try pointer(true, in: panel)
                try await Task.sleep(nanoseconds: 180_000_000)
                try require(tracking.isInside.wrappedValue, "pointer_enter_shows_controls_\(Int(size.height))", &checks)
                let shown = directory.appendingPathComponent("hover-\(Int(size.width))x\(Int(size.height)).png")
                try snapshot(panel, to: shown)
                try pointer(false, in: panel)
                try await Task.sleep(nanoseconds: 180_000_000)
                try require(!tracking.isInside.wrappedValue, "pointer_exit_hides_controls_\(Int(size.height))", &checks)
                let hidden = directory.appendingPathComponent("unhover-\(Int(size.width))x\(Int(size.height)).png")
                try snapshot(panel, to: hidden)
                try require(try Data(contentsOf: shown) != Data(contentsOf: hidden), "hover_changes_rendered_controls_\(Int(size.height))", &checks)
                let geometry = SubtitleToolbarLayout(size: size)
                let right = [geometry.pinCenter, geometry.homeCenter, geometry.exportCenter,
                             geometry.clearCenter, geometry.modeCenter, geometry.languagesCenter]
                let centers = [geometry.playbackCenter] + right
                let frames = centers.map {
                    CGRect(x: $0.x - geometry.controlWidth / 2, y: $0.y - geometry.controlSize / 2,
                           width: geometry.controlWidth, height: geometry.controlSize)
                }
                let bounds = CGRect(origin: .zero, size: size)
                let separate = frames.enumerated().allSatisfy { index, rect in
                    bounds.contains(rect) && !geometry.paperFrame.intersects(rect)
                        && frames.dropFirst(index + 1).allSatisfy { rect.intersection($0).isEmpty }
                }
                let columnsAligned = (0..<3).allSatisfy { right[$0].x == right[$0 + 3].x }
                try require(separate && columnsAligned && right[0].y < right[3].y
                            && right.allSatisfy { $0.x > size.width / 2 } && geometry.playbackCenter.x < size.width / 2
                            && geometry.controlSize == geometry.controlWidth,
                            "seven_square_tool_targets_clear_of_paper_\(Int(size.height))", &checks)
                // Click through the real hosting view, using its window's coordinate system.
                // Changing a confirmed line's display must keep the existing translation.
                model.isCapturing = true
                let source = model.selectedAppBundleID
                try await Task.sleep(nanoseconds: 120_000_000)
                try pointer(true, in: panel)
                try await Task.sleep(nanoseconds: 180_000_000)
                try await clickTool("subtitle.displayMode", in: panel, at: windowPoint(geometry.modeCenter, size: size))
                try await Task.sleep(nanoseconds: 150_000_000)
                try require(model.subtitleDisplayMode == .original && model.isCapturing
                            && controller.settingsWindow?.isVisible != true && !home.isVisible,
                            "click_only_original_in_place_\(Int(size.height))", &checks)
                try await clickTool("subtitle.displayMode", in: panel, at: windowPoint(geometry.modeCenter, size: size))
                try await Task.sleep(nanoseconds: 150_000_000)
                try require(model.subtitleDisplayMode == .bilingual && model.captions == [caption]
                            && model.isCapturing && model.selectedAppBundleID == source,
                            "click_bilingual_preserves_capture_source_and_translation_\(Int(size.height))", &checks)
                let pin = model.isSubtitlePinned
                try await clickTool("subtitle.pin", in: panel, at: windowPoint(geometry.pinCenter, size: size))
                try await Task.sleep(nanoseconds: 120_000_000)
                try require(model.isSubtitlePinned != pin && model.captions == [caption],
                            "pin_directly_reachable_\(Int(size.height))", &checks)
                try await clickTool("subtitle.pin", in: panel, at: windowPoint(geometry.pinCenter, size: size))
                try await Task.sleep(nanoseconds: 120_000_000)
                try require(model.isSubtitlePinned == pin, "pin_restores_\(Int(size.height))", &checks)
                model.isCapturing = false
            }
            panel.setContentSize(NSSize(width: 800, height: 96))
            panel.setFrameOrigin(originalFrame.origin)
            try await checkLanguagePicker(model, panel: panel, checks: &checks)
            try checkSingleLineCaptions(caption, checks: &checks)
            try await checkFullCue(model, panel: panel, checks: &checks)
            if let appearance {
                let size = CGSize(width: 540, height: 200)
                let previousFont = appearance.chineseSize
                let previousSourceFont = appearance.japaneseSize
                let previousZoom = appearance.workspaceZoom
                defer {
                    appearance.chineseSize = previousFont
                    appearance.japaneseSize = previousSourceFont
                    appearance.workspaceZoom = previousZoom
                }
                appearance.workspaceZoom = .normal
                appearance.japaneseSize = 16
                panel.setContentSize(size)
                for subtitleSize in [20.0, 32.0] {
                    appearance.chineseSize = subtitleSize
                    try await Task.sleep(nanoseconds: 200_000_000)
                    let geometry = SubtitleToolbarLayout(size: size)
                    try require(geometry.paperFrame.minY == 2
                                && !geometry.paperFrame.contains(geometry.modeCenter)
                                && !geometry.paperFrame.contains(geometry.playbackCenter),
                                "font_\(Int(subtitleSize))_keeps_side_controls_clear_of_paper", &checks)
                    try pointer(true, in: panel)
                    try await Task.sleep(nanoseconds: 180_000_000)
                    try await clickTool("subtitle.displayMode", in: panel, at: windowPoint(geometry.modeCenter, size: size))
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try require(model.subtitleDisplayMode == .original && model.captions == [caption],
                                "reflow_mode_target_\(Int(subtitleSize))", &checks)
                    model.subtitleDisplayMode = .bilingual
                    try snapshot(panel, to: directory.appendingPathComponent("font-\(Int(subtitleSize))-540x200.png"))
                }
            }
            panel.setContentSize(NSSize(width: 800, height: 96))
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let native = findNativeControls(panel.contentView) else { throw CheckFailure("missing_native_controls") }
            try require(native.buttons.count == 3, "native_traffic_light_controls", &checks)
            if let appearance {
                try await checkZoomKeepsChosenType(model, panel: panel, controls: native, appearance: appearance, checks: &checks)
            }
            let compact = NSSize(width: 500, height: 76)
            panel.setContentSize(compact)
            try await Task.sleep(nanoseconds: 180_000_000)
            try require(!controller.isBubble && panel.frame.size == compact && model.subtitleDisplayMode == .bilingual,
                        "compact_preserves_bilingual_panel", &checks)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-紧凑双排-500x76.png"))
            try exerciseContinuousHeight(panel, caption: caption, checks: &checks)
            try exerciseAnchoredCorners(panel, checks: &checks)
            let lastReadable = panel.frame
            let releaseCenter = NSPoint(x: lastReadable.minX + 180, y: lastReadable.midY)
            try exerciseContinuousResize(panel, controller: controller, caption: caption, checks: &checks)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(controller.isBubble && panel.frame.size == NSSize(width: 44, height: 44)
                        && abs(panel.frame.midX - releaseCenter.x) <= 1 && abs(panel.frame.midY - releaseCenter.y) <= 1
                        && model.captions == [caption], "cue_pressure_folds_at_center_and_keeps_caption", &checks)
            try require(!panel.hasShadow && containsBubbleDragView(panel.contentView), "bubble_uses_native_drag_without_shadow", &checks)
            try snapshot(panel, to: directory.appendingPathComponent("字幕-收起徽记-44x44.png"))
            controller.restoreFromBubble()
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(!controller.isBubble && panel.frame.size == compact && panel.hasShadow
                        && abs(panel.frame.midX - releaseCenter.x) <= 1 && abs(panel.frame.midY - releaseCenter.y) <= 1,
                        "bubble_restores_last_readable_dimensions_and_center", &checks)
            findNativeControls(panel.contentView)?.buttons[1].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(controller.isBubble && !panel.isMiniaturized, "native_yellow_folds_to_badge", &checks)
            controller.restoreFromBubble()
            try await Task.sleep(nanoseconds: 550_000_000)
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
            model.setSubtitleSource(id: AudioCaptureEngine.systemAudioID, name: "Mac 声音")
            model.isCapturing = true
            let size = panel.frame.size
            try await Task.sleep(nanoseconds: 120_000_000)
            try pointer(true, in: panel)
            try await Task.sleep(nanoseconds: 200_000_000)
            let playbackPoint = SubtitleToolbarLayout(size: size).playbackCenter
            try await clickTool("subtitle.playback", in: panel, at: windowPoint(playbackPoint, size: size))
            try await Task.sleep(nanoseconds: 200_000_000)
            try require(!model.isCapturing && model.isSubtitlePaused && model.captions == [caption]
                        && model.selectedAppBundleID == AudioCaptureEngine.systemAudioID, "pause_retains_captions_and_source_simulated", &checks)
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
            for size in [NSSize(width: 800, height: 96), NSSize(width: 1000, height: 300), NSSize(width: 500, height: 48), NSSize(width: 800, height: 66), NSSize(width: 360, height: 80)] {
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

    private static func checkZoomKeepsChosenType(_ model: AppModel, panel: NSPanel,
                                                 controls: SubtitleNativeControls.NativeControlsView,
                                                 appearance: HomeAppearance, checks: inout [String]) async throws {
        let cue = Caption(start: 0, end: 2, original: "Good morning.", translated: "早上好。")
        let previous = (appearance.japaneseSize, appearance.chineseSize, appearance.workspaceZoom)
        let savedCaptions = model.captions, savedMode = model.subtitleDisplayMode
        defer {
            (appearance.japaneseSize, appearance.chineseSize, appearance.workspaceZoom) = previous
            model.captions = savedCaptions
            model.subtitleDisplayMode = savedMode
        }
        appearance.workspaceZoom = .normal
        appearance.japaneseSize = 18
        appearance.chineseSize = 24
        model.captions = [cue]
        for mode in [SubtitleDisplayMode.original, .bilingual] {
            model.subtitleDisplayMode = mode
            func usesChosenSizes(_ size: CGSize) -> Bool {
                let cueLayout = SubtitleCueLayout(caption: cue, mode: mode, size: size,
                    japaneseFont: appearance.japaneseFont, chineseFont: appearance.chineseFont,
                    japaneseSize: appearance.japaneseSize, chineseSize: appearance.chineseSize, zoom: appearance.workspaceZoom)
                let chosen: [CGFloat] = mode == .original ? [18] : [18, 24]
                return cueLayout.lines.map { $0.font.pointSize } == chosen
                    && cueLayout.lines.map { $0.preferredFont.pointSize } == chosen && !cueLayout.tooNarrow && !cueLayout.tooShort
            }
            for size in [CGSize(width: 500, height: 76), CGSize(width: 800, height: 96), CGSize(width: 1000, height: 520)] {
                panel.setContentSize(size)
                try require(usesChosenSizes(panel.frame.size), "resize_keeps_18_24_when_text_fits_\(mode.rawValue)_\(Int(size.height))", &checks)
            }
            panel.setContentSize(CGSize(width: 800, height: 96))
            let before = panel.frame
            controls.buttons[2].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(panel.frame.height > before.height && usesChosenSizes(panel.frame.size),
                        "green_zoom_keeps_chosen_type_\(mode.rawValue)", &checks)
            controls.buttons[2].performClick(nil)
            try await Task.sleep(nanoseconds: 550_000_000)
            try require(panel.frame == before && usesChosenSizes(panel.frame.size),
                        "green_restore_keeps_chosen_type_\(mode.rawValue)", &checks)
        }
    }

    private static func subview<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = subview(type, in: child) { return match }
        }
        return nil
    }

    private static func exerciseContinuousHeight(_ panel: NSPanel, caption: Caption, checks: inout [String]) throws {
        guard let surface = subview(SubtitleResizeSurface.ResizeView.self, in: panel.contentView) else {
            throw CheckFailure("missing_native_resize_surface")
        }
        let start = panel.frame
        // Give the top edge enough space for the complete test gesture.
        panel.center()
        let centered = panel.frame
        let top = NSPoint(x: centered.midX, y: centered.maxY - 2)
        func event(_ type: NSEvent.EventType, _ height: CGFloat) throws -> NSEvent {
            let screenPoint = NSPoint(x: top.x, y: top.y + height - centered.height)
            guard let e = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckFailure("missing_vertical_resize_event") }
            return e
        }
        surface.mouseDown(with: try event(.leftMouseDown, centered.height))
        var prior = SubtitleToolbarLayout(size: centered.size)
        let heights = Array(Int(centered.height)...180) + Array((Int(centered.height)..<180).reversed())
        for step in heights {
            let height = CGFloat(step)
            surface.mouseDragged(with: try event(.leftMouseDragged, height))
            let geometry = SubtitleToolbarLayout(size: panel.frame.size)
            let layout = SubtitleCueLayout(caption: caption, mode: .bilingual, size: panel.frame.size)
            guard abs(panel.frame.midX - centered.midX) <= 1 && abs(panel.frame.minY - centered.minY) <= 1,
                  abs(panel.frame.height - height) <= 1 && abs(panel.frame.width - centered.width) <= 1,
                  abs(geometry.paperFrame.midY - prior.paperFrame.midY) <= 1.01,
                  abs(geometry.languagesCenter.y - prior.languagesCenter.y) <= 1.01,
                  layout.lines.count == 2 && layout.lines.allSatisfy({ $0.font.pointSize == $0.preferredFont.pointSize })
            else { throw CheckFailure("vertical_drag_reflow_jump_at_" + String(step)) }
            prior = geometry
        }
        surface.mouseUp(with: try event(.leftMouseUp, centered.height))
        panel.setFrame(start, display: true)
        try require(panel.frame.size == start.size, "vertical_drag_across_height_breakpoints_preserves_cue_and_tools", &checks)
    }

    private static func exerciseAnchoredCorners(_ panel: NSPanel, checks: inout [String]) throws {
        guard let screen = panel.screen?.visibleFrame,
              let surface = subview(SubtitleResizeSurface.ResizeView.self, in: panel.contentView) else {
            throw CheckFailure("missing_resize_surface_or_screen")
        }
        let saved = panel.frame
        defer { panel.setFrame(saved, display: true) }
        for positive in [true, false] {
            let width = min(420, screen.width - 100), height: CGFloat = 90
            let x = positive ? screen.minX : screen.maxX - width
            let y = positive ? screen.minY : screen.maxY - height
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            let start = panel.frame
            let corner = NSPoint(x: positive ? start.maxX - 2 : start.minX + 2,
                                 y: positive ? start.maxY - 2 : start.minY + 2)
            func event(_ type: NSEvent.EventType, _ distance: CGFloat) throws -> NSEvent {
                let sign: CGFloat = positive ? 1 : -1
                let location = CGPoint(x: corner.x + sign * distance, y: corner.y + sign * distance)
                guard let event = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: location),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                    throw CheckFailure("missing_corner_drag_event")
                }
                return event
            }
            surface.mouseDown(with: try event(.leftMouseDown, 0))
            surface.mouseDragged(with: try event(.leftMouseDragged, 35))
            surface.mouseUp(with: try event(.leftMouseUp, 47))
            let frame = panel.frame
            let xShift = positive ? frame.minX - start.minX : frame.maxX - start.maxX
            let yShift = positive ? frame.minY - start.minY : frame.maxY - start.maxY
            try require(abs(xShift) <= 1 && abs(yShift) <= 1 && abs(frame.width - start.width - 47) <= 1
                        && abs(frame.height - start.height - 47) <= 1,
                        "drag_corner_follows_release_against_screen_\(positive ? "lower_left" : "upper_right")", &checks)
        }
    }

    private static func exerciseContinuousResize(_ panel: NSPanel, controller: SubtitlePanelController,
                                                 caption: Caption, checks: inout [String]) throws {
        guard let surface = subview(SubtitleResizeSurface.ResizeView.self, in: panel.contentView) else {
            throw CheckFailure("missing_native_resize_surface")
        }
        let start = panel.frame
        let origin = NSPoint(x: start.maxX - 2, y: start.midY)
        func event(_ type: NSEvent.EventType, atWidth width: CGFloat) throws -> NSEvent {
            let screenPoint = NSPoint(x: origin.x + width - start.width, y: origin.y)
            guard let e = NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: screenPoint),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw CheckFailure("missing_resize_event") }
            return e
        }
        surface.mouseDown(with: try event(.leftMouseDown, atWidth: start.width))
        var previousWidth = start.width
        var previousType = SubtitleCueLayout(caption: caption, mode: .bilingual, size: start.size).lines[0].font.pointSize
        let widths = Array(stride(from: 490, through: 360, by: -10))
            + Array(stride(from: 370, through: 500, by: 10)) + Array(stride(from: 490, through: 360, by: -10))
        var sawCompression = false, returnedToFullSize = false
        for step in widths {
            let width = CGFloat(step)
            surface.mouseDragged(with: try event(.leftMouseDragged, atWidth: width))
            guard !controller.isBubble, abs(panel.frame.minX - start.minX) <= 1, abs(panel.frame.midY - start.midY) <= 1,
                  abs(panel.frame.width - width) <= 1, panel.frame.height == start.height else {
                throw CheckFailure("resize_jumps_or_folds_before_release")
            }
            let geometry = SubtitleToolbarLayout(size: panel.frame.size)
            let line = SubtitleCueLayout(caption: caption, mode: .bilingual, size: panel.frame.size).lines[0]
            let actual = line.font.pointSize, preferred = line.preferredFont.pointSize
            guard abs(geometry.paperFrame.midX - width / 2) <= 1,
                  abs(width - geometry.languagesCenter.x - 21) <= 1,
                  actual >= preferred * 0.85 - 0.01 && actual <= preferred + 0.01,
                  width < previousWidth ? actual <= previousType + 0.05 : actual >= previousType - 0.05 else {
                throw CheckFailure("continuous_resize_changes_font_or_tool_discontinuously")
            }
            sawCompression = sawCompression || actual < preferred - 0.05
            if sawCompression && width == start.width { returnedToFullSize = actual == preferred }
            previousType = actual
            previousWidth = width
        }
        try require(sawCompression && returnedToFullSize, "continuous_width_drag_reverses_without_premature_fold", &checks)
        surface.mouseUp(with: try event(.leftMouseUp, atWidth: 360))
    }

    private static func parkAwayFromPointer(_ panel: NSPanel) async throws {
        guard let screen = panel.screen ?? NSScreen.main else { throw CheckFailure("missing_screen") }
        let visible = screen.visibleFrame
        for _ in 0..<3 {
            let size = panel.frame.size
            let y = NSEvent.mouseLocation.y < visible.midY ? visible.maxY - size.height - 12 : visible.minY + 12
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: y))
            panel.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            if !panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { return }
        }
        throw CheckFailure("cannot_isolate_tracking_panel_" + NSStringFromRect(panel.frame)
                           + "_pointer_" + NSStringFromPoint(NSEvent.mouseLocation))
    }

    private static func checkCaptionStyle(_ appearance: HomeAppearance, panel: NSPanel,
                                          directory: URL, checks: inout [String]) async throws {
        let saved = appearance.captionStyle, mode = appearance.mode
        defer { appearance.captionStyle = saved; appearance.mode = mode }
        appearance.mode = .dark
        let originalSize = appearance.japaneseSize, translatedSize = appearance.chineseSize
        var standardRows: [ClosedRange<Int>] = []
        for (style, name) in [(LiveCaptionStyle.standard, "standard"), (.blue, "blue")] {
            appearance.captionStyle = style
            try await Task.sleep(nanoseconds: 250_000_000)
            let bitmap = try snapshot(panel, to: directory.appendingPathComponent("caption-style-\(name).png"))
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            var whitePixels = 0, bluePixels = 0, rows: [ClosedRange<Int>] = []
            for y in 0..<height {
                var ink = 0
                for x in stride(from: width / 4, to: 3 * width / 4, by: 2) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    if min(r, g, b) > 0.52 { ink += 1 }
                    if min(r, g, b) > 0.95 { whitePixels += 1 }
                    if b > r + 0.24 && g > r + 0.10 && b > g + 0.12 { bluePixels += 1 }
                }
                if ink >= 4 {
                    if let last = rows.last, y - last.upperBound <= 2 {
                        rows[rows.count - 1] = last.lowerBound...y
                    } else { rows.append(y...y) }
                }
            }
            if style == .standard {
                try require(rows.count == 2 && bluePixels < 15, "standard_caption_has_two_rows_without_blue_outline", &checks)
                standardRows = rows
            } else {
                try require(whitePixels > 80 && bluePixels > 80, "native_blue_outline_and_white_glyph_fill_visible", &checks)
                let tolerance = Int(ceil(Double(height) / panel.frame.height * 2))
                try require(rows.count == standardRows.count && zip(rows, standardRows).allSatisfy {
                    abs($0.0.lowerBound - $0.1.lowerBound) <= tolerance && abs($0.0.upperBound - $0.1.upperBound) <= tolerance
                } && appearance.japaneseSize == originalSize && appearance.chineseSize == translatedSize,
                "caption_paint_keeps_original_and_translation_type_metrics", &checks)
            }
        }
    }

    private static func checkPendingPair(_ model: AppModel, panel: NSPanel, directory: URL,
                                         checks: inout [String]) async throws {
        panel.setContentSize(NSSize(width: 800, height: 320))
        model.captions = [
            Caption(start: 0, end: 2, original: "今日はいい天気ですね。", translated: "", isDraft: true),
            Caption(start: 2, end: 4, original: "一緒に歩いてみよう。", translated: "", isDraft: true)
        ]
        var originalBounds: CGRect?
        for step in 0..<3 {
            if step > 0 {
                model.captions[step - 1].isDraft = false
                model.captions[step - 1].translated = step == 1 ? "今天的天气真好。" : "我们一起走走吧。"
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            guard let scroll = subview(NSScrollView.self, in: panel.contentView),
                  let document = scroll.documentView else { throw CheckFailure("missing_two_cue_scroll") }
            let viewport = scroll.convert(scroll.contentView.frame, to: nil)
            let row = document.bounds.height / 2
            try require(row > 20 && row < 96 && abs(viewport.height - 2 * row) <= 1
                        && abs(viewport.midY - panel.frame.height / 2) <= 1
                        && (originalBounds == nil || originalBounds == viewport),
                        "pending_pair_stays_centered_with_stable_row_pitch_step_\(step)", &checks)
            originalBounds = viewport
            try snapshot(panel, to: directory.appendingPathComponent("pending-pair-\(step).png"))
        }
    }

    private static func checkHistoryScrolling(_ model: AppModel, panel: NSPanel, checks: inout [String]) async throws {
        guard let scroll = subview(NSScrollView.self, in: panel.contentView), let document = scroll.documentView else {
            throw CheckFailure("missing_history_scroll_view")
        }
        let clip = scroll.contentView
        func liveOffset() -> CGFloat {
            document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0
        }
        func wheel(_ lines: Int32) async throws {
            guard let input = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                      wheel1: lines, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: input) else { throw CheckFailure("cannot_create_scroll_wheel_event") }
            scroll.scrollWheel(with: event)
            try await Task.sleep(nanoseconds: 450_000_000)
        }
        try require(abs(clip.bounds.minY - liveOffset()) < 4,
                    "enlarged_history_starts_at_latest_cue", &checks)
        try await wheel(8)
        let readPosition = clip.bounds.minY
        let tailBefore = liveOffset()
        try require(abs(readPosition - tailBefore) > 20 && readPosition >= 0,
                    "manual_scroll_reaches_valid_earlier_cue", &checks)
        let row = document.bounds.height / CGFloat(model.captions.count)
        let fromTop = document.isFlipped ? readPosition : document.bounds.height - clip.bounds.height - readPosition
        try require(abs(fromTop - (fromTop / row).rounded() * row) <= 1,
                    "history_rests_on_whole_cue_after_wheel", &checks)
        model.captions.append(Caption(start: 33, end: 36, original: "New sentence", translated: "新的一句"))
        try await Task.sleep(nanoseconds: 300_000_000)
        guard abs(clip.bounds.minY - readPosition) < 4 && abs(clip.bounds.minY - liveOffset()) > 20 else {
            throw CheckFailure("incoming_cue_shifted_history_\(readPosition)_to_\(clip.bounds.minY)_tail_\(tailBefore)_to_\(liveOffset())")
        }
        checks.append("incoming_cue_preserves_manual_history_position")
        for _ in 0..<8 where abs(clip.bounds.minY - liveOffset()) > 2 { try await wheel(-8) }
        try require(abs(clip.bounds.minY - liveOffset()) <= 2, "wheel_scroll_reaches_live_edge", &checks)
        model.captions.append(Caption(start: 37, end: 40, original: "Back to live", translated: "回到同传"))
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(abs(clip.bounds.minY - liveOffset()) < 4,
                    "return_to_bottom_follows_next_cue", &checks)
    }

    private static func checkSingleLineCaptions(_ caption: Caption, checks: inout [String]) throws {
        for size in [CGSize(width: 800, height: 96), CGSize(width: 500, height: 76), CGSize(width: 540, height: 200)] {
            for mode in [SubtitleDisplayMode.bilingual, .original] {
                let layout = SubtitleCueLayout(caption: caption, mode: mode, size: size)
                try require(layout.lines.count == (mode == .original ? 1 : 2)
                            && layout.lines.allSatisfy { !$0.truncated && !$0.text.contains("\n") }
                            && layout.lines.first?.text == caption.original,
                            "complete_single_line_per_language_\(mode.rawValue)_\(Int(size.width))", &checks)
            }
        }
        let asymmetric = Caption(start: 0, end: 2, original: caption.original, translated: "你好。")
        // Search the width, so the check exercises the actual system font on this Mac.
        let fits = (360...500).map {
            SubtitleCueLayout(caption: asymmetric, mode: .bilingual, size: CGSize(width: $0, height: 76))
        }
        let moderate = fits.contains { layout in
            guard let source = layout.lines.first, let target = layout.lines.last else { return false }
            return !layout.tooNarrow && !source.truncated && source.font.pointSize < source.preferredFont.pointSize - 0.1
                && source.font.pointSize >= source.preferredFont.pointSize * 0.85 - 0.01
                && target.font.pointSize == target.preferredFont.pointSize
        }
        try require(moderate, "shrink_only_long_language_within_readability_budget", &checks)
        let narrow = fits[0]
        try require(narrow.tooNarrow && narrow.lines.first?.truncated == true
                    && narrow.lines.last?.truncated == false, "width_pressure_before_wrapping", &checks)
        let paragraph = Caption(start: 1, end: 3, original: "First line\nSecond line", translated: "第一句\n第二句")
        let text = SubtitleCueLayout(caption: paragraph, mode: .bilingual, size: CGSize(width: 800, height: 96))
        try require(text.lines.map(\.text) == ["First line Second line", "第一句 第二句"]
                    && paragraph.original.contains("\n"), "flatten_only_display_and_keep_original_cue", &checks)
    }

    private static func checkFullCue(_ model: AppModel, panel: NSPanel, checks: inout [String]) async throws {
        let saved = model.captions
        let size = CGSize(width: 500, height: 76)
        defer { model.captions = saved }
        panel.setContentSize(size)
        let cue = Caption(start: 1, end: 3, original: String(repeating: "今日は配信を楽しみましょう。", count: 4),
                          translated: String(repeating: "今天一起开心地看直播。", count: 5))
        model.captions = [cue]
        let paper = SubtitleToolbarLayout(size: size).paperFrame
        for hovered in [false, true] {
            try pointer(hovered, in: panel)
            try await Task.sleep(nanoseconds: 200_000_000)
            let center = windowPoint(CGPoint(x: paper.midX, y: paper.midY), size: size)
            for _ in 0..<20 where accessible("subtitle.fullCaption") == nil {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let axFrame = accessible("subtitle.fullCaption")?.accessibilityFrame?() ?? .zero
            let buttonFrame = panel.convertFromScreen(axFrame)
            guard buttonFrame.contains(center) else {
                throw CheckFailure("full_caption_target_not_centered_" + NSStringFromRect(buttonFrame)
                                   + "_center_" + NSStringFromPoint(center))
            }
            try click(panel, at: center)
            for _ in 0..<30 where accessible("subtitle.fullCaptionDetail") == nil {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            try require(accessible("subtitle.fullCaptionDetail") != nil && model.captions == [cue],
                        "click_long_cue_reveals_full_text_with_tools_\(hovered ? "shown" : "hidden")", &checks)
            // Click blank space outside the popover to dismiss it like a user.
            try click(panel, at: NSPoint(x: 75, y: 8))
            for _ in 0..<30 where accessible("subtitle.fullCaptionDetail") != nil {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            try require(accessible("subtitle.fullCaptionDetail") == nil,
                        "outside_click_dismisses_full_text_with_tools_\(hovered ? "shown" : "hidden")", &checks)
        }
    }

    private static func checkLanguagePicker(_ model: AppModel, panel: NSPanel, checks: inout [String]) async throws {
        model.setSourceLanguage(.japanese)
        model.setTargetLanguage(.simplifiedChinese)
        let captions = model.captions
        func openPicker() async throws {
            let point = windowPoint(SubtitleToolbarLayout(size: panel.frame.size).languagesCenter, size: panel.frame.size)
            try await clickTool("subtitle.languages", in: panel, at: point)
            for _ in 0..<40 where accessible("subtitle.languages.source.en") == nil {
                try await Task.sleep(nanoseconds: 40_000_000)
            }
            guard accessible("subtitle.languages.source.en") != nil else {
                throw CheckFailure("language_click_did_not_open_options_at_" + NSStringFromPoint(point))
            }
        }
        try await openPicker()
        try await pressAccessible("subtitle.languages.source.en")
        try await pressAccessible("subtitle.languages.cancel")
        try require(model.sourceLanguage == .japanese && model.targetLanguage == .simplifiedChinese
                    && model.captions == captions, "cancel_language_draft_preserves_cue_and_direction", &checks)
        try await openPicker()
        try await pressAccessible("subtitle.languages.source.en")
        try await pressAccessible("subtitle.languages.swap")
        try await pressAccessible("subtitle.languages.apply")
        for _ in 0..<30 where model.targetLanguage != .english { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(model.sourceLanguage == .simplifiedChinese && model.targetLanguage == .english
                    && model.captions == captions && model.isSubtitleOnly && panel.isVisible,
                    "apply_swapped_language_direction_in_place_without_clearing", &checks)
        model.setSourceLanguage(.japanese)
        model.setTargetLanguage(.simplifiedChinese)
    }

    // Query only this application's accessibility tree. The real popover may be hosted
    // by a separate AppKit window, depending on the macOS version.
    private static func accessible(_ identifier: String) -> AnyObject? {
        func find(_ object: Any, seen: inout Set<ObjectIdentifier>) -> AnyObject? {
            let node = object as AnyObject
            guard seen.insert(ObjectIdentifier(node)).inserted else { return nil }
            if node.accessibilityIdentifier?() == identifier { return node }
            for child in node.accessibilityChildren?() ?? [] {
                if let match = find(child, seen: &seen) { return match }
            }
            return nil
        }
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows where window.isVisible {
            if let node = find(window, seen: &seen) { return node }
        }
        return nil
    }

    private static func pressAccessible(_ identifier: String) async throws {
        for _ in 0..<30 {
            if let node = accessible(identifier), node.accessibilityPerformPress?() == true {
                try await Task.sleep(nanoseconds: 100_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw CheckFailure("inaccessible_control_" + identifier)
    }

    private static func findNativeControls(_ view: NSView?) -> SubtitleNativeControls.NativeControlsView? {
        guard let view else { return nil }
        if let native = view as? SubtitleNativeControls.NativeControlsView { return native }
        for child in view.subviews { if let result = findNativeControls(child) { return result } }
        return nil
    }

    private static func findPointerTracking(_ view: NSView?) -> SubtitlePointerTracking.TrackingView? {
        guard let view else { return nil }
        if let tracking = view as? SubtitlePointerTracking.TrackingView { return tracking }
        for child in view.subviews { if let result = findPointerTracking(child) { return result } }
        return nil
    }

    @discardableResult
    private static func pointer(_ inside: Bool, in panel: NSPanel) throws -> SubtitlePointerTracking.TrackingView {
        let location = inside ? CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2) : CGPoint(x: -8, y: -8)
        guard let tracking = findPointerTracking(panel.contentView),
              let event = NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        else { throw CheckFailure("missing_pointer_tracking") }
        if inside { tracking.mouseEntered(with: event) } else { tracking.mouseExited(with: event) }
        return tracking
    }

    private static func windowPoint(_ topLeadingPoint: CGPoint, size: CGSize) -> NSPoint {
        NSPoint(x: topLeadingPoint.x, y: size.height - topLeadingPoint.y)
    }

    private static func clickTool(_ identifier: String, in panel: NSPanel, at point: NSPoint) async throws {
        guard let tracking = findPointerTracking(panel.contentView),
              let movement = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw CheckFailure("missing_tool_tracking_" + identifier) }
        panel.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<25 {
            tracking.mouseMoved(with: movement)
            try await Task.sleep(nanoseconds: 50_000_000)
            if tracking.isInside.wrappedValue, let button = accessible(identifier),
               button.isAccessibilityEnabled?() != false {
                try click(panel, at: point)
                return
            }
        }
        throw CheckFailure("tool_inaccessible_after_pointer_move_" + identifier)
    }

    private static func click(_ panel: NSPanel, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { throw CheckFailure("missing_panel_click_event") }
            NSApp.postEvent(event, atStart: false)
        }
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
                "pinEnabled": panel.level == .statusBar, "panelLevel": panel.level.rawValue,
                "pointerInside": findPointerTracking(panel.contentView)?.isInside.wrappedValue ?? false,
                "trackingBounds": findPointerTracking(panel.contentView).map { NSStringFromRect($0.bounds) } ?? "missing",
                "mouseInWindow": NSStringFromPoint(panel.mouseLocationOutsideOfEventStream)]
    }

    private static func require(_ value: Bool, _ name: String, _ checks: inout [String]) throws {
        guard value else { throw CheckFailure(name) }
        checks.append(name)
    }
    @discardableResult
    private static func snapshot(_ window: NSWindow, to url: URL) throws -> NSBitmapImageRep {
        guard let view = window.contentView else { throw CheckFailure("no_content_view") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CheckFailure("no_bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure("no_png") }
        try data.write(to: url)
        return bitmap
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
