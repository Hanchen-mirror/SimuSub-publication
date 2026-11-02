import SwiftUI

 enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, subtitle, recording, clips, services, settings
    var id: String { rawValue }
    var title: String { switch self { case .home: "工作空间"; case .subtitle: "日中同传"; case .recording: "直播录制"; case .clips: "剪辑工作台"; case .services: "模型与服务"; case .settings: "设置" } }
    var symbol: String { switch self { case .home: "square.grid.2x2"; case .subtitle: "captions.bubble"; case .recording: "record.circle"; case .clips: "scissors"; case .services: "cpu"; case .settings: "gearshape" } }
}
struct WorkspaceSidebar: View {
    var selected: WorkspaceDestination
    var onSelect: (WorkspaceDestination) -> Void
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var guide = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble").font(.system(size: 19)).foregroundStyle(ThemeColor.surface)
                    .frame(width: 34, height: 34).background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 11))
                Text("SimuSub").font(.system(size: 22, weight: .semibold, design: .rounded))
            }.padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 30)
            ForEach(WorkspaceDestination.allCases.filter { $0 != .settings }) { item in
                entry(item.title, symbol: item.symbol, selected: selected == item) { onSelect(item) }
                    .accessibilityIdentifier("nav." + item.rawValue)
            }
            Spacer()
            entry(appearance.isDark ? "浅色模式" : "深色模式", symbol: appearance.isDark ? "sun.max" : "moon", action: appearance.toggleTheme)
            entry("使用帮助", symbol: "questionmark.circle") { guide = true }
            entry("设置", symbol: "gearshape", selected: selected == .settings) { onSelect(.settings) }.accessibilityIdentifier("nav.settings")
        }.padding(14).background(ThemeColor.sidebar.ignoresSafeArea(.container, edges: .top))
            .overlay(alignment: .trailing) { ThemeColor.line.frame(width: 1) }
            .sheet(isPresented: $guide) { SimuSubGuide().appTheme() }
    }
    private func entry(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 44)
                .foregroundStyle(selected ? ThemeColor.primaryInk : ThemeColor.muted)
                .background(selected ? ThemeColor.surface : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct WorkspaceHome: View {
    var onSelect: (WorkspaceDestination) -> Void
    var onClips: () -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("工作空间").font(.system(size: 28, weight: .semibold))
                HStack(spacing: 18) {
                    mode(.subtitle, detail: "日语 → 中文 · 实时字幕") { onSelect(.subtitle) }
                    mode(.recording, detail: "关注主播 · 监控与录制") { onSelect(.recording) }
                    mode(.clips, detail: "自由选段 · 字幕编辑与导出", action: onClips)
                }
                HStack {
                    Text("关注的主播").font(.title3.weight(.semibold))
                    Spacer(); Button("搜索与管理") { onSelect(.recording) }
                }
                HomeDashboard(onClips: { _ in onClips() }, embedded: true)
                HStack {
                    Image(systemName: model.readinessIssues.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                    Text(model.isDownloadingModels ? model.downloadStatus : model.readinessIssues.isEmpty ? "本地引擎已就绪" : "可在模型与服务中准备引擎").font(.caption)
                    Spacer()
                    Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.28")).font(.caption)
                }.foregroundStyle(ThemeColor.muted)
            }.padding(30)
        }.background {
            ThemeColor.background
            if let image = appearance.backgroundImage { Image(nsImage: image).resizable().scaledToFill().opacity(0.12).clipped().allowsHitTesting(false) }
        }
    }
    private func mode(_ destination: WorkspaceDestination, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: destination.symbol).font(.system(size: 25, weight: .light)).foregroundStyle(ThemeColor.primary)
                    .frame(width: 50, height: 50).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 16))
                Text(destination.title).font(.system(size: 19, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                HStack { Text("进入"); Spacer(); Image(systemName: "arrow.up.right") }.font(.callout).foregroundStyle(ThemeColor.primary)
            }.themeCard()
        }.buttonStyle(.plain).accessibilityIdentifier("module." + destination.rawValue)
    }
}

@MainActor
final class ClipWindowController: ObservableObject {
    private(set) var window: NSWindow?
    private var lastCreatorID: UUID?
    func show(creatorID: UUID?, tool: ClipWorkspaceTool, model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore, clips: ClipStore) {
        if let window, creatorID == lastCreatorID {
            window.makeKeyAndOrderFront(nil)
            return
        }
        lastCreatorID = creatorID
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "SimuSub · 剪辑工作台"; w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.backgroundColor = ThemePalette.color(appearance.theme, dark: appearance.isDark, role: .background)
            w.identifier = NSUserInterfaceItemIdentifier("clips.window")
            w.contentMinSize = NSSize(width: 1180, height: 720)
            w.center(); window = w
        }
        window?.contentView = NSHostingView(rootView: ClipWorkspace(creatorID: creatorID, initialTool: tool) { [weak self] in
            self?.window?.orderOut(nil)
            NSApp.windows.first { $0.identifier?.rawValue != "clips.window" && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }.environmentObject(model).environmentObject(model.permissions).environmentObject(appearance).environmentObject(monitor).environmentObject(clips).appTheme().environmentObject(appearance))
        window?.makeKeyAndOrderFront(nil)
    }
}
