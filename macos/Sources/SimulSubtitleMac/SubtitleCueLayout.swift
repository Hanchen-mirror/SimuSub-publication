import AppKit

/// One baseline per visible language. The window controller uses the same fit as
/// the renderer, so folding is tied to the actual cue, typeface and zoom.
struct SubtitleCueLayout {
    static let minimumScale: CGFloat = 0.85

    struct Line {
        let original: Bool
        let fullText: String
        let text: String
        let preferredFont: NSFont
        let font: NSFont
        let pendingTranslation: Bool
        let truncated: Bool
    }

    let lines: [Line]
    let width: CGFloat
    let spacing: CGFloat
    let tooNarrow: Bool
    let tooShort: Bool

    /// Older cues use a stable row height independent of the viewport, including
    /// cues with a pending translation, so scrolling anchors survive live updates.
    static func historyHeight(mode: SubtitleDisplayMode, japaneseFont: String, chineseFont: String,
                              japaneseSize: CGFloat, chineseSize: CGFloat, zoom: WorkspaceZoom) -> CGFloat {
        func lineHeight(_ family: String, _ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            let font = SubtitleFont.native(family, size: size * zoom.factor, weight: weight)
            return ceil(font.ascender - font.descender + max(0, font.leading))
        }
        let source = lineHeight(japaneseFont, japaneseSize, .medium)
        let target = lineHeight(chineseFont, chineseSize, .semibold)
        switch mode {
        case .original: return source + 12
        case .chinese: return max(source, target) + 12
        case .bilingual: return source + 4 * zoom.factor + target + 12
        }
    }

    init(caption: Caption?, mode: SubtitleDisplayMode, size: CGSize, japaneseFont: String = "",
         chineseFont: String = "", japaneseSize: CGFloat = 16, chineseSize: CGFloat = 20,
         zoom: WorkspaceZoom = .normal) {
        let geometry = SubtitleToolbarLayout(size: size)
        let available = max(1, geometry.paperFrame.width - 12)
        width = available
        spacing = 4 * zoom.factor

        guard let caption = caption.map(SubtitleDocument.liveCaption) else {
            lines = []; tooNarrow = false; tooShort = false
            return
        }

        let originalOnly = mode == .original || caption.isOriginalOnly
        var texts: [(original: Bool, text: String, pending: Bool)] = []
        if originalOnly || (mode == .bilingual && caption.original != caption.translated) {
            if !caption.original.isEmpty { texts.append((true, caption.original, false)) }
        }
        if !originalOnly {
            let failed = caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成")
            let completed = SubtitleDocument.completedTranslation(caption)
            texts.append((false, completed ?? L10n.text(failed ? "翻译未完成" : "正在翻译…"), completed == nil && !failed))
        }

        let measured = texts.map { row in
            let family = row.original ? japaneseFont : chineseFont
            let weight: NSFont.Weight = row.original ? .medium : .semibold
            let pointSize = max(1, (row.original ? japaneseSize : chineseSize) * zoom.factor)
            let preferred = SubtitleFont.native(family, size: pointSize, weight: weight)
            let text = row.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let cue = text as NSString
            let naturalWidth = cue.size(withAttributes: [.font: preferred]).width
            let floorSize = pointSize * Self.minimumScale
            var fitted = preferred
            var clipped = false
            if naturalWidth > available {
                let floorFont = SubtitleFont.native(family, size: floorSize, weight: weight)
                clipped = cue.size(withAttributes: [.font: floorFont]).width > available
                fitted = floorFont
                if !clipped {
                    // Fallback glyphs and hinting can change advance nonlinearly with size.
                    var low = floorSize, high = pointSize
                    while high - low > 0.05 {
                        let mid = (low + high) / 2
                        let candidate = SubtitleFont.native(family, size: mid, weight: weight)
                        if cue.size(withAttributes: [.font: candidate]).width <= available {
                            low = mid
                            fitted = candidate
                        } else {
                            high = mid
                        }
                    }
                }
            }
            return (row: row, text: text, family: family, weight: weight, preferred: preferred, fitted: fitted, clipped: clipped)
        }
        tooNarrow = measured.contains { $0.clipped }
        let verticalRoom = geometry.paperFrame.height - 8 - CGFloat(max(0, measured.count - 1)) * spacing
        func height(at scale: CGFloat) -> CGFloat {
            measured.reduce(0) { sum, line in
                let font = line.preferred
                let limited = min(scale, line.fitted.pointSize / font.pointSize)
                return sum + (font.ascender - font.descender + max(0, font.leading)) * limited
            }
        }
        tooShort = !measured.isEmpty && height(at: Self.minimumScale) > verticalRoom
        var heightLimit: CGFloat = 1
        if height(at: 1) > verticalRoom {
            var low = Self.minimumScale, high: CGFloat = 1
            while high - low > 0.001 {
                let mid = (low + high) / 2
                if height(at: mid) <= verticalRoom { low = mid } else { high = mid }
            }
            heightLimit = low
        }
        lines = measured.map { line in
            let limit = line.preferred.pointSize * heightLimit
            let font = limit >= line.fitted.pointSize ? line.fitted
                : SubtitleFont.native(line.family, size: limit, weight: line.weight)
            return Line(original: line.row.original, fullText: line.row.text, text: line.text,
                        preferredFont: line.preferred, font: font, pendingTranslation: line.row.pending, truncated: line.clipped)
        }
    }
}
