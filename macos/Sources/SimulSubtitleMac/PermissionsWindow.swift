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
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("应用音频").font(.headline)
                    Label(permissions.screenGranted ? "已允许" : "未允许",
                          systemImage: permissions.screenGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(permissions.screenGranted ? Color.green : Color.orange)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                icon("wrench.and.screwdriver", title: "检查并修复音频权限", identifier: "settings.permissions.repair") {
                    permissions.repairScreenFromUI()
                }.disabled(model.isBusy || busy)
                icon("door.left.hand.open", title: "打开系统录制权限设置", identifier: "settings.permissions.open") {
                    permissions.openSettings()
                }.disabled(busy)
            }
            if !permissions.notice.isEmpty {
                Text(permissions.notice).font(.callout).textSelection(.enabled)
            }
            DisclosureGroup("仍然无法采集？") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("系统要求重新打开时，请先导出字幕。只有旧记录失效时才需要重置本应用授权，其他应用不受影响。")
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    HStack {
                        Button("重新打开应用") { confirmRestart = true }
                        Button("重置本应用旧授权…") { permissions.needsResetConfirmation = true }
                    }.disabled(model.isBusy || busy)
                    if !permissions.screenAccessError.isEmpty {
                        Text(permissions.screenAccessError).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
                    }
                }.padding(.top, 9)
            }.font(.caption)
        }
        .designPanel()
        .onAppear { permissions.refresh() }
        .confirmationDialog("重置本应用的音频授权并重新打开？", isPresented: $permissions.needsResetConfirmation) {
            Button("重置本应用授权并重新打开", role: .destructive) { permissions.resetScreenFromUI() }
                .disabled(model.isBusy)
            Button("仅重新打开应用") { permissions.restartApplication() }.disabled(model.isBusy)
        } message: {
            Text("请先导出需要保存的字幕。只清除 SimuSub 的应用音频旧授权；重新打开后需要你重新允许系统弹窗。")
        }
        .confirmationDialog("重新打开应用？", isPresented: $confirmRestart) {
            Button("重新打开") { permissions.restartApplication() }
        } message: { Text("重新打开会结束当前会话，请先导出需要保存的字幕。") }
    }

    private func icon(_ symbol: String, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17))
                .frame(width: 38, height: 38)
                .background(ThemeColor.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}
