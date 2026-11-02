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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble").font(.system(size: 19)).foregroundStyle(ThemeColor.surface)
                    .frame(width: 34, height: 34).background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 11))
                Text("SimuSub").font(.system(size: 20, weight: .bold))
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 30)
            ForEach(WorkspaceDestination.allCases.filter { $0 != .settings }) { item in
                entry(item.title, symbol: item.symbol, selected: selected == item) { onSelect(item) }
                    .accessibilityIdentifier("nav." + item.rawValue)
            }
            Spacer()
            entry(appearance.isDark ? "浅色模式" : "深色模式", symbol: appearance.isDark ? "sun.max" : "moon", action: appearance.toggleTheme)
            entry("使用帮助", symbol: "questionmark.circle") { guide = true }
            entry("设置", symbol: "gearshape", selected: selected == .settings) { onSelect(.settings) }.accessibilityIdentifier("nav.settings")
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 20).background(ThemeColor.sidebar.ignoresSafeArea(.container, edges: .top))
            .overlay(alignment: .trailing) { ThemeColor.line.frame(width: 1) }
            .sheet(isPresented: $guide) { SimuSubGuide().appTheme() }
    }
    private func entry(_ title: String, symbol: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: 46)
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
    @EnvironmentObject private var clips: ClipStore
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DesignPageHeading(title: "工作空间") {
                    Label(model.readinessIssues.isEmpty ? "本地引擎已就绪" : "准备引擎", systemImage: model.readinessIssues.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                        .font(.system(size: 11)).foregroundStyle(ThemeColor.primaryInk).padding(9).background(ThemeColor.soft, in: Capsule())
                        .onTapGesture { onSelect(.services) }
                }
                HStack(spacing: 16) {
                    mode(.subtitle, detail: "日语 → 中文字幕", actionTitle: "开始同传") { onSelect(.subtitle) }
                    mode(.recording, detail: "关注主播 · 监控与录制", actionTitle: "选择直播") { onSelect(.recording) }
                    mode(.clips, detail: "选段 · 字幕 · 导出", actionTitle: "导入视频", action: onClips)
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("关注的直播").font(.system(size: 15, weight: .semibold)); Spacer(); Button { onSelect(.recording) } label: { Label("添加主播", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk) }
                    CreatorListV23(onClips: { _ in onClips() }, limit: 4)
                }.designPanel()
                if !clips.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("最近项目").font(.system(size: 15, weight: .semibold))
                        ForEach(clips.projects.prefix(3)) { project in
                            HStack { Image(systemName: "film").foregroundStyle(ThemeColor.primary).frame(width: 38, height: 38).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) { Text(project.name); Text("\(project.ranges.count) 个选段 · " + ClipTime.label(project.media.duration)).font(.caption).foregroundStyle(ThemeColor.muted) }
                                Spacer(); Button("继续剪辑") { clips.selectedID = project.id; onClips() }
                            }
                        }
                    }.designPanel()
                }
            }.padding(.horizontal, 32).padding(.vertical, 28)
        }.background {
            ThemeColor.background
            if let image = appearance.backgroundImage { Image(nsImage: image).resizable().scaledToFill().opacity(0.12).clipped().allowsHitTesting(false) }
        }
    }
    private func mode(_ destination: WorkspaceDestination, detail: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                DesignModeArt(destination: destination)
                VStack(alignment: .leading, spacing: 5) {
                    Text(destination.title).font(.system(size: 17, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
                }
                HStack { Text(actionTitle); Spacer(); Image(systemName: "arrow.right") }.font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.primaryInk).padding(.top, 4)
            }.padding(.horizontal, 20).padding(.vertical, 18).frame(maxWidth: .infinity)
                .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(ThemeColor.line))
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
