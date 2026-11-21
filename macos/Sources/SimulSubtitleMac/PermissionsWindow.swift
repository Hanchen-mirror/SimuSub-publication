import SwiftUI

/// Embedded in subtitle settings. Checking/opening settings never resets TCC.
struct SubtitlePermissionTools: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: CapturePermissionCenter
    @State private var confirmRestart = false

    private var busy: Bool { permissions.isRequesting || permissions.isRepairing }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 13) {
            Text(L10n.text("权限")).font(.headline)
            HStack(spacing: 14) {
                Button { Task { await permissions.requestScreenSettings(manageGranted: true) } } label: {
                    Label(L10n.text("屏幕与系统音频录制"), systemImage: "display")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(ThemeActionButtonStyle()).disabled(model.isBusy || busy)
                    .accessibilityIdentifier("settings.permissions.screen")
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                } label: {
                    Label(L10n.text("麦克风"), systemImage: "mic")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(ThemeActionButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("settings.permissions.microphone")
            }
            if !permissions.screenAccessError.isEmpty {
                HStack {
                    icon("wrench.and.screwdriver", title: "检查并修复音频权限", identifier: "settings.permissions.repair") { permissions.repairScreenFromUI() }
                    icon("door.left.hand.open", title: "打开系统录制权限设置", identifier: "settings.permissions.open") { permissions.openSettings() }
                }.disabled(model.isBusy || busy)
            }
            if !permissions.notice.isEmpty {
                Text(L10n.text(permissions.notice)).font(.callout).textSelection(.enabled)
            }
            if !permissions.screenAccessError.isEmpty {
            DisclosureGroup(L10n.text("仍然无法采集？")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("系统要求重新打开时，请先导出字幕。只有旧记录失效时才需要重置本应用授权，其他应用不受影响。"))
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    HStack {
                        Button(L10n.text("重新打开应用")) { confirmRestart = true }
                        Button(L10n.text("重置本应用旧授权…")) { permissions.needsResetConfirmation = true }
                    }.disabled(model.isBusy || busy)
                    if !permissions.screenAccessError.isEmpty {
                        Text(L10n.text(permissions.screenAccessError)).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
                    }
                }.padding(.top, 9)
            }.font(.caption)
            }
        }
        .designPanel()
        .onAppear { permissions.refresh() }
        .confirmationDialog(L10n.text("重置本应用的音频授权并重新打开？"), isPresented: $permissions.needsResetConfirmation) {
            Button(L10n.text("重置本应用授权并重新打开"), role: .destructive) { permissions.resetScreenFromUI() }
                .disabled(model.isBusy)
            Button(L10n.text("仅重新打开应用")) { permissions.restartApplication() }.disabled(model.isBusy)
        } message: {
            Text(L10n.text("请先导出需要保存的字幕。只清除 SimuSub 的应用音频旧授权；重新打开后需要你重新允许系统弹窗。"))
        }
        .confirmationDialog(L10n.text("重新打开应用？"), isPresented: $confirmRestart) {
            Button(L10n.text("重新打开")) { permissions.restartApplication() }
        } message: { Text(L10n.text("重新打开会结束当前会话，请先导出需要保存的字幕。")) }
    }

    private func icon(_ symbol: String, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).interfaceFont(size: 17)
                .frame(width: 38, height: 38)
                .background(ThemeColor.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title)).accessibilityIdentifier(identifier)
    }
}
