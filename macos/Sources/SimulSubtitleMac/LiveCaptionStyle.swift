import AppKit
import SwiftUI

struct LiveCaptionStyle: Codable, Equatable {
    var fill: String?
    var outline = "#326BAD"
    var width: Double = 0
    var shadow: Double = 0

    static let standard = LiveCaptionStyle()
    static let blue = LiveCaptionStyle(fill: "#FFFFFF", outline: "#326BAD", width: 1.3, shadow: 0.65)
    static let cinema = LiveCaptionStyle(fill: "#FFF4DB", outline: "#29221F", width: 1, shadow: 0.8)
}

// The visible text supplies both its natural metrics and its selection behavior.
// Paint the outline behind the glyphs so the fill keeps its original weight.
struct LiveCaptionText: View {
    let text: String
    let font: NSFont
    let fallback: Color
    let style: LiveCaptionStyle
    var scale: CGFloat = 1

    var body: some View {
        let label = Text(verbatim: text).font(Font(font)).lineLimit(1).truncationMode(.tail)
        label.foregroundStyle(style.fill.map { Color(nsColor: .clipHex($0)) } ?? fallback)
            .background {
                if style.width > 0 {
                    GeometryReader { geometry in
                        outlineCanvas(label: label, width: geometry.size.width)
                            .padding(-4 * scale)
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .shadow(color: Color.black.opacity(style.shadow), radius: 1.8 * scale, y: 1.4 * scale)
    }

    private func outlineCanvas(label: some View, width: CGFloat) -> some View {
        Canvas { context, size in
            guard let glyphs = context.resolveSymbol(id: 0) else { return }
            let radius = style.width * scale
            for index in 0..<12 {
                let angle = Double(index) * .pi / 6
                let center = CGPoint(x: size.width / 2 + cos(angle) * radius,
                                     y: size.height / 2 + sin(angle) * radius)
                context.draw(glyphs, at: center)
            }
        } symbols: {
            label.foregroundStyle(Color(nsColor: .clipHex(style.outline)))
                .frame(width: width)
                .tag(0)
        }
    }
}

struct LiveCaptionStylePicker: View {
    @EnvironmentObject private var appearance: HomeAppearance
    @EnvironmentObject private var model: AppModel
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            preset("默认", .standard)
            preset("蓝边", .blue)
            preset("暖白", .cinema)
            Button { editing = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30)
            }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk)
                .help(L10n.text("自定义字幕样式")).accessibilityLabel(L10n.text("自定义字幕样式"))
                .popover(isPresented: $editing) { editor }
        }.frame(maxWidth: .infinity, alignment: .center)
    }

    private func preset(_ title: String, _ style: LiveCaptionStyle) -> some View {
        let selected = appearance.captionStyle == style
        return Button { appearance.captionStyle = style } label: {
            LiveCaptionText(text: L10n.text(title), font: .systemFont(ofSize: 12, weight: .semibold),
                            fallback: ThemeColor.ink, style: style)
                .padding(.horizontal, 9).frame(height: 30)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? ThemeColor.primary : ThemeColor.line, lineWidth: selected ? 1.5 : 0.6) }
        }.buttonStyle(.plain).accessibilityLabel(L10n.text(title))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("自定义字幕样式")).font(.headline)
            LiveCaptionText(text: model.targetLanguage.preview,
                            font: SubtitleFont.native(appearance.chineseFont, size: appearance.chineseSize, weight: .semibold),
                            fallback: ThemeColor.ink, style: appearance.captionStyle)
                .frame(maxWidth: .infinity).padding(10)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8))
            ColorPicker(L10n.text("文字颜色"), selection: Binding(get: {
                appearance.captionStyle.fill.map { Color(nsColor: .clipHex($0)) } ?? ThemeColor.ink
            }, set: {
                appearance.captionStyle.fill = NSColor($0).clipHex
            }), supportsOpacity: false)
            ColorPicker(L10n.text("描边颜色"), selection: Binding(get: {
                Color(nsColor: .clipHex(appearance.captionStyle.outline))
            }, set: {
                appearance.captionStyle.outline = NSColor($0).clipHex
                if appearance.captionStyle.width == 0 { appearance.captionStyle.width = 1 }
            }), supportsOpacity: false)
            HStack {
                Text(L10n.text("描边宽度"))
                Slider(value: $appearance.captionStyle.width, in: 0...2.5, step: 0.1)
                    .accessibilityLabel(L10n.text("描边宽度"))
                Text(appearance.captionStyle.width.formatted(.number.precision(.fractionLength(1))) + " pt")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text(L10n.text("阴影"))
                Slider(value: $appearance.captionStyle.shadow, in: 0...1, step: 0.05)
                    .accessibilityLabel(L10n.text("阴影"))
                Text(appearance.captionStyle.shadow.formatted(.percent)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            HStack { Spacer(); Button(L10n.text("完成")) { editing = false }.keyboardShortcut(.defaultAction) }
        }.padding(18).frame(width: 290).appTheme()
    }
}
