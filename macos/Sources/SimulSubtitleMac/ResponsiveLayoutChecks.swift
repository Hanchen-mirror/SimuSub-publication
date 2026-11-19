import AppKit

@MainActor
enum ResponsiveLayoutChecks {
    private static var started = false

    static func runIfRequested(model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore,
                               clips: ClipStore, subtitles: SubtitlePanelController) async -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--responsive-layout-check"), args.count > index + 2 else { return false }
        guard !started else { return true }
        started = true
        let output = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let fixture = URL(fileURLWithPath: args[index + 2])
        let controller = ClipWindowController()
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message(name) }
            checks.append(name)
        }
        @discardableResult
        func checkLayout(_ window: NSWindow, _ width: CGFloat, _ height: CGFloat, _ zoom: WorkspaceZoom,
                         _ name: String) async throws -> Data {
            appearance.workspaceZoom = zoom
            window.setContentSize(NSSize(width: width, height: height))
            try await settle()
            let image = try snapshot(window, named: name, in: output)
            let size = window.contentView?.bounds.size ?? .zero
            try require(abs(size.width - width) < 1 && abs(size.height - height) < 32,
                        "\(name)_native_size_\(Int(size.width))x\(Int(size.height))")
            return image
        }
        func checkZoomButton(_ window: NSWindow, _ name: String) async throws {
            let frame = window.frame
            window.zoom(nil)
            try await settle()
            try require(window.frame.width > frame.width && window.frame.height > frame.height, name + "_window_zoom_expands")
            window.zoom(nil)
            try await settle()
            try require(window.frame == frame, name + "_window_zoom_restores")
        }

        var failure: String?
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            appearance.theme = .green
            appearance.mode = .dark
            try await settle()
            guard let home = subtitles.homeWindow else { throw ClipError.message("main_window_not_attached") }

            try await checkLayout(home, 1200, 680, .normal, "main-1200-100")
            try await checkLayout(home, 900, 640, .normal, "main-900-100")
            try await checkLayout(home, 640, 480, .normal, "main-640-100")
            try await checkLayout(home, 1000, 680, .medium, "main-1000-125")
            try await checkLayout(home, 900, 640, .large, "main-900-150")
            let before = try await checkLayout(home, 640, 420, .extraLarge, "main-640-200")
            try await checkZoomButton(home, "main")

            home.makeKeyAndOrderFront(nil)
            try click(home, x: 443, fromTop: 70)
            try await settle()
            let after = try snapshot(home, named: "services-640-200", in: output)
            try require(before != after, "main_services_navigation_at_200_changes_rendering")
            try await checkLayout(home, 1200, 680, .normal, "services-1200-100")
            try await checkLayout(home, 900, 640, .large, "services-900-150")

            appearance.workspaceZoom = .normal
            controller.show(creatorID: nil, tool: .edit, model: model, appearance: appearance, monitor: monitor, clips: clips)
            guard let clip = controller.window else { throw ClipError.message("clip_window_not_created") }
            try await checkLayout(clip, 1200, 680, .normal, "clip-import-1200-100")
            try await checkLayout(clip, 640, 420, .extraLarge, "clip-import-640-200")
            let project = try await clips.importVideo(fixture)
            try await checkLayout(clip, 1200, 680, .normal, "clip-editor-1200-100")
            try await checkLayout(clip, 900, 640, .medium, "clip-editor-900-125")
            try await checkLayout(clip, 900, 640, .large, "clip-editor-900-150")
            try await checkLayout(clip, 640, 420, .extraLarge, "clip-editor-640-200")
            try await checkZoomButton(clip, "clip")
            try require(clips.selected?.id == project && clips.selected?.ranges.count == 1, "clip_project_and_range_survive_resize")
            clip.orderOut(nil)

            appearance.workspaceZoom = .normal
            model.captions = [Caption(start: 0, end: 2, original: "今日は配信を楽しみましょう。", translated: "今天一起開心地看直播吧。")]
            model.subtitleDisplayMode = .bilingual
            model.isSubtitleOnly = true
            subtitles.show()
            guard let panel = subtitles.panel else { throw ClipError.message("subtitle_panel_not_created") }
            try await checkLayout(panel, 800, 180, .normal, "subtitle-800x180-100")
            let frame = panel.frame
            let beforeZoom = try snapshot(panel, named: "subtitle-before-zoom", in: output)
            appearance.workspaceZoom = .medium
            try await settle()
            let afterZoom = try snapshot(panel, named: "subtitle-800x180-125", in: output)
            try require(beforeZoom != afterZoom && panel.frame == frame, "subtitle_zoom_changes_rendering_in_same_window_bounds")
            try await checkLayout(panel, 800, 96, .large, "subtitle-800x96-150")
            try await checkLayout(panel, 500, 48, .extraLarge, "subtitle-500x48-200")
            panel.setContentSize(NSSize(width: 800, height: 96))
            let expanded = panel.frame
            subtitles.toggleZoom()
            try await settle()
            try require(panel.frame.height > expanded.height, "subtitle_window_zoom_expands")
            subtitles.toggleZoom()
            try await settle()
            try require(panel.frame == expanded, "subtitle_window_zoom_restores")
            subtitles.beginUserResize()
            panel.setContentSize(NSSize(width: 180, height: 32))
            subtitles.finishUserResize()
            try await settle()
            try require(subtitles.isBubble && panel.frame.size == CGSize(width: 48, height: 48), "subtitle_drag_to_bubble")
            subtitles.restoreFromBubble()
            try await settle()
            try require(panel.frame.size == expanded.size && model.captions.count == 1 && model.subtitleDisplayMode == .bilingual,
                        "subtitle_restores_caption_and_bilingual_preference")
            subtitles.returnHome()

            let senseVoice = model.profiles.first { $0.localModelID == "sensevoice" }
            let whisper = model.profiles.first { $0.localModelID == "whisper-base" }
            try require(senseVoice != nil && whisper != nil, "language_recognition_profiles_available")
            model.chooseRecognition(senseVoice?.id, for: .japanese)
            model.chooseRecognition(whisper?.id, for: .english)
            model.chooseRecognition(senseVoice?.id, for: .simplifiedChinese)
            for (language, profile) in [(SubtitleLanguage.japanese, senseVoice), (.english, whisper), (.traditionalChinese, senseVoice)] {
                model.setSourceLanguage(language)
                try require(model.recognitionProfile(for: language)?.id == profile?.id, "clip_recognition_override_" + language.rawValue)
            }
        } catch {
            failure = error.localizedDescription
        }
        controller.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: clips.root)
        let result: [String: Any] = ["passed": failure == nil, "checks": checks, "error": failure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("layout-results.json"), options: .atomic)
        }
        print(failure.map { "Layout check failed: " + $0 } ?? "Passed \(checks.count) native layout checks")
        exit(failure == nil ? 0 : 1)
    }

    private static func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func click(_ window: NSWindow, x: CGFloat, fromTop: CGFloat) throws {
        let point = NSPoint(x: x, y: window.frame.height - fromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw ClipError.message("Cannot generate window click")
            }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private static func snapshot(_ window: NSWindow, named name: String, in output: URL) throws -> Data {
        guard let view = window.contentView else { throw ClipError.message("Missing content for " + name) }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ClipError.message("Missing bitmap for " + name)
        }
        view.cacheDisplay(in: view.bounds, to: image)
        guard let png = image.representation(using: .png, properties: [:]) else {
            throw ClipError.message("Cannot encode " + name)
        }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        return png
    }
}
