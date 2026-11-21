import AppKit
import SwiftUI

struct LaunchContent: View {
    @ObservedObject var model: AppModel
    @State private var initialDestination: WorkspaceDestination?

    var body: some View {
        if CommandLine.arguments.contains("--onboarding-check") ||
            (!model.onboardingCompleted && !AppLaunchOptions.isDiagnostic && !model.subtitleNeedsPermission
             && !CommandLine.arguments.contains("--show-permissions") && !CommandLine.arguments.contains("--show-subtitle-settings")) {
            OnboardingHost(model: model) { initialDestination = $0 }
        } else {
            MainWindow(initialDestination: initialDestination)
        }
    }
}

private struct OnboardingHost: View {
    @StateObject private var setup: OnboardingState
    @EnvironmentObject private var appearance: HomeAppearance
    let navigate: (WorkspaceDestination) -> Void

    init(model: AppModel, navigate: @escaping (WorkspaceDestination) -> Void) {
        _setup = StateObject(wrappedValue: OnboardingState(model: model))
        self.navigate = navigate
    }

    var body: some View {
        OnboardingWindow(setup: setup, navigate: navigate)
            .task {
                if await OnboardingChecks.runIfRequested(model: setup.model, appearance: appearance) { return }
                setup.refreshPermission()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                setup.refreshPermission()
            }
    }
}

struct OnboardingWindow: View {
    @ObservedObject var setup: OnboardingState
    let navigate: (WorkspaceDestination) -> Void
    @Environment(\.appThemeID) private var themeID

    var body: some View {
        let _ = themeID
        GeometryReader { geometry in
            let narrow = geometry.size.width < 840
            let short = geometry.size.height < 620
            HStack(spacing: 0) {
                sidebar.frame(width: narrow ? 154 : 204)
                    .background(ThemeColor.sidebar.ignoresSafeArea())
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: short ? 14 : 22) {
                            Text(L10n.text("开启权限")).font(.system(size: 30, weight: .semibold))
                            Text(L10n.text("实时字幕需要读取 Mac 正在播放的声音。"))
                                .font(.system(size: 15)).foregroundStyle(ThemeColor.muted)
                            permissionCard.padding(.top, short ? 4 : 14)
                        }.padding(.top, short ? 28 : 72).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().background(ThemeColor.line)
                    ViewThatFits(in: .horizontal) {
                        HStack { laterButton; Spacer(minLength: 12); continueButton }
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .trailing, spacing: 8) { laterButton; continueButton }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.padding(.top, short ? 12 : 23)
                }.padding(.horizontal, narrow ? 20 : 44).padding(.bottom, short ? 16 : 30)
            }
        }.background(ThemeColor.background.ignoresSafeArea()).appTheme()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 35, height: 35)
                        .clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                }
                Text("SimuSub").font(.system(size: 22, weight: .semibold))
            }.padding(.horizontal, 16).padding(.bottom, 44)
            HStack(spacing: 12) {
                Image(systemName: "lock").foregroundStyle(ThemeColor.primary)
                Text(L10n.text("开启权限")).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(12).frame(minHeight: 44)
                .background(ThemeColor.selection, in: RoundedRectangle(cornerRadius: 11)).padding(.horizontal, 11)
            Spacer(minLength: 14)
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("主题")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                ThemeColorChoices(compact: true)
            }.padding(.horizontal, 16).padding(.bottom, 25)
        }.padding(.top, 38)
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "display").font(.system(size: 19))
                    .foregroundStyle(ThemeColor.primary).frame(width: 40, height: 40)
                    .background(ThemeColor.selection, in: RoundedRectangle(cornerRadius: 11)).accessibilityHidden(true)
                Text(L10n.text("屏幕与系统音频录制")).font(.system(size: 19, weight: .semibold))
                Spacer(minLength: 3)
                Text(L10n.text(setup.permissions.screenGranted ? "✓ 已开启" : "待开启"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.primary)
                    .padding(.horizontal, 12).padding(.vertical, 6).background(ThemeColor.soft, in: Capsule())
                    .fixedSize()
            }
            Divider().background(ThemeColor.line)
            Text(L10n.text("系统设置  ›  隐私与安全性  ›  屏幕与系统音频录制"))
                .font(.system(size: 13)).foregroundStyle(ThemeColor.muted)
            if setup.permissions.screenGranted {
                Label(L10n.text("已允许 SimuSub 获取系统声音。"), systemImage: "checkmark")
                    .font(.system(size: 14)).foregroundStyle(ThemeColor.ink)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { settingsInstruction.fixedSize(); Spacer(minLength: 0); settingsButton.fixedSize() }
                    VStack(alignment: .leading, spacing: 12) { settingsInstruction; settingsButton }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ThemeColor.line))
    }

    private var settingsInstruction: some View {
        Text(L10n.text("打开 %@ 的开关，返回后会自动检查权限。").replacingOccurrences(of: "%@", with: CapturePermissionCenter.applicationName))
            .font(.system(size: 14))
    }

    private var settingsButton: some View {
        Button { setup.permissions.openSetupSettings() } label: {
            Label(L10n.text("打开系统设置"), systemImage: "arrow.up.right")
        }.buttonStyle(ThemeActionButtonStyle(prominent: true)).accessibilityIdentifier("onboarding.openSettings")
    }

    @ViewBuilder private var laterButton: some View {
        if !setup.permissions.screenGranted {
            Button(L10n.text("稍后设置，先剪辑本地视频")) { setup.finish(at: .clips, navigate: navigate) }
                .buttonStyle(.plain).foregroundStyle(ThemeColor.primary)
                .accessibilityIdentifier("onboarding.editInstead")
        }
    }

    private var continueButton: some View {
        Button { setup.finish(at: .subtitle, navigate: navigate) } label: {
            HStack(spacing: 14) { Text(L10n.text("进入字幕同传")); Image(systemName: "arrow.right") }
                .font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).frame(minHeight: 38)
                .foregroundStyle(setup.permissions.screenGranted ? ThemeColor.background : ThemeColor.muted)
                .background(setup.permissions.screenGranted ? ThemeColor.primary : ThemeColor.control,
                            in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(!setup.permissions.screenGranted)
            .accessibilityIdentifier("onboarding.enterSubtitles")
    }
}
