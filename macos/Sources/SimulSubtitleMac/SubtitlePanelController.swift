import AppKit
import SwiftUI

final class SubtitleFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubtitlePanelController: NSObject, ObservableObject, NSWindowDelegate {
    private(set) var panel: SubtitleFloatingPanel?
    private(set) var settingsWindow: NSWindow?
    private(set) weak var homeWindow: NSWindow?
    private weak var model: AppModel?
    private weak var appearance: HomeAppearance?
    private var shouldReturnHome = true
    @Published private(set) var isBubble = false
    @Published var isResizeHover = false
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var reassertTask: Task<Void, Never>?
    private var resizeStartFrame: NSRect?
    private var lastExpandedFrame: NSRect?
    private var zoomRestoreFrame: NSRect?
    private var pickerFrame: NSRect?
    private var closeTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let frameKey = "subtitle.panel.frame.v103"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults; super.init() }

    func configure(model: AppModel, appearance: HomeAppearance) {
        self.model = model
        self.appearance = appearance
        guard spaceObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReassertion() }
        }
        activationObserver = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReassertion() }
        }
    }

    func attachHomeWindow(_ window: NSWindow) { homeWindow = window }

    func synchronize() {
        guard let model else { return }
        if model.isSubtitleOnly { show() }
        else { hide(showHome: shouldReturnHome) }
    }

    func show() {
        guard let model, let appearance else { return }
        shouldReturnHome = true
        if panel == nil {
            let screen = homeWindow?.screen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 760)
            let width = min(800, max(320, visible.width - 40))
            let defaultFrame = NSRect(x: visible.midX - width / 2, y: visible.minY + 70, width: width, height: 96)
            var frame = defaults.string(forKey: frameKey).map(NSRectFromString) ?? defaultFrame
            if !frame.width.isFinite || !frame.height.isFinite || frame.width < 360 || frame.height < 40 {
                frame = defaultFrame
            }
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            let window = SubtitleFloatingPanel(contentRect: frame,
                styleMask: [.borderless, .resizable, .closable, .miniaturizable, .nonactivatingPanel],
                backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("subtitle.panel")
            window.title = "SimuSub 字幕"
            window.isReleasedWhenClosed = false
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.contentMinSize = NSSize(width: 48, height: 32)
            window.acceptsMouseMovedEvents = true
            window.delegate = self
            let hosting = NSHostingView(rootView: SubtitlePanelRoot(controller: self)
                .environmentObject(model).environmentObject(model.permissions).environmentObject(appearance))
            hosting.sizingOptions = []
            window.contentView = hosting
            panel = window
            lastExpandedFrame = frame
        }
        updatePin()
        homeWindow?.orderOut(nil)
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        panel?.orderFrontRegardless()
        scheduleReassertion()
    }

    func updatePin() {
        guard let panel, let model else { return }
        panel.level = model.isSubtitlePinned ? .statusBar : .normal
        panel.collectionBehavior = model.isSubtitlePinned
            ? [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Spaces/full-screen transitions complete asynchronously. Reassert at a few
    /// transition checkpoints without activating SimuSub or running a focus loop.
    func scheduleReassertion() {
        reassertTask?.cancel()
        reassertTask = Task { [weak self] in
            for delay: UInt64 in [0, 180_000_000, 500_000_000] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard !Task.isCancelled, let self, self.model?.isSubtitleOnly == true,
                      self.model?.isSubtitlePinned == true, let panel = self.panel,
                      panel.isVisible, !panel.isMiniaturized else { return }
                self.updatePin()
                panel.orderFrontRegardless()
            }
        }
    }

    func beginUserResize() { resizeStartFrame = panel?.frame }

    func finishUserResize() {
        guard let panel else { return }
        isResizeHover = false
        if SubtitleDensity.forSize(panel.frame.size) == .bubble { collapseToBubble() }
        else { lastExpandedFrame = panel.frame; saveFrame() }
        resizeStartFrame = nil
    }

    func collapseToBubble() {
        guard let panel, !isBubble else { return }
        lastExpandedFrame = resizeStartFrame ?? lastExpandedFrame ?? panel.frame
        isBubble = true
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.styleMask.remove(.resizable)
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - 48, width: 48, height: 48)
        panel.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func restoreFromBubble() {
        guard let panel else { return }
        isBubble = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.styleMask.insert(.resizable)
        let old = lastExpandedFrame ?? NSRect(x: panel.frame.minX, y: panel.frame.maxY - 96, width: 800, height: 96)
        var target = NSRect(x: panel.frame.minX, y: panel.frame.maxY - old.height, width: max(360, old.width), height: max(40, old.height))
        if let screen = panel.screen?.visibleFrame {
            target.size.width = min(target.width, screen.width)
            target.size.height = min(target.height, screen.height)
            target.origin.x = min(max(target.minX, screen.minX), screen.maxX - target.width)
            target.origin.y = min(max(target.minY, screen.minY), screen.maxY - target.height)
        }
        panel.setFrame(target, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastExpandedFrame = target
        saveFrame()
        scheduleReassertion()
    }

    func toggleZoom() {
        guard let panel else { return }
        if let restore = zoomRestoreFrame {
            panel.setFrame(restore, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            zoomRestoreFrame = nil
        } else if let visible = panel.screen?.visibleFrame {
            zoomRestoreFrame = panel.frame
            let width = min(1000, visible.width - 32), height = min(360, visible.height - 32)
            let expanded = NSRect(x: min(max(panel.frame.midX - width / 2, visible.minX + 16), visible.maxX - width - 16),
                y: min(max(panel.frame.minY, visible.minY + 16), visible.maxY - height - 16), width: width, height: height)
            panel.setFrame(expanded, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        lastExpandedFrame = panel.frame
        saveFrame()
        scheduleReassertion()
    }

    func openSubtitleSettings() {
        guard let model, let appearance else { return }
        if settingsWindow == nil {
            let height = min(700, ((panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 780) - 80)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: height),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "字幕设置"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = ThemePalette.color(appearance.theme, dark: appearance.isDark, role: .background)
            window.identifier = NSUserInterfaceItemIdentifier("subtitle.settings.window")
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 440)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: SubtitleQuickSettings()
                .environmentObject(model).environmentObject(model.permissions).environmentObject(appearance)
                .appTheme().environmentObject(appearance))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.level = NSWindow.Level(rawValue: (panel?.level.rawValue ?? NSWindow.Level.normal.rawValue) + 1)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func prepareForPicker() { if pickerFrame == nil { pickerFrame = panel?.frame } }
    func finishPicker() {
        if let pickerFrame { panel?.setFrame(pickerFrame, display: true) }
        pickerFrame = nil
        model?.applicationPickerDidDismiss()
        scheduleReassertion()
    }

    func returnHome() {
        shouldReturnHome = true
        model?.cancelApplicationSelection()
        model?.isSubtitleOnly = false
        hide(showHome: true)
    }

    func openHomeFromDock() {
        if panel?.isMiniaturized == true, model?.isSubtitleOnly == true {
            panel?.deminiaturize(nil)
            scheduleReassertion()
            return
        }
        shouldReturnHome = true
        model?.section = .live
        model?.isSubtitleOnly = false
        hide(showHome: true)
    }

    func closeSubtitles() {
        shouldReturnHome = false
        model?.cancelApplicationSelection()
        model?.isSubtitleOnly = false
        hide(showHome: false)
        guard closeTask == nil, let model else { return }
        closeTask = Task { [weak self] in
            await model.finishSubtitleSession()
            self?.closeTask = nil
        }
    }

    private func hide(showHome: Bool) {
        reassertTask?.cancel()
        settingsWindow?.orderOut(nil)
        if let panel, panel.isVisible { saveFrame(); panel.orderOut(nil) }
        if showHome, let homeWindow {
            homeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func saveFrame() {
        if let panel { defaults.set(NSStringFromRect(isBubble ? (lastExpandedFrame ?? panel.frame) : panel.frame), forKey: frameKey) }
    }

    func windowWillStartLiveResize(_ notification: Notification) { beginUserResize() }
    func windowDidEndLiveResize(_ notification: Notification) { finishUserResize() }
    func windowDidDeminiaturize(_ notification: Notification) { scheduleReassertion() }
    func windowDidChangeScreen(_ notification: Notification) { scheduleReassertion() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeSubtitles(); return false }
}

struct HomeWindowBridge: NSViewRepresentable {
    let controller: SubtitlePanelController
    func makeNSView(context: Context) -> WindowReader { WindowReader(controller: controller) }
    func updateNSView(_ nsView: WindowReader, context: Context) { }
    final class WindowReader: NSView {
        let controller: SubtitlePanelController
        init(controller: SubtitlePanelController) { self.controller = controller; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                controller.attachHomeWindow(window)
            }
        }
    }
}

@MainActor
final class SimuSubAppDelegate: NSObject, NSApplicationDelegate {
    weak var subtitles: SubtitlePanelController?
    weak var liveMonitor: LiveMonitorStore?
    weak var clips: ClipStore?
    private var terminating = false
    private var readyToTerminate = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if readyToTerminate { return .terminateNow }
        guard let liveMonitor else { return .terminateNow }
        if terminating { return .terminateCancel }
        terminating = true
        // Keep the ordinary app run loop alive while FFmpeg finalizes its file.
        // A second termination request only exits after shutdown has completed.
        Task {
            clips?.cancel()
            await liveMonitor.shutdown()
            await clips?.shutdown()
            readyToTerminate = true
            sender.terminate(nil)
        }
        return .terminateCancel
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard subtitles?.homeWindow != nil else { return true }
        subtitles?.openHomeFromDock()
        return false
    }
}

private struct SubtitlePanelRoot: View {
    @ObservedObject var controller: SubtitlePanelController
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: HomeAppearance

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            Group {
                if controller.isBubble || SubtitleDensity.forSize(geometry.size) == .bubble {
                    SubtitleBubble(controller: controller, active: model.isCapturing, busy: model.isStarting || model.isStopping)
                } else {
                    SubtitleStrip(captions: model.captions,
                                  presentation: SubtitlePresentation(size: geometry.size, subtitleOnly: true, displayMode: model.subtitleDisplayMode),
                                  size: geometry.size, isPinned: model.isSubtitlePinned,
                                  onTogglePin: { model.isSubtitlePinned.toggle(); controller.scheduleReassertion() },
                                  onExit: controller.returnHome, onZoom: controller.toggleZoom, onClose: controller.closeSubtitles,
                                  displayMode: model.subtitleDisplayMode,
                                  onToggleDisplayMode: { model.subtitleDisplayMode = model.subtitleDisplayMode == .bilingual ? .chinese : .bilingual },
                                  onExport: { model.exportCaptions(format: $0) },
                                  onClear: { Task { await model.clearCaptions() } }, canClear: model.canClearCaptions,
                                  idleText: model.subtitleStatus, isCapturing: model.isCapturing,
                                  isBusy: model.isStarting || model.isStopping || model.isLoadingApplications || model.isClearingCaptions,
                                  canStartStop: !(model.isDownloadingModels && !model.readinessIssues.isEmpty),
                                  onStartStop: { if model.subtitlePlaybackIntent == .chooseApplication { controller.prepareForPicker() }; model.toggleSubtitlePlayback() },
                                  onSettings: controller.openSubtitleSettings,
                                  japaneseFont: appearance.japaneseFont, chineseFont: appearance.chineseFont,
                                  japaneseSize: appearance.japaneseSize, chineseSize: appearance.chineseSize)
                        .contextMenu { SubtitleWindowMenu(model: model); Button("收起为悬浮图标") { controller.collapseToBubble() } }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(ThemeColor.primary.opacity(controller.isResizeHover ? 0.65 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay { if !controller.isBubble { SubtitleResizeSurface(controller: controller) } }
        }
        .appTheme(clearBackground: true)
        .onChange(of: model.isSubtitlePinned) { _ in controller.updatePin() }
        .onChange(of: model.isLoadingApplications) { loading in if loading { controller.prepareForPicker() } }
        .sheet(isPresented: $model.isChoosingApplication, onDismiss: controller.finishPicker) {
            CaptureApplicationPicker().environmentObject(model)
        }
        .alert("需要处理", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
            Button(model.errorSection.rawValue) {
                model.section = model.errorSection
                model.errorMessage = nil
                controller.returnHome()
            }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct CaptureApplicationPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ApplicationDockPicker(applications: model.availableApps, selectedBundleID: model.selectedAppBundleID,
                              isRefreshing: model.isLoadingApplications,
                              onRefresh: model.selectApplication,
                              onSelect: model.chooseApplication,
                              onCancel: model.cancelApplicationSelection)
    }
}

private struct SubtitleBubble: View {
    @ObservedObject var controller: SubtitlePanelController
    var active: Bool
    var busy: Bool
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "captions.bubble.fill").font(.system(size: 23, weight: .regular))
                .foregroundStyle(ThemeColor.primary).frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
            Circle().fill(busy ? Color.orange : (active ? Color.green : ThemeColor.muted))
                .frame(width: 6, height: 6).padding(7)
                .accessibilityHidden(true)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay { SubtitleBubbleInteraction(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
