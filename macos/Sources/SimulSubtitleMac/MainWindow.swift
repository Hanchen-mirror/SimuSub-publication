import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: CapturePermissionCenter
    @EnvironmentObject private var monitor: LiveMonitorStore
    @EnvironmentObject private var clips: ClipStore
    @State private var destination: WorkspaceDestination
    private let initialDestination: WorkspaceDestination?

    init(initialDestination: WorkspaceDestination? = nil) {
        self.initialDestination = initialDestination
        _destination = State(initialValue: initialDestination ?? .subtitle)
    }
    @AppStorage("workspace.sidebarCollapsed.v150") private var sidebarCollapsed = false
    @State private var showingHomeSettings = false
    @State private var settingsInitialCategory: String?
    @State private var clipCreatorID: UUID?
    @State private var clipTool: ClipWorkspaceTool = .edit
    @EnvironmentObject private var subtitles: SubtitlePanelController
    @EnvironmentObject private var appearance: HomeAppearance

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var navigationAnimation: Animation? {
        appearance.reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.22)
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ZoomedWorkspace {
            GeometryReader { geometry in
                let mode = WorkspaceNavigation(width: geometry.size.width)
                let shell = mode == .top ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
                shell {
                    SidebarRevealLayout(top: mode == .top, fraction: sidebarCollapsed ? 0 : 1) {
                        WorkspaceSidebar(selected: destination, mode: mode, short: geometry.size.height < 320) { item in
                            navigate(to: item)
                        }.frame(width: mode.width)
                            .background(ThemeColor.sidebar)
                            .opacity(sidebarCollapsed ? 0 : 1)
                    }
                    .clipped()
                    .allowsHitTesting(!sidebarCollapsed)
                    .accessibilityHidden(sidebarCollapsed)
                    .disabled(sidebarCollapsed)
                    ZStack {
                        if model.section != .live { auxiliaryWorkspace }
                        else {
                            workspacePage
                                .id(destination)
                                .transition(appearance.reduceMotion || systemReduceMotion ? .identity :
                                    .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        sidebarToggle(mode)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.background.ignoresSafeArea(.container, edges: .top))
        .appTheme()
        .background(HomeWindowBridge(controller: subtitles))
        .onChange(of: destination) { value in if value != .clips { appearance.lastPage = value.rawValue } }
        .onChange(of: model.isSubtitleOnly) { _ in subtitles.synchronize() }
        .onChange(of: model.subtitleNeedsPermission) { pending in if pending { destination = .subtitle } }
        .onChange(of: model.section) { section in
            if section == .permissions {
                model.isSubtitleOnly = false
                model.section = .live
                destination = .settings
            }
        }
        .sheet(isPresented: Binding(get: { model.isChoosingApplication && !model.isSubtitleOnly }, set: { if !$0 && !model.isSubtitleOnly { model.isChoosingApplication = false } }),
               onDismiss: model.applicationPickerDidDismiss) {
            CaptureApplicationPicker().environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.subtitlePreparationBytes != nil && !model.isSubtitleOnly },
                                    set: { if !$0 && !model.isSubtitleOnly { model.cancelSubtitlePreparation() } })) {
            SubtitlePreparationSheet()
        }
        .sheet(isPresented: $showingHomeSettings) {
            ZoomedWorkspace {
                SettingsWindow(recording: destination == .recording, onClose: { showingHomeSettings = false })
            }.frame(width: 640, height: 600)
        }
        .alert(L10n.text("需要处理"), isPresented: Binding(get: { model.errorMessage != nil && !model.isSubtitleOnly }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.text("知道了")) { model.errorMessage = nil }
            Button(L10n.text(model.errorSection.rawValue)) {
                model.errorMessage = nil
                if model.errorSection == .live { destination = .subtitle }
                model.section = model.errorSection
                model.isSubtitleOnly = false
            }
        } message: { Text(model.errorMessage ?? "") }
        .task {
            subtitles.configure(model: model, appearance: appearance, monitor: monitor)
            if await OriginalModePreview.runIfRequested(appearance: appearance) { return }
            if await Release148Checks.runIfRequested(appearance: appearance, subtitles: subtitles, monitor: monitor, clips: clips) { return }
            if await Release146Checks.runIfRequested(appearance: appearance, subtitles: subtitles) { return }
            if await Release145Checks.runIfRequested(appearance: appearance, subtitles: subtitles) { return }
            if await ResponsiveLayoutChecks.runIfRequested(model: model, appearance: appearance, monitor: monitor, clips: clips, subtitles: subtitles) { return }
            if await ModelLibraryChecks.runIfRequested(model: model, appearance: appearance, monitor: monitor, clips: clips) { return }
            if await Release141Checks.runIfRequested(model: model, appearance: appearance, monitor: monitor, subtitles: subtitles) { return }
            if await ThemeChecks.runIfRequested(model: model, appearance: appearance, monitor: monitor, clips: clips, subtitles: subtitles) { return }
            if CommandLine.arguments.contains("--clip-demo") { openClips(nil); return }
            if await ClipChecks.runIfRequested(model: model, appearance: appearance, monitor: monitor) { return }
            if CommandLine.arguments.contains("--live-monitor-check") {
                // Explicit network checks own their lifetime independently of the view.
                Task { @MainActor in _ = await LiveMonitorChecks.runIfRequested(monitor: monitor, appearance: appearance) }
                return
            }
            if await LiveMonitorChecks.runIfRequested(monitor: monitor, appearance: appearance) { return }
            if await SubtitlePanelChecks.runIfRequested(model: model, controller: subtitles, appearance: appearance) { return }
            if await SubtitleLayoutPreview.renderIfRequested(model: model, controller: subtitles) { return }
            if initialDestination == nil, !AppLaunchOptions.isDiagnostic, appearance.restorePage,
               let saved = WorkspaceDestination(rawValue: appearance.lastPage), saved != .clips { destination = saved == .home ? .subtitle : saved }
            // Diagnostic entry points never restore or mutate the user's page.
            if CommandLine.arguments.contains("--show-permissions") || CommandLine.arguments.contains("--show-subtitle-settings") {
                settingsInitialCategory = "权限"
                destination = .settings
                if CommandLine.arguments.contains("--request-audio-access") { permissions.requestScreenFromUI() }
            } else if model.subtitleNeedsPermission {
                destination = .subtitle
                model.resumeSubtitleAfterAuthorization(onLaunch: true)
            }
            if !AppLaunchOptions.isDiagnostic {
                model.refreshModels()
                monitor.refreshMissingProfiles()
                if monitor.creators.contains(where: \.monitoring) { monitor.startMonitoring() }
            }
            if await LiveCaptureChecks.runIfRequested(model: model) { return }
            await UISmokeChecks.runIfRequested(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !CommandLine.arguments.contains("--preview-subtitle-layout") {
                permissions.refresh()
                model.resumeSubtitleAfterAuthorization()
            }
        }
    }

    private func sidebarToggle(_ mode: WorkspaceNavigation) -> some View {
        Button {
            withAnimation(navigationAnimation) { sidebarCollapsed.toggle() }
        } label: {
            SidebarToggleGlyph(collapsed: sidebarCollapsed, top: mode == .top)
                .animation(navigationAnimation, value: sidebarCollapsed)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).controlSize(.small)
        .help(L10n.text(sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"))
        .accessibilityLabel(L10n.text(sidebarCollapsed ? "展开侧边栏" : "折叠侧边栏"))
        .accessibilityIdentifier("nav.toggleSidebar")
    }

    @ViewBuilder private var workspacePage: some View {
        switch destination {
        case .home:
            WorkspaceHome(onSelect: { navigate(to: $0) }, onClips: { navigate(to: .clips) })
        case .subtitle:
            SubtitleConfiguration(onServices: { navigate(to: .services) })
        case .recording:
            RecordingWorkspace(onSettings: { showingHomeSettings = true },
                               onClips: { navigate(to: .clips, creatorID: $0) })
        case .clips:
            ClipWorkspace(creatorID: clipCreatorID, initialTool: clipTool) { navigate(to: .subtitle) }
        case .services:
            AdvancedServiceSettings(clipJobActive: clips.isBusy)
        case .settings:
            SettingsWindow(initialCategory: settingsInitialCategory)
        }
    }

    private func navigate(to item: WorkspaceDestination, creatorID: UUID? = nil) {
        guard destination != item || model.section != .live ||
                (item == .clips && creatorID != clipCreatorID) else { return }
        withAnimation(navigationAnimation) {
            if item == .clips {
                openClips(creatorID)
            } else {
                model.section = .live
                destination = item
            }
        }
    }

    private func openClips(_ id: UUID?) {
        clipCreatorID = id
        model.section = .live
        destination = .clips
    }

    private func enterSubtitles() {
        model.section = .live
        model.isSubtitleOnly = true
    }

    private func returnHome() {
        model.section = .live
        model.isSubtitleOnly = false
    }

    // Permissions, service configuration and history remain auxiliary destinations.
    // The normal subtitle entry never renders the old capture console.
    private var auxiliaryWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: returnHome) { Image(systemName: "chevron.left") }
                    .help(L10n.text("返回首页")).accessibilityLabel(L10n.text("返回首页"))
                Text(L10n.text(model.section.rawValue)).font(.title3.bold())
                Spacer()
                Button(action: enterSubtitles) { Image(systemName: "captions.bubble") }
                    .help(L10n.text("返回同传字幕")).accessibilityLabel(L10n.text("返回同传字幕"))
            }.buttonStyle(.bordered).padding(24)
            Divider()
            Group {
                switch model.section {
                case .services: AdvancedServiceSettings(clipJobActive: clips.isBusy)
                case .permissions: SettingsWindow()
                case .history: captionPanel.padding(22)
                case .live: Color.clear.onAppear { enterSubtitles() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(ThemeColor.background)
    }

    private var captionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text(model.section == .history ? "当前字幕记录" : "实时字幕"), systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                Text(L10n.text("\(model.captions.count) 条")).font(.caption).foregroundStyle(ThemeColor.muted)
            }
            Divider()
            if model.captions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path").font(.system(size: 42, weight: .light)).foregroundStyle(ThemeColor.primary.opacity(0.7))
                    Text(L10n.text("还没有字幕")).font(.title3.bold())
                    Text(L10n.text(model.readinessIssues.isEmpty ? "选择正在播放直播的应用，然后开始同传。" : "请在模型与服务中配置识别和翻译。"))
                        .font(.callout).foregroundStyle(ThemeColor.muted).multilineTextAlignment(.center).frame(maxWidth: 310)
                    if !model.isDownloadingModels && !model.readinessIssues.isEmpty { Button(L10n.text("重新准备本地引擎")) { model.ensureLocalModels() }.buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(model.captions) { caption in
                                CaptionRow(caption: caption).id(caption.id)
                            }
                        }
                    }
                    .onChange(of: model.captions.count) { _ in
                        if let last = model.captions.last { reader.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ThemeColor.line))
    }


}

struct CaptionRow: View {
    @EnvironmentObject private var model: AppModel
    let caption: Caption
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 9) {
            Text(String(format: "%02d:%02d", Int(caption.start) / 60, Int(caption.start) % 60)).font(.caption.monospacedDigit()).foregroundStyle(ThemeColor.muted)
            Text(caption.original).font(.system(size: 17, weight: .medium)).textSelection(.enabled)
            if let translation = SubtitleDocument.completedTranslation(SubtitleDocument.liveCaption(caption)) {
                Text(translation).font(.system(size: 15)).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
            }
            if !caption.originalRevisions.isEmpty || caption.pendingOriginal != nil || !caption.recognitionNotice.isEmpty {
                DisclosureGroup(L10n.text("原文修订记录（\(caption.originalRevisions.count) 版）")) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !caption.recognitionNotice.isEmpty {
                            Text(L10n.text(caption.recognitionNotice)).foregroundStyle(.secondary)
                        }
                        ForEach(Array(caption.originalRevisions.enumerated()), id: \.offset) { item in
                            Text("\(item.offset + 1). \(item.element)").textSelection(.enabled)
                        }
                        if let candidate = caption.pendingOriginal {
                            Text(L10n.text("新识别候选：") + (candidate.isEmpty ? "（空结果）" : candidate)).textSelection(.enabled)
                            if caption.recognitionNeedsReview {
                                HStack {
                                    Button(L10n.text("保留原文并翻译")) { Task { await model.resolveRecognition(caption.id, useCandidate: false) } }
                                    if !candidate.isEmpty { Button(L10n.text("采用新识别并翻译")) { Task { await model.resolveRecognition(caption.id, useCandidate: true) } } }
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }
            if caption.translated.hasPrefix("翻译失败：") || caption.translated.hasPrefix("译文未完成") ||
                SubtitleDocument.isTranslationArtifact(caption.translated, original: caption.original) {
                Button(L10n.text("重试翻译")) { Task { await model.retryTranslation(caption.id) } }
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 10))
    }
}


// Keep the navigation at its natural size and slide it through an animated clip.
// The destination stays mounted as the space available to it changes.
private struct SidebarRevealLayout: Layout {
    var top: Bool
    var fraction: CGFloat
    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let sidebar = subviews.first else { return .zero }
        let size = sidebar.sizeThatFits(proposal)
        return CGSize(width: top ? size.width : size.width * fraction,
                      height: top ? size.height * fraction : size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sidebar = subviews.first else { return }
        let natural = sidebar.sizeThatFits(proposal)
        let size = top ? CGSize(width: bounds.width, height: natural.height)
                       : CGSize(width: natural.width, height: bounds.height)
        sidebar.place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing,
                      proposal: ProposedViewSize(size))
    }
}

private struct SidebarToggleGlyph: View {
    let collapsed: Bool
    let top: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(lineWidth: 1.25)
            RoundedRectangle(cornerRadius: 0.8)
                .frame(width: top ? 12 : (collapsed ? 0 : 4),
                       height: top ? (collapsed ? 0 : 3) : 9)
                .offset(x: 2, y: 2)
            Image(systemName: "chevron.right")
                .font(.system(size: 6, weight: .bold))
                .rotationEffect(.degrees(top ? (collapsed ? 90 : -90) : (collapsed ? 0 : 180)))
                .frame(width: 8, height: 8)
                .offset(x: top || collapsed ? 4 : 6, y: top && !collapsed ? 4 : 2.5)
        }
        .frame(width: 16, height: 13)
        .foregroundStyle(ThemeColor.primaryInk)
        .accessibilityHidden(true)
    }
}
