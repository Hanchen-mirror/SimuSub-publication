import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SubtitleConfiguration: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subtitles: SubtitlePanelController
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var transitionAnimation: Animation? {
        systemReduceMotion || appearance.reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
    var onServices: () -> Void
    private let spokenLanguages: [SubtitleLanguage] = [.simplifiedChinese, .english, .japanese]
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            let layout = WorkspaceMetrics(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DesignPageHeading(title: "字幕同传") { EmptyView() }
                    layout.columns {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(L10n.text("声音来源")).interfaceFont(size: 16, weight: .semibold)
                            SubtitleSourceDock(compact: layout.narrow).zIndex(2)
                            HStack(alignment: .bottom, spacing: 14) {
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(L10n.text("源语言")).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
                                    DesignMenuField(title: L10n.text(spokenName(model.sourceLanguage))) {
                                        ForEach(spokenLanguages, id: \.self) { language in
                                            Button(L10n.text(spokenName(language))) { model.setSourceLanguage(language) }
                                        }
                                    }.accessibilityIdentifier("subtitle.sourceLanguage")
                                }.frame(maxWidth: .infinity)
                                Button(action: model.swapLanguages) {
                                    Image(systemName: "arrow.left.arrow.right").interfaceFont(size: 16, weight: .medium)
                                        .frame(width: 40, height: 40)
                                        .background(ThemeColor.control, in: Circle())
                                        .overlay(Circle().strokeBorder(ThemeColor.line))
                                }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk).padding(.bottom, 2)
                                    .help(L10n.text("交换语言")).accessibilityLabel(L10n.text("交换语言"))
                                    .accessibilityIdentifier("subtitle.swapLanguages")
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(L10n.text("翻译为")).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
                                    DesignMenuField(title: L10n.text(model.targetLanguage.name)) {
                                        ForEach(SubtitleLanguage.allCases, id: \.self) { language in
                                            Button(L10n.text(language.name)) { model.setTargetLanguage(language) }
                                        }
                                    }.accessibilityIdentifier("subtitle.targetLanguage")
                                }.frame(maxWidth: .infinity)
                            }.disabled(model.isBusy)
                            if let issue = model.recognitionLanguageIssue {
                                Button(action: onServices) { Label(L10n.text(issue), systemImage: "slider.horizontal.3") }
                                    .buttonStyle(.plain).interfaceFont(size: 12).foregroundStyle(ThemeColor.primaryInk)
                                    .accessibilityIdentifier("subtitle.languageService")
                            }
                            SubtitleStartControl(title: startTitle) {
                                if model.isCapturing { model.isSubtitleOnly = true; subtitles.show() }
                                else { model.startCapture(showSubtitles: true) }
                            }
                                .disabled((model.selectedAppBundleID == nil && !model.isCapturing) || (!model.canBeginSubtitleCapture && !model.isCapturing) || model.isStopping || model.isLoadingApplications || model.recognitionLanguageIssue != nil)
                                .accessibilityIdentifier("subtitle.start")
                            if model.subtitleNeedsPermission {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L10n.text("请在系统设置中允许 SimuSub 采集应用音频。"))
                                        .font(.caption).foregroundStyle(ThemeColor.muted)
                                    let actions = layout.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
                                    actions {
                                        Button(L10n.text("打开系统录制权限设置"), action: model.openSubtitlePermissionSettings)
                                        Button(L10n.text("重试"), action: model.retrySubtitlePermission)
                                        Button(L10n.text("取消"), action: model.cancelSubtitlePermissionResume)
                                    }.disabled(model.isBusy)
                                }
                            }
                            if let error = model.subtitleStartError {
                                Text(L10n.text(error)).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
                            }
                        }.designPanel(inset: layout.cardInset).zIndex(1).accessibilityIdentifier("subtitle.sourcePanel")
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(L10n.text("字幕外观")).interfaceFont(size: 16, weight: .semibold)
                                Spacer()
                                Toggle(L10n.text("显示原文"), isOn: Binding(get: { model.subtitleDisplayMode != .chinese }, set: { model.subtitleDisplayMode = $0 ? .bilingual : .chinese }))
                                    .toggleStyle(DesignToggleStyle()).fixedSize()
                            }
                            VStack(spacing: 7) {
                                if model.subtitleDisplayMode == .bilingual {
                                    LiveCaptionText(text: model.sourceLanguage.preview,
                                        font: SubtitleFont.native(appearance.japaneseFont, size: appearance.japaneseSize, weight: .medium),
                                        fallback: ThemeColor.muted, style: appearance.captionStyle)
                                        .transition(.opacity)
                                }
                                LiveCaptionText(text: model.originalOnly ? model.sourceLanguage.preview : model.targetLanguage.preview,
                                    font: SubtitleFont.native(model.originalOnly ? appearance.japaneseFont : appearance.chineseFont,
                                        size: model.originalOnly ? appearance.japaneseSize : appearance.chineseSize, weight: .semibold),
                                    fallback: ThemeColor.ink, style: appearance.captionStyle)
                            }.padding(10).frame(maxWidth: .infinity, minHeight: 104).background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 12))
                                .animation(transitionAnimation, value: model.subtitleDisplayMode)
                            LiveCaptionStylePicker()
                            SubtitleFontSettings(inlineSizes: true)
                        }.designPanel(inset: layout.cardInset).accessibilityIdentifier("subtitle.appearancePanel")
                    }
                }.padding(layout.gutter)
            }.accessibilityIdentifier(layout.stacked ? "subtitle.layout.stacked" : "subtitle.layout.columns")
        }.background(ThemeColor.background)
    }
    private var startTitle: String {
        if model.isStarting { return model.status }
        if model.isStopping { return "正在暂停…" }
        if model.isCapturing { return "打开字幕浮窗" }
        return model.modelsAreDownloading ? "正在准备本地字幕" : "开始同传"
    }

    private func spokenName(_ language: SubtitleLanguage) -> String { language.isChinese ? "中文" : language.name }

}

struct SubtitlePreparationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("准备本地字幕")).font(.headline)
            if model.isDownloadingModels {
                ProgressView(value: model.downloadProgress)
                    .accessibilityLabel(L10n.text("正在准备本地字幕"))
            } else if let bytes = model.subtitlePreparationBytes {
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                Text(L10n.text("本次需下载 \(size)，准备好后自动开始同传。"))
                    .foregroundStyle(ThemeColor.muted)
            }
            if let error = model.subtitlePreparationError {
                Text(L10n.text(error)).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: model.cancelSubtitlePreparation)
                if !model.isDownloadingModels {
                    Button(L10n.text(model.subtitlePreparationError == nil ? "准备本地字幕" : "重试"), action: model.prepareSubtitleModels)
                        .buttonStyle(ThemeActionButtonStyle(prominent: true))
                        .accessibilityIdentifier("subtitle.prepareModels")
                }
            }
        }.padding(24).frame(width: 420).background(ThemeColor.surface)
            .accessibilityIdentifier("subtitle.preparation")
    }
}

struct SubtitleSourceDock: View {
    var compact = false
    @EnvironmentObject private var model: AppModel
    @State private var apps: [NSRunningApplication] = []
    @State private var more = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var editing = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || appearance.reduceMotion }
    private var motion: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.18) }
    @AppStorage("subtitle.hiddenSources.v150") private var hiddenSources = ""
    private var hiddenIDs: Set<String> { Set(hiddenSources.split(separator: "|").map(String.init)) }
    private func select(_ id: String, app: NSRunningApplication?) {
        guard !model.isBusy else { return }
        editing = false
        if id == AudioCaptureEngine.systemAudioID { model.setSubtitleSource(id: id, name: "Mac 声音") }
        else if let app { choose(app) }
    }
    private func remove(_ id: String) {
        guard !model.isBusy else { return }
        if sourceIDs.count == 1 { editing = false }
        var hidden = hiddenIDs; hidden.insert(id); hiddenSources = hidden.sorted().joined(separator: "|")
        appearance.unpinSubtitleSource(id)
        if model.selectedAppBundleID == id { model.setSubtitleSource(id: nil, name: nil) }
    }
    private func restore(_ id: String) {
        var hidden = hiddenIDs; hidden.remove(id); hiddenSources = hidden.sorted().joined(separator: "|")
    }
    private var sourceIDs: [String] {
        Self.visibleSources(running: apps.compactMap(\.bundleIdentifier), order: appearance.sourceOrder,
                            pinned: appearance.pinnedSubtitleSources, hidden: hiddenIDs, selected: model.selectedAppBundleID)
    }
    static func visibleSources(running: [String], order: [String], pinned: [String], hidden: Set<String>, selected: String?) -> [String] {
        let available = [AudioCaptureEngine.systemAudioID] + running
        var remaining = Set(available).subtracting(hidden)
        let visiblePins = pinned.filter { remaining.remove($0) != nil }
        let candidates = (order + available).filter { remaining.remove($0) != nil }
        var suggested = Array(candidates.prefix(max(0, 5 - visiblePins.count)))
        if let selected, candidates.contains(selected), !suggested.contains(selected) {
            if !suggested.isEmpty { suggested.removeLast() }
            suggested.append(selected)
        }
        return visiblePins + suggested
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 58 : 54), spacing: 7)], spacing: 7) {
                ForEach(sourceIDs, id: \.self) { id in
                    let app = apps.first { $0.bundleIdentifier == id }
                    let system = id == AudioCaptureEngine.systemAudioID
                    let name = system ? "Mac 声音" : app.map(shortName) ?? ""
                    let selected = model.selectedAppBundleID == id
                    let shell = RoundedRectangle(cornerRadius: 12, style: .continuous)
                    let tile = VStack(spacing: 5) {
                        if system {
                            Image(systemName: "speaker.wave.2").font(.system(size: 27, weight: .light)).frame(width: 36, height: 36)
                        } else {
                            Image(nsImage: app?.icon ?? NSImage()).resizable().scaledToFit().frame(width: 36, height: 36)
                        }
                        Text(L10n.text(name)).interfaceFont(size: 10).lineLimit(1)
                        Circle().fill(selected ? ThemeColor.primary : .clear).frame(width: 4, height: 4)
                    }.frame(maxWidth: .infinity).frame(height: 86)
                        .background {
                            if editing {
                                ZStack {
                                    if reduceTransparency {
                                        shell.fill(selected ? ThemeColor.selection : ThemeColor.control)
                                    } else {
                                        shell.fill(.regularMaterial)
                                        shell.fill(ThemeColor.primary.opacity(selected ? 0.24 : 0.11))
                                    }
                                    shell.strokeBorder(selected ? ThemeColor.primary : ThemeColor.muted.opacity(0.68),
                                                       lineWidth: selected ? 1.5 : 1)
                                }
                            } else if selected {
                                shell.fill(ThemeColor.soft)
                            }
                        }
                    ZStack(alignment: .topLeading) {
                        tile.modifier(SourceEditMotion(enabled: editing && !reduceMotion))
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        SubtitlePressButton(title: L10n.text(name), identifier: system ? "source.systemAudio" : "source." + id,
                                            selected: selected, duration: 0.55,
                                            onHold: { if !editing { editing = true } },
                                            onRemove: { withAnimation(motion) { remove(id) } },
                                            activate: { select(id, app: app) })
                            .frame(maxWidth: .infinity).frame(height: 86)
                        if editing {
                            SourceRemoveButton(title: L10n.text("移除") + " " + name) {
                                withAnimation(motion) { remove(id) }
                            }
                            .frame(width: 17, height: 17)
                            .background(ThemeColor.control, in: Circle())
                            .overlay {
                                ZStack {
                                    Circle().strokeBorder(ThemeColor.line)
                                    Image(systemName: "xmark").font(.system(size: 7, weight: .semibold))
                                }.allowsHitTesting(false).accessibilityHidden(true)
                            }
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                }
                Button { editing = false; reload(); more.toggle(); searchFocused = more } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "plus").interfaceFont(size: 23, weight: .light).frame(width: 36, height: 36)
                        Text(L10n.text("其他")).interfaceFont(size: 10).lineLimit(1)
                        Color.clear.frame(width: 4, height: 4).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity).frame(height: 86)
                }.buttonStyle(.plain).foregroundStyle(ThemeColor.muted)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ThemeColor.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .accessibilityIdentifier("source.more")
            }.padding(.vertical, 8).disabled(model.isBusy)
                .background {
                    if editing {
                        SourceEditDismissal { editing = false }
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .animation(motion, value: model.selectedAppBundleID)
            if more { moreApplications.disabled(model.isBusy).transition(.opacity) }
        }
        .animation(motion, value: more)
        .onExitCommand { editing = false; more = false }.onAppear(perform: reload)
            .onDisappear { editing = false }
            .onChange(of: model.isBusy) { if $0 { editing = false } else { reload() } }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
    }
    private var matchesSystemAudio: Bool {
        search.isEmpty || L10n.text("Mac 声音").localizedCaseInsensitiveContains(search)
    }
    private var matchingApps: [NSRunningApplication] {
        apps.filter { search.isEmpty || ($0.localizedName ?? "").localizedCaseInsensitiveContains(search) }
    }
    private var moreApplications: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColor.muted)
                TextField(L10n.text("搜索应用"), text: $search, prompt: Text(L10n.text("搜索应用")).foregroundColor(ThemeColor.muted)).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("source.search")
                Button { more = false; searchFocused = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("关闭应用列表"))
            }.padding(10).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                VStack(spacing: 4) {
                    if matchesSystemAudio {
                        Button { addSource(AudioCaptureEngine.systemAudioID, app: nil) } label: {
                            HStack(spacing: 12) { Image(systemName: "speaker.wave.2").frame(width: 25, height: 25); Text(L10n.text("Mac 声音")); Spacer() }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    ForEach(matchingApps, id: \.processIdentifier) { app in
                        Button { if let id = app.bundleIdentifier { addSource(id, app: app) } } label: {
                            HStack(spacing: 12) { Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 25, height: 25); Text(L10n.text(app.localizedName ?? "应用")).interfaceFont(size: 12); Spacer(); if app.bundleIdentifier == model.selectedAppBundleID { Image(systemName: "checkmark").foregroundStyle(ThemeColor.primary) } }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if !matchesSystemAudio && matchingApps.isEmpty { Text(L10n.text("没有匹配的应用")).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted).padding() }
                }
            }.frame(height: 172)
            HStack { Spacer(); Button(L10n.text("刷新应用"), action: reload).interfaceFont(size: 11) }
        }.padding(10).frame(maxWidth: .infinity).background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ThemeColor.line))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .onAppear { searchFocused = true }
    }
    private func addSource(_ id: String, app: NSRunningApplication?) {
        guard !model.isBusy else { return }
        restore(id)
        appearance.pinSubtitleSource(id)
        select(id, app: app)
        more = false
        searchFocused = false
    }
    private func shortName(_ app: NSRunningApplication) -> String {
        if app.bundleIdentifier == "com.apple.Safari" { return "Safari" }
        if app.bundleIdentifier == "com.google.Chrome" { return "Chrome" }
        return app.localizedName ?? "应用"
    }
    private func choose(_ app: NSRunningApplication) {
        guard !model.isBusy else { return }
        // Configuration only. Screen/audio permission and capture start remain
        // in AppModel.startCapture, triggered by the explicit Start button.
        model.setSubtitleSource(id: app.bundleIdentifier, name: app.localizedName)
    }
    private func reload() {
        let preferred = ["com.apple.Safari", "com.google.Chrome", "com.colliderli.iina", "org.videolan.vlc"]
        var seen = Set<String>()
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }.sorted {
            let a = preferred.firstIndex(of: $0.bundleIdentifier ?? "") ?? 99, b = preferred.firstIndex(of: $1.bundleIdentifier ?? "") ?? 99
            return a == b ? ($0.localizedName ?? "") < ($1.localizedName ?? "") : a < b
        }.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return seen.insert(id).inserted
        }
        if !model.isBusy, !model.subtitleNeedsPermission, let selected = model.selectedAppBundleID,
           hiddenIDs.contains(selected) || (selected != AudioCaptureEngine.systemAudioID && !apps.contains(where: { $0.bundleIdentifier == selected })) {
            model.setSubtitleSource(id: nil, name: nil)
        }
    }
}

// Keep the remove badge a separate native target. The window monitor can
// distinguish this action from blank pixels even under workspace zoom.
private struct SourceRemoveButton: NSViewRepresentable {
    var title: String
    var remove: () -> Void

    final class Control: NSButton {
        var remove: (() -> Void)?
        @objc func removeSource() { remove?() }
    }

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.title = ""
        button.isBordered = false
        button.target = button
        button.action = #selector(Control.removeSource)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        button.setAccessibilityLabel(title)
        button.remove = remove
    }
}

// Native menus and toolbar controls can handle the mouse before a parent SwiftUI tap
// gesture sees it. Observe only this window while editing, and forward ordinary clicks.
private struct SourceEditDismissal: NSViewRepresentable {
    var dismiss: () -> Void

    final class Observer: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        var dismiss: (() -> Void)?
        var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }
                    self.dismiss?()
                    return nil
                }
                // Only the remove badge needs edit mode to survive mouse-down.
                // An independent click anywhere else dismisses and is forwarded
                // so a menu, another source, or a navigation button still works.
                if let content = window.contentView,
                   let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
                   hit is SourceRemoveButton.Control {
                    return event
                }
                self.dismiss?()
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }

    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: Observer, coordinator: Void) { view.stop() }
}

private struct SourceEditMotion: ViewModifier {
    var enabled: Bool
    @State private var phase = false
    func body(content: Content) -> some View {
        if enabled {
            content.rotationEffect(.degrees(phase ? 1.2 : -1.2))
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { phase = true }
                }
                .onDisappear { phase = false }
        } else {
            content
        }
    }
}

private struct SubtitleStartControl: View {
    var title: String
    var action: () -> Void
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        ZStack {
            Label(L10n.text(title), systemImage: "play")
                .interfaceFont(size: 13, weight: .medium)
                .foregroundStyle(ThemeColor.surface)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        shape.fill(ThemeColor.primary)
                        if !appearance.reduceMotion && !systemReduceMotion {
                            Rectangle().fill(ThemeColor.primaryInk.opacity(0.12))
                                .scaleEffect(x: pressed ? 1 : 0, anchor: .leading)
                                .animation(pressed ? .linear(duration: 0.8) : nil, value: pressed)
                        }
                    }.clipShape(shape)
                }
                .opacity(enabled ? (pressed ? 0.8 : 1) : 0.45)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .overlay {
            SubtitlePressButton(title: L10n.text(title), identifier: "subtitle.start", duration: 0.8,
                                onPress: { pressed = $0 }, activate: action)
        }
    }
}

private struct SubtitlePressButton: NSViewRepresentable {
    let title: String
    let identifier: String
    var selected: Bool?
    let duration: TimeInterval
    var onHold: (() -> Void)?
    var onRemove: (() -> Void)?
    var onPress: ((Bool) -> Void)?
    let activate: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(title: String, identifier: String, selected: Bool? = nil, duration: TimeInterval,
         onHold: (() -> Void)? = nil, onRemove: (() -> Void)? = nil,
         onPress: ((Bool) -> Void)? = nil, activate: @escaping () -> Void) {
        self.title = title
        self.identifier = identifier
        self.selected = selected
        self.duration = duration
        self.onHold = onHold
        self.onRemove = onRemove
        self.onPress = onPress
        self.activate = activate
    }

    final class Control: NSButton {
        var onPress: ((Bool) -> Void)?
        var activate: (() -> Void)?
        var duration: TimeInterval = 0.8
        var onHold: (() -> Void)?
        var onRemove: (() -> Void)?
        private var origin: NSPoint = .zero
        private var pending: Timer?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onHold != nil || super.acceptsFirstMouse(for: event) }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard isEnabled, onRemove != nil else { return super.menu(for: event) }
            let menu = NSMenu()
            menu.addItem(withTitle: L10n.text("移除"), action: #selector(removeSource), keyEquivalent: "").target = self
            return menu
        }

        @objc private func removeSource() {
            if isEnabled { onRemove?() }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            cancelPress()
            origin = event.locationInWindow
            onPress?(true)
            let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Track the accepted mouse-down until a matching window event
                    // cancels it. Global cursor/button state can belong to another device.
                    guard let self, self.window?.isKeyWindow == true else { return }
                    if let onHold = self.onHold {
                        // Consume the mouse-up after entering edit mode.
                        self.cancelPress()
                        if self.isEnabled { onHold() }
                    } else {
                        self.commitPress()
                    }
                }
            }
            pending = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            if !containsPointer(point) || (onHold != nil && hypot(point.x - origin.x, point.y - origin.y) > 8) { cancelPress() }
        }

        override func mouseUp(with event: NSEvent) {
            if containsPointer(event.locationInWindow) { commitPress() }
            else { cancelPress() }
        }

        private func containsPointer(_ point: NSPoint) -> Bool {
            bounds.contains(convert(point, from: nil))
        }

        private func commitPress() {
            guard pending != nil else { return }
            cancelPress()
            if isEnabled { sendAction(action, to: target) }
        }

        @objc func cancelPress() {
            guard let timer = pending else { return }
            pending = nil
            timer.invalidate()
            onPress?(false)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let window {
                NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            }
            cancelPress()
            super.viewWillMove(toWindow: newWindow)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                                       name: NSWindow.didResignKeyNotification, object: newWindow)
            }
        }

        @objc private func windowResignedKey(_ note: Notification) { cancelPress() }
        @objc func performActivation(_ sender: Any?) { if isEnabled { activate?() } }
    }

    func makeNSView(context: Context) -> Control {
        let button = Control()
        button.title = ""
        button.isBordered = false
        button.focusRingType = .exterior
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(Control.performActivation(_:))
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Control, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 44, height: 44))
    }

    func updateNSView(_ button: Control, context: Context) {
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        button.duration = duration
        button.onHold = onHold
        button.onRemove = onRemove
        if let selected { button.setAccessibilitySelected(selected) }
        if onRemove != nil {
            button.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: L10n.text("移除")) { [weak button] in
                guard let button, button.isEnabled, let remove = button.onRemove else { return false }
                remove()
                return true
            }])
        }
        button.onPress = onPress
        button.activate = activate
        if !enabled { button.cancelPress() }
    }

    static func dismantleNSView(_ button: Control, coordinator: Void) {
        button.onPress = nil
        button.cancelPress()
    }
}
