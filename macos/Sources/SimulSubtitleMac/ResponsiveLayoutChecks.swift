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
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
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
            // With a unified title bar the minimum usable height excludes the toolbar,
            // while the full-size content view includes it. Check both AppKit rectangles.
            let usable = window.contentLayoutRect.size
            let requestedHeight = abs(size.height - height) < 1 || abs(usable.height - height) < 1
            try require(abs(size.width - width) < 1 && requestedHeight,
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

            if args.contains("--six-source-layout") {
                let running = NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                    .compactMap(\.bundleIdentifier)
                let sources = [AudioCaptureEngine.systemAudioID] + Set(running).sorted().prefix(5)
                try require(sources.count == 6, "six_source_fixture_requires_five_running_apps_and_mac_audio")
                let previous = appearance.pinnedSubtitleSources
                for id in previous { appearance.unpinSubtitleSource(id) }
                defer {
                    for id in sources { appearance.unpinSubtitleSource(id) }
                    for id in previous.reversed() { appearance.pinSubtitleSource(id) }
                }
                for id in sources.reversed() { appearance.pinSubtitleSource(id) }
                for (w, h) in [(1200, 680), (900, 640), (640, 480)] {
                    try await checkLayout(home, CGFloat(w), CGFloat(h), .normal, "main-six-sources-\(w)")
                }
            }

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
            if let originalName = clips.selected?.name {
                let previousLanguage = AppLocalization.shared.language
                defer {
                    AppLocalization.shared.language = previousLanguage
                    clips.update(project) { $0.name = originalName }
                }
                clips.update(project) { $0.name = "SpaceLens — International Space Station Rendezvous and Docking · 同传剪辑记录" }
                for language in [SubtitleLanguage.simplifiedChinese, .english, .japanese] {
                    AppLocalization.shared.language = language
                    let name = "clip-toolbar-875-" + language.rawValue
                    try await checkLayout(clip, 875, 636, .normal, name)
                    let remove = try accessibilityFrame("clips.removeProject", label: "移出工作台", in: clip)
                    let save = try accessibilityFrame("clips.saveProject", label: "保存项目", in: clip)
                    let export = try accessibilityFrame("clips.exportRanges", label: "导出片段", in: clip)
                    try require(abs(save.minX - remove.maxX - 8) <= 2 && abs(save.midY - remove.midY) <= 1,
                                name + "_project_buttons_separated_and_aligned")
                    try require(export.width >= 70 && export.height <= 40 && export.width > export.height * 1.8 &&
                                clip.frame.insetBy(dx: -1, dy: -1).contains(export),
                                name + "_export_visible_in_one_row")
                }
            }
            try await checkLayout(clip, 1200, 680, .normal, "clip-editor-1200-100")
            try await checkLayout(clip, 900, 640, .medium, "clip-editor-900-125")
            try await checkLayout(clip, 900, 640, .large, "clip-editor-900-150")
            try await checkLayout(clip, 640, 420, .extraLarge, "clip-editor-640-200")
            try await checkZoomButton(clip, "clip")
            try require(clips.selected?.id == project && clips.selected?.ranges.count == 1, "clip_project_and_range_survive_resize")
            if let first = clips.selected?.ranges.first {
                var duplicate = first
                duplicate.id = UUID()
                duplicate.title = "选段 2"
                let adjacent = ClipRange(title: "选段 3", start: first.end, end: first.end + 1)
                let nested = ClipRange(title: "选段 4", start: first.start + first.duration / 4, end: first.end)
                let lanes = ClipTimeline150.lanes(for: [first, duplicate, adjacent, nested])
                try require(lanes[first.id] == 0 && lanes[duplicate.id] == 1, "clip_duplicate_ranges_each_have_their_own_lane")
                try require(lanes[nested.id] == 2 && lanes[adjacent.id] == 0, "clip_nested_ranges_remain_reachable_and_adjacent_cuts_share_lane")
                let cache = TimelineLaneCache()
                let a = ClipRange(title: "A", start: 1, end: 4)
                let b = ClipRange(title: "B", start: 5, end: 8)
                let initial = cache.lanes(for: [a, b])
                var moved = b
                moved.start = 0
                moved.end = 3
                let edited = cache.lanes(for: [a, moved])
                try require(initial[a.id] == initial[b.id] && edited[a.id] == initial[a.id]
                            && edited[b.id] != edited[a.id], "drag_across_start_moves_only_edited_range_to_free_lane")
                let added = ClipRange(title: "C", start: 2, end: 3)
                let afterAdd = cache.lanes(for: [a, moved, added])
                try require(afterAdd[a.id] == edited[a.id] && afterAdd[b.id] == edited[b.id]
                            && Set(afterAdd.values).count == 3, "add_overlap_preserves_both_existing_lanes")
                let afterDelete = cache.lanes(for: [moved, added])
                try require(afterDelete[b.id] == edited[b.id] && afterDelete[added.id] == afterAdd[added.id],
                            "delete_preserves_surviving_lanes")
                try require(cache.lanes(for: [a, moved, added]) == afterAdd
                            && cache.lanes(for: [a, moved]) == edited && cache.lanes(for: [a, b]) == initial,
                            "undo_delete_add_and_edit_restores_original_tracks")
                clips.update(project) { $0.ranges.append(duplicate) }
                try await checkLayout(clip, 1200, 680, .normal, "clip-overlapping-ranges")
            }
            let longMediaRange = ClipRange(title: "切片", start: 759.552, end: 1287.767)
            // A click anywhere in the 12 pt handle has zero displacement.
            for start in [true, false] {
                let same = ClipTimeline150.resized(longMediaRange, start: start, delta: 0, duration: 3314)
                try require(same == longMediaRange, start ? "clip_start_handle_click_keeps_time" : "clip_end_handle_click_keeps_time")
            }
            let shifted = ClipTimeline150.resized(longMediaRange, start: true, delta: 10 * 3314 / 1000.0, duration: 3314)
            try require(abs(shifted.start - 792.692) < 0.000001 && shifted.end == longMediaRange.end, "clip_long_media_handle_uses_only_pointer_delta")
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
            try await checkLayout(panel, 500, 76, .extraLarge, "subtitle-500x76-200")
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
            try require(subtitles.isBubble && panel.frame.size == CGSize(width: 44, height: 44), "subtitle_drag_to_bubble")
            subtitles.restoreFromBubble()
            try await settle()
            try require(panel.frame.size == expanded.size && model.captions.count == 1 && model.subtitleDisplayMode == .bilingual,
                        "subtitle_restores_caption_and_bilingual_preference")
            subtitles.returnHome()

            // The UI fixture intentionally has no models. A real override can only
            // be selected when the caller supplies an installed model directory.
            let routing: AppModel
            var routingSuite: String?
            defer { if let routingSuite { UserDefaults.standard.removePersistentDomain(forName: routingSuite) } }
            if let index = args.firstIndex(of: "--clip-real-models"), args.indices.contains(index + 1) {
                let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                let suite = "SimuSub.LayoutRouting." + UUID().uuidString
                routingSuite = suite
                let defaults = UserDefaults(suiteName: suite)!
                routing = AppModel(defaults: defaults, modelStore: LocalModelStore(root: root), modelDownloadsAllowed: false)
            } else {
                routing = model
            }
            let senseVoice = routing.profiles.first { $0.localModelID == "sensevoice" }
            let whisper = routing.profiles.first { $0.localModelID == "whisper-base" }
            try require(senseVoice != nil && whisper != nil, "language_recognition_profiles_available")
            for (language, profile) in [(SubtitleLanguage.japanese, senseVoice), (.english, whisper), (.traditionalChinese, senseVoice)] {
                routing.setSourceLanguage(language)
                let initialID = routing.recognitionProfile(for: language)?.id
                let installed = routing.recognitionChoices(for: language).contains { $0.id == profile?.id }
                routing.chooseRecognition(profile?.id, for: language)
                if args.contains("--clip-real-models") {
                    try require(installed && routing.recognitionProfile(for: language)?.id == profile?.id
                                && routing.hasRecognitionOverride(for: language), "clip_recognition_override_" + language.rawValue)
                } else {
                    try require(!installed && routing.recognitionProfile(for: language)?.id == initialID
                                && !routing.hasRecognitionOverride(for: language), "missing_clip_recognition_override_rejected_" + language.rawValue)
                }
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

    private static func accessibilityFrame(_ identifier: String, label: String, in window: NSWindow) throws -> CGRect {
        var seen = Set<ObjectIdentifier>()
        func find(_ object: AnyObject) -> CGRect? {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            let hasLabel = object.accessibilityRole?() == .button && object.accessibilityLabel?() == L10n.text(label)
            if object.accessibilityIdentifier?() == identifier || hasLabel,
               let frame = object.accessibilityFrame?(), !frame.isEmpty {
                return frame
            }
            for child in object.accessibilityChildren?() ?? [] {
                if let frame = find(child as AnyObject) { return frame }
            }
            return nil
        }
        guard let frame = find(window) else { throw ClipError.message("Missing visible control " + identifier) }
        return frame
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
