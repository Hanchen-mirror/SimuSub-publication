import AppKit
import SwiftUI

struct LiveCaptionStyle: Codable, Equatable {
    var fill: String?
    var outline = "#326BAD"
    var width: Double = 0
    var shadow: Double = 0
    var shadowHeight: Double?
    var effectiveShadowHeight: Double { shadowHeight ?? 1.4 }

    static let standard = LiveCaptionStyle()
    static let blue = LiveCaptionStyle(fill: "#FFFFFF", outline: "#326BAD", width: 1.3, shadow: 0.65)
    static let cinema = LiveCaptionStyle(fill: "#FFF4DB", outline: "#29221F", width: 1, shadow: 0.8)
}

struct LiveCaptionStyles: Codable, Equatable {
    var original: LiveCaptionStyle
    var translation: LiveCaptionStyle

    init(both style: LiveCaptionStyle) {
        original = style
        translation = style
    }

    static let standard = Self(both: .standard)
    static let blue = Self(both: .blue)
    static let cinema = Self(both: .cinema)
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
            .shadow(color: Color.black.opacity(style.shadow), radius: 1.8 * scale, y: style.effectiveShadowHeight * scale)
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
    @State private var editingOriginal = true

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
        let selected = appearance.captionStyle == LiveCaptionStyles(both: style)
        return Button { appearance.captionStyle = LiveCaptionStyles(both: style) } label: {
            LiveCaptionText(text: L10n.text(title), font: .systemFont(ofSize: 12, weight: .semibold),
                            fallback: ThemeColor.ink, style: style)
                .padding(.horizontal, 9).frame(height: 30)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? ThemeColor.primary : ThemeColor.line, lineWidth: selected ? 1.5 : 0.6) }
        }.buttonStyle(.plain).accessibilityLabel(L10n.text(title))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var line: Binding<LiveCaptionStyle> {
        editingOriginal ? $appearance.captionStyle.original : $appearance.captionStyle.translation
    }

    private var section: String { editingOriginal ? "原文" : "译文" }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("自定义字幕样式")).interfaceFont(size: 15, weight: .semibold)
                Spacer()
                Button { editing = false } label: {
                    Image(systemName: "checkmark").frame(width: 28, height: 26)
                }
                .buttonStyle(ThemeActionButtonStyle()).keyboardShortcut(.defaultAction)
                .help(L10n.text("完成")).accessibilityLabel(L10n.text("完成"))
            }
            VStack(spacing: 6) {
                LiveCaptionText(text: model.sourceLanguage.preview,
                    font: SubtitleFont.native(appearance.japaneseFont, size: appearance.japaneseSize, weight: .medium),
                    fallback: ThemeColor.muted, style: appearance.captionStyle.original)
                LiveCaptionText(text: model.targetLanguage.preview,
                    font: SubtitleFont.native(appearance.chineseFont, size: appearance.chineseSize, weight: .semibold),
                    fallback: ThemeColor.ink, style: appearance.captionStyle.translation)
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 4) {
                tab(original: true)
                tab(original: false)
            }
            ColorPicker(L10n.text("文字颜色"), selection: Binding(get: {
                line.wrappedValue.fill.map { Color(nsColor: .clipHex($0)) } ?? (editingOriginal ? ThemeColor.muted : ThemeColor.ink)
            }, set: { line.wrappedValue.fill = NSColor($0).clipHex }), supportsOpacity: false)
            ColorPicker(L10n.text("描边颜色"), selection: Binding(get: {
                Color(nsColor: .clipHex(line.wrappedValue.outline))
            }, set: {
                line.wrappedValue.outline = NSColor($0).clipHex
                if line.wrappedValue.width == 0 { line.wrappedValue.width = 1 }
            }), supportsOpacity: false)
            ClipStyleSlider(title: "描边宽度", section: section, value: line.width, limits: 0...2.5,
                            step: 0.1, readout: points(line.wrappedValue.width))
            ClipStyleSlider(title: "阴影强度", section: section, value: line.shadow, limits: 0...1,
                            step: 0.05, readout: line.wrappedValue.shadow.formatted(.percent))
            ClipStyleSlider(title: "阴影高度", section: section,
                            value: Binding(get: { line.wrappedValue.effectiveShadowHeight },
                                           set: { line.wrappedValue.shadowHeight = $0 }),
                            limits: -6...6, step: 0.1, readout: points(line.wrappedValue.effectiveShadowHeight))
        }.padding(16).frame(width: 310).appTheme()
    }

    private func points(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " pt"
    }

    private func tab(original: Bool) -> some View {
        let selected = original == editingOriginal
        return Button { editingOriginal = original } label: {
            Text(L10n.text(original ? "原文" : "译文"))
                .interfaceFont(size: 12, weight: selected ? .semibold : .regular)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(selected ? ThemeColor.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? ThemeColor.primaryInk : ThemeColor.muted)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
