import SwiftUI

/// The same 24 pt drawing grid as the reviewed design. Rendering at 12–14 pt keeps
/// the captions visually dominant, while the separate button hit area stays 24 pt.
enum SubtitlePanelGlyph: Shape {
    case pause, play, pin, home, export, clear, original, bilingual, languages

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: point(x, y)) }
        func line(_ x: CGFloat, _ y: CGFloat) { path.addLine(to: point(x, y)) }
        func curve(_ x: CGFloat, _ y: CGFloat, _ cx: CGFloat, _ cy: CGFloat) {
            path.addQuadCurve(to: point(x, y), control: point(cx, cy))
        }
        switch self {
        case .pause:
            move(8, 6); line(8, 18); move(16, 6); line(16, 18)
        case .play:
            move(7, 4.6); line(19, 12); line(7, 19.4); path.closeSubpath()
        case .pin:
            move(15.1, 2.9); line(21.1, 8.9); line(18.3, 9.5); line(14.4, 13.5)
            line(14, 16.8); line(12.7, 18.1); line(5.7, 11.1); line(7, 9.8)
            line(10.3, 9.4); line(14.3, 5.6); path.closeSubpath()
            move(9.2, 14.7); line(3.1, 20.8)
        case .home:
            move(3, 10.7); line(10.8, 3.9); curve(13.2, 3.9, 12, 2.8); line(21, 10.7)
            move(5, 9); line(5, 18.2); curve(7, 20, 5, 20); line(9.6, 20); line(9.6, 14.2)
            line(14.4, 14.2); line(14.4, 20); line(17, 20); curve(19, 18.2, 19, 20); line(19, 9)
        case .export:
            move(12, 14.3); line(12, 3.1); move(7.6, 7.5); line(12, 3.1); line(16.4, 7.5)
            move(3.4, 13.1); line(3.4, 18); curve(6, 20.4, 3.4, 20.4)
            line(18, 20.4); curve(20.6, 18, 20.6, 20.4); line(20.6, 13.1)
        case .clear:
            move(3.5, 13.3); line(12.6, 4.2); curve(15.7, 4.2, 14.15, 2.65)
            line(19.9, 8.4); curve(19.9, 11.5, 21.45, 9.95); line(11.2, 20.2)
            line(8.4, 20.2); line(3.5, 15.3); curve(3.5, 13.3, 2.5, 14.3)
            move(7.5, 9.4); line(14.8, 16.7); move(11.2, 20.2); line(21.2, 20.2)
        case .original:
            path.addRoundedRect(in: CGRect(x: 2.7, y: 5.2, width: 18.6, height: 13.6),
                                cornerSize: CGSize(width: 1.7, height: 1.7))
            move(7.1, 14.2); line(16.9, 14.2)
        case .bilingual:
            move(2.3, 13.4); line(2.3, 5); curve(4.3, 3, 2.3, 3); line(16.6, 3)
            path.addRoundedRect(in: CGRect(x: 7, y: 7.8, width: 14.6, height: 12.6),
                                cornerSize: CGSize(width: 1.8, height: 1.8))
            move(10.9, 15.9); line(17.8, 15.9)
        case .languages:
            // Two overlapping speech bubbles, matching the approved comparison.
            move(1.5, 6.5); curve(5, 3.5, 1.5, 3.5); line(12.8, 3.5)
            curve(16.3, 7.1, 16.3, 3.5); line(16.3, 10); curve(12.8, 13, 16.3, 13)
            line(8, 13); line(3.7, 16); line(3.7, 12.8); curve(1.5, 10, 1.5, 12.2); path.closeSubpath()
            move(10.7, 15.6); curve(14.4, 18.6, 10.7, 18.6); line(17.4, 18.6)
            line(21.2, 21.4); line(21.2, 17.9); curve(23, 15.2, 23, 17.3); line(23, 11.3)
            curve(19.7, 8.3, 23, 8.3)
            move(5.8, 8.2); line(11.6, 8.2)
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .concatenating(.init(translationX: rect.minX, y: rect.minY)))
    }
}

struct SubtitleLanguagePicker: View {
    @State var source: SubtitleLanguage
    @State var target: SubtitleLanguage
    var onCancel: () -> Void
    var onApply: (SubtitleLanguage, SubtitleLanguage) -> Void
    private let options: [SubtitleLanguage] = [.japanese, .english, .simplifiedChinese, .traditionalChinese]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SubtitlePanelGlyph.languages.stroke(style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .frame(width: 17, height: 17).foregroundStyle(ThemeColor.primary)
                Text(L10n.text("翻译语言")).font(.headline)
                Spacer()
                Button {
                    (source, target) = (target, source)
                } label: {
                    Image(systemName: "arrow.left.arrow.right").frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L10n.text("交换语言")).accessibilityLabel(L10n.text("交换语言"))
                .accessibilityIdentifier("subtitle.languages.swap")
            }
            choices(isSource: true)
            choices(isSource: false)
            Divider()
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: onCancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("subtitle.languages.cancel")
                Button(L10n.text("应用")) { onApply(source, target) }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("subtitle.languages.apply")
            }
        }
        .foregroundStyle(ThemeColor.ink)
        .padding(18).frame(width: 356)
        .background(ThemeColor.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.languages.picker")
    }

    private func choices(isSource: Bool) -> some View {
        let title = L10n.text(isSource ? "源语言" : "翻译为")
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(ThemeColor.muted)
            HStack(spacing: 3) {
                ForEach(options) { language in
                    let selected = (isSource ? source : target) == language
                    Button {
                        if isSource {
                            if language == target { target = source }
                            source = language
                        } else {
                            if language == source { source = target }
                            target = language
                        }
                    } label: {
                        Text(L10n.text(language.name)).font(.system(size: 12, weight: selected ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, minHeight: 28)
                            .background(selected ? ThemeColor.selection : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).accessibilityLabel(title + " " + L10n.text(language.name))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("subtitle.languages." + (isSource ? "source." : "target.") + language.rawValue)
                }
            }
            .padding(3).background(ThemeColor.soft, in: Capsule())
        }
    }
}
