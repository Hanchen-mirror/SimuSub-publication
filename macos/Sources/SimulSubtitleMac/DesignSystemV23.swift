import SwiftUI

// Layout values from the approved SimuSub v2.3 HTML; colors come exclusively
// from the complete theme palette. Native window chrome is outside this canvas.
enum DesignV23 {
    static let sidebar: CGFloat = 190
    static let pageInset: CGFloat = 46
    static let panelInset: CGFloat = 26
    static let panelRadius: CGFloat = 18
}
extension View {
    func designPanel(inset: CGFloat = DesignV23.panelInset) -> some View {
        padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: DesignV23.panelRadius))
    }
    func designField() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ThemeColor.line))
    }
}
struct DesignPageHeading<Trailing: View>: View {
    @ObservedObject private var localization = AppLocalization.shared
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack { Text(L10n.text(title)).interfaceFont(size: 26, weight: .semibold); Spacer(); trailing() }
            .frame(minHeight: 32).padding(.bottom, 12)
    }
}
struct DesignToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.appThemeID) private var themeID
    func makeBody(configuration: Configuration) -> some View {
        let _ = themeID
        return HStack {
            configuration.label.interfaceFont(size: 13); Spacer()
            Button { configuration.isOn.toggle() } label: {
                Capsule().fill(configuration.isOn ? ThemeColor.primary : ThemeColor.line)
                    .frame(width: 32, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(3)
                    }
            }.buttonStyle(.plain).accessibilityLabel(L10n.text(configuration.isOn ? "关闭" : "开启"))
        }.opacity(enabled ? 1 : 0.45).accessibilityElement(children: .combine)
    }
}
struct DesignModeArt: View {
    let destination: WorkspaceDestination
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(ThemeColor.soft)
            switch destination {
            case .subtitle:
                Text("おはよう").interfaceFont(size: 11).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 11)).offset(x: -45, y: -13)
                Text(L10n.text("早上好呀")).interfaceFont(size: 11).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ThemeColor.selection, in: RoundedRectangle(cornerRadius: 11)).offset(x: 48, y: 15)
            case .recording:
                HStack(spacing: 5) { ForEach(Array([12,24,18,38,27,42,20,30,13].enumerated()), id: \.offset) { _, h in
                    Capsule().fill(ThemeColor.primary.opacity(0.55)).frame(width: 5, height: CGFloat(h))
                } }
                Circle().fill(ThemeColor.primary).frame(width: 8, height: 8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)
            default:
                HStack(spacing: 5) { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 3).fill(ThemeColor.surface) } }
                    .padding(5).frame(height: 40).background(ThemeColor.selection, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 26)
                Rectangle().fill(ThemeColor.primary).frame(width: 2, height: 56)
            }
        }.foregroundStyle(ThemeColor.primaryInk).frame(height: 76)
    }
}

// AppKit Menu intentionally retains its native keyboard/accessibility behavior;
// an inert visual overlay gives it the full-width v2.3 field appearance.
struct DesignMenuField<Items: View>: View {
    let title: String
    var height: CGFloat = 44
    @ViewBuilder var items: () -> Items
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        Menu(L10n.text(title), content: items).menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity).frame(height: height)
            .overlay {
                HStack { Text(L10n.text(title)).interfaceFont(size: 13).lineLimit(1); Spacer(); Image(systemName: "chevron.down").interfaceFont(size: 9) }
                    .foregroundStyle(ThemeColor.ink).padding(.horizontal, 13).frame(maxWidth: .infinity).frame(height: height)
                    .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ThemeColor.line)).allowsHitTesting(false)
            }
    }
}
