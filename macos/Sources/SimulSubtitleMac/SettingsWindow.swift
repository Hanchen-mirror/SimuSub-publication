import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "外观", recording = "录制与剪辑", accounts = "平台", permissions = "权限", guide = "使用说明"
    var id: String { rawValue }
}

private struct SettingsCategoryGlyph: View {
    let category: SettingsCategory

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 20, y: size.height / 20)
            let pen = StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            switch category {
            case .appearance:
                let disc = CGRect(x: 2.5, y: 2.5, width: 15, height: 15)
                var litHalf = Path()
                litHalf.addArc(center: CGPoint(x: 10, y: 10), radius: 7.5,
                               startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
                litHalf.closeSubpath()
                context.fill(litHalf, with: .foreground)
                context.stroke(Path(ellipseIn: disc), with: .foreground, style: pen)
            case .recording:
                // A selected stretch of playable footage.
                var track = Path()
                track.addLines([CGPoint(x: 5, y: 4), CGPoint(x: 2.5, y: 4), CGPoint(x: 2.5, y: 16), CGPoint(x: 5, y: 16)])
                track.addLines([CGPoint(x: 15, y: 4), CGPoint(x: 17.5, y: 4), CGPoint(x: 17.5, y: 16), CGPoint(x: 15, y: 16)])
                context.stroke(track, with: .foreground, style: pen)
                var play = Path()
                play.addLines([CGPoint(x: 7.8, y: 6.4), CGPoint(x: 13.6, y: 10), CGPoint(x: 7.8, y: 13.6)])
                play.closeSubpath()
                context.fill(play, with: .foreground)
            case .accounts:
                // One connection branching out to the available platforms.
                var links = Path()
                links.addEllipse(in: CGRect(x: 7, y: 2, width: 6, height: 6))
                links.addLines([CGPoint(x: 10, y: 8), CGPoint(x: 10, y: 10)])
                links.addLines([CGPoint(x: 4, y: 14), CGPoint(x: 4, y: 12)])
                links.addQuadCurve(to: CGPoint(x: 6, y: 10), control: CGPoint(x: 4, y: 10))
                links.addLine(to: CGPoint(x: 14, y: 10))
                links.addQuadCurve(to: CGPoint(x: 16, y: 12), control: CGPoint(x: 16, y: 10))
                links.addLine(to: CGPoint(x: 16, y: 14))
                context.stroke(links, with: .foreground, style: pen)
                for x in [1.5, 13.5] {
                    context.fill(Path(roundedRect: CGRect(x: x, y: 13, width: 5, height: 4.5), cornerRadius: 1.3), with: .foreground)
                }
            case .guide:
                for x in [2, 10] {
                    let page = CGRect(x: x, y: 4, width: 8, height: 12)
                    context.stroke(Path(roundedRect: page, cornerRadius: 1.5), with: .foreground, style: pen)
                }
            case .permissions:
                var key = Path(ellipseIn: CGRect(x: 2, y: 2, width: 8.5, height: 8.5))
                key.move(to: CGPoint(x: 9.3, y: 9.3))
                key.addLine(to: CGPoint(x: 17.2, y: 17.2))
                key.addLine(to: CGPoint(x: 19, y: 15.4))
                key.move(to: CGPoint(x: 14.2, y: 14.2))
                key.addLine(to: CGPoint(x: 16.2, y: 12.2))
                context.stroke(key, with: .foreground, style: pen)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
struct SettingsWindow: View {
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var category: SettingsCategory = .appearance
    var recording = false
    var subtitleFontsFirst = false
    var initialCategory: String? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            let metrics = WorkspaceMetrics(width: geometry.size.width)
            let layout = metrics.stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 18))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DesignPageHeading(title: "设置") {
                        if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("关闭设置")) }
                    }
                    layout {
                        LazyVGrid(columns: metrics.stacked ? [GridItem(.adaptive(minimum: 116), spacing: 6)] : [GridItem(.flexible())], spacing: 4) {
                            ForEach(SettingsCategory.allCases) { item in
                                Button { withAnimation(reduceMotion || appearance.reduceMotion ? nil : .easeInOut(duration: 0.18)) { category = item } } label: {
                                    HStack(spacing: 7) {
                                        SettingsCategoryGlyph(category: item)
                                            .foregroundStyle(category == item ? ThemeColor.primaryInk : ThemeColor.muted)
                                        Text(L10n.text(item.rawValue)).lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .interfaceFont(size: 13)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .foregroundStyle(ThemeColor.ink)
                                    .background(category == item ? ThemeColor.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .help(L10n.text(item.rawValue))
                                    .accessibilityLabel(L10n.text(item.rawValue))
                                    .accessibilityAddTraits(category == item ? .isSelected : [])
                                    .accessibilityIdentifier("settings." + item.id)
                            }
                        }.frame(width: metrics.stacked ? nil : 122)

                        Group {
                            switch category {
                            case .appearance:
                                VStack(spacing: 20) {
                                    if subtitleFontsFirst { SubtitleFontSettings(stacked: metrics.narrow).designPanel(inset: metrics.cardInset) }
                                    AppearanceSettings(compact: metrics.narrow, inset: metrics.cardInset)
                                }
                            case .recording: LiveRecordingSettings()
                            case .accounts: PlatformAdvancedSettings()
                            case .permissions: SubtitlePermissionTools()
                            case .guide: UsageAboutSettingsView()
                            }
                        }.id(category).transition(.opacity).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }.padding(metrics.gutter)
            }
        }.background(ThemeColor.background).appTheme()
            .onAppear { if recording { category = .recording }; if let initialCategory, let initial = SettingsCategory(rawValue: initialCategory == "录制" ? "录制与剪辑" : initialCategory) { category = initial } }
    }
}
// Retained type for diagnostic callers; the actual settings entry is unified.
struct SubtitleSettingsContent: View { var body: some View { SubtitlePermissionTools() } }

struct SubtitleQuickSettings: View { var body: some View { SettingsWindow(subtitleFontsFirst: true) } }
