import SwiftUI

struct CreatorRemovalConfirmation: View {
    let name: String
    let onCancel: () -> Void
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("移除 \(name)？")).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text(L10n.text("已保存的视频会保留")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(L10n.text("取消")).frame(maxWidth: .infinity).frame(height: 32)
                        .background(ThemeColor.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("home.remove.cancel")
                Button(role: .destructive, action: onRemove) {
                    Text(L10n.text("移除")).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 32)
                        .background(Color(red: 0.66, green: 0.17, blue: 0.21), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityIdentifier("home.remove.confirm")
            }.font(.system(size: 13, weight: .medium)).padding(.top, 5)

        }.padding(24).frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .background(ThemeColor.surface)
            .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("移除主播确认"))
    }
}
