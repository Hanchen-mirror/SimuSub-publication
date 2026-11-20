import SwiftUI

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home, subtitle, recording, clips, services, settings
    var id: String { rawValue }
    var title: String { switch self { case .home: "工作空间"; case .subtitle: "字幕同传"; case .recording: "直播录制"; case .clips: "剪辑工作台"; case .services: "模型与服务"; case .settings: "设置" } }
}
struct WorkspaceSidebar: View {
    @Namespace private var selection
    var selected: WorkspaceDestination
    var mode: WorkspaceNavigation = .sidebar
    var short = false
    var onSelect: (WorkspaceDestination) -> Void
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let _ = appThemeID
        let layout = mode == .top ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        layout {
            if mode == .sidebar {
                HStack(spacing: 8) {
                    if !short { WorkspaceBrandMark().frame(width: 36, height: 36) }
                    wordmark(size: 21)
                }.padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, short ? 2 : 26)
            } else if mode == .rail {
                VStack(spacing: 4) {
                    if !short { WorkspaceBrandMark().frame(width: 32, height: 32) }
                    wordmark(size: 12).fixedSize(horizontal: true, vertical: false)
                }.frame(maxWidth: .infinity).padding(.bottom, short ? 2 : 16)
            } else {
                wordmark(size: 13).fixedSize().padding(.horizontal, 4)
            }
            ForEach(WorkspaceDestination.allCases.filter { $0 != .settings && $0 != .home }) { item in
                entry(item)
            }
            if mode != .top { Spacer(minLength: 0) }
            entry(.settings)
        }.padding(.horizontal, mode == .sidebar ? 16 : 8)
            .padding(.vertical, mode == .top || short ? 6 : 14)
            .background(ThemeColor.sidebar.ignoresSafeArea(.container, edges: .top))
            .accessibilityIdentifier("nav.layout." + mode.rawValue)
    }

    private func wordmark(size: CGFloat) -> some View {
        Text(verbatim: "SimuSub").font(.system(size: size, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(ThemeColor.muted)
            .modifier(TextSheen(active: true))
            .accessibilityIdentifier("nav.brand")
    }

    private func entry(_ item: WorkspaceDestination) -> some View {
        Button { onSelect(item) } label: {
            HStack(spacing: 8) {
                WorkspaceNavigationGlyph(item: item, selected: selected == item)
                if mode == .sidebar { Text(L10n.text(item.title)).lineLimit(1) }
            }.font(.system(size: 13, weight: selected == item ? .semibold : .regular))
                .padding(.horizontal, mode == .sidebar ? 12 : 0)
                .frame(maxWidth: .infinity, alignment: mode == .sidebar ? .leading : .center)
                .frame(height: mode == .top || short ? 36 : 46)
                .foregroundStyle(selected == item ? ThemeColor.primaryInk : ThemeColor.muted)
                .background {
                    if selected == item {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ThemeColor.selection)
                            .matchedGeometryEffect(id: "workspace.selection", in: selection)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text(item.title)).accessibilityLabel(L10n.text(item.title))
            .accessibilityAddTraits(selected == item ? .isSelected : [])
            .accessibilityIdentifier("nav." + item.rawValue)
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
                    Label(L10n.text(model.readinessIssues.isEmpty ? "本地引擎已就绪" : "准备引擎"), systemImage: model.readinessIssues.isEmpty ? "checkmark.circle" : "arrow.down.circle")
                        .interfaceFont(size: 11).foregroundStyle(ThemeColor.primaryInk).padding(9).background(ThemeColor.soft, in: Capsule())
                        .onTapGesture { onSelect(.services) }
                }
                HStack(spacing: 16) {
                    mode(.subtitle, detail: "日语 → 中文字幕", actionTitle: "开始同传") { onSelect(.subtitle) }
                    mode(.recording, detail: "关注主播 · 监控与录制", actionTitle: "选择直播") { onSelect(.recording) }
                    mode(.clips, detail: "选段 · 字幕 · 导出", actionTitle: "打开视频", action: onClips)
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text(L10n.text("关注的直播")).interfaceFont(size: 15, weight: .semibold); Spacer(); Button { onSelect(.recording) } label: { Label(L10n.text("添加主播"), systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk) }
                    CreatorListV23(onClips: { _ in onClips() }, limit: 4)
                }.designPanel()
                if !clips.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.text("最近项目")).interfaceFont(size: 15, weight: .semibold)
                        ForEach(clips.projects.prefix(3)) { project in
                            HStack { Image(systemName: "film").foregroundStyle(ThemeColor.primary).frame(width: 38, height: 38).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) { Text(project.name); Text(L10n.text("\(project.ranges.count) 个选段 · " + ClipTime.label(project.media.duration))).font(.caption).foregroundStyle(ThemeColor.muted) }
                                Spacer(); Button(L10n.text("继续剪辑")) { clips.selectedID = project.id; onClips() }
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
                    Text(L10n.text(destination.title)).interfaceFont(size: 17, weight: .semibold)
                    Text(L10n.text(detail)).interfaceFont(size: 11).foregroundStyle(ThemeColor.muted)
                }
                HStack { Text(L10n.text(actionTitle)); Spacer(); Image(systemName: "arrow.right") }.interfaceFont(size: 12, weight: .medium).foregroundStyle(ThemeColor.primaryInk).padding(.top, 4)
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
            w.contentMinSize = NSSize(width: 640, height: 420)
            w.center(); window = w
        }
        window?.contentView = NSHostingView(rootView: ZoomedWorkspace {
            ClipWorkspace(creatorID: creatorID, initialTool: tool) { [weak self] in
                self?.window?.orderOut(nil)
                NSApp.windows.first { $0.identifier?.rawValue != "clips.window" && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
        }.environmentObject(model).environmentObject(model.permissions).environmentObject(appearance).environmentObject(monitor).environmentObject(clips).appTheme().environmentObject(appearance))
        window?.makeKeyAndOrderFront(nil)
    }
}
