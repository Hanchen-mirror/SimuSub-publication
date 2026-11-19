import AppKit
import CoreText
import CoreImage

enum ClipLanguageMode: String, Codable, CaseIterable, Identifiable {
    case chinese = "纯中文", japanese = "纯日语", bilingual = "双语"
    var title: String { switch self { case .chinese: "仅译文"; case .japanese: "仅原文"; case .bilingual: "双语" } }
    var id: String { rawValue }
}
struct ClipTextStyle: Codable, Equatable {
    var font = "PingFang SC"
    var size: Double = 42
    var color = "#FFFFFF"
    var bold = true
    var outlineColor = "#000000"
    var outline: Double = 2
}
struct ClipSubtitlePosition: Codable, Equatable {
    var x: Double = 0.5
    var y: Double = 0.85
    var width: Double = 0.6
    var valid: Bool { [x, y, width].allSatisfy { $0.isFinite && (0...1).contains($0) } && width >= 0.2 }
}
struct ClipSubtitleMask: Codable, Equatable {
    var enabled = true
    var x: Double = 0.5
    var y: Double = 0.88
    var width: Double = 0.9
    var height: Double = 0.12
    var color = "#17151C"
    var opacity: Double = 1
    var valid: Bool { [x, y, width, height, opacity].allSatisfy { $0.isFinite && (0...1).contains($0) } && width >= 0.02 && height >= 0.02 && ClipSubtitleStyle.isColor(color) }
}
struct ClipSubtitleStyle: Codable, Equatable {
    var mode: ClipLanguageMode = .bilingual
    var chinese = ClipTextStyle()
    var japanese = ClipTextStyle(font: "Hiragino Sans", size: 28, bold: false)
    var chineseFirst = true
    var alignment = 1
    var spacing: Double = 8
    var bottom: Double = 36
    var background: Double = 0
    var shadow = true
    var position: ClipSubtitlePosition?
    var mask: ClipSubtitleMask?
    static var classic: Self { Self() }
    static var pink: Self { var s = Self(); s.chinese.color = "#F2CDD8"; return s }
    static var gold: Self { var s = Self(); s.chinese.color = "#E9D6A2"; s.chinese.size = 46; return s }
    var valid: Bool {
        [chinese, japanese].allSatisfy { t in
            t.size.isFinite && (12...120).contains(t.size) && t.outline.isFinite && (0...10).contains(t.outline)
            && t.font.count <= 100 && Self.isColor(t.color) && Self.isColor(t.outlineColor)
        } && spacing.isFinite && (0...60).contains(spacing) && bottom.isFinite && (0...400).contains(bottom)
            && background.isFinite && (0...1).contains(background) && (0...2).contains(alignment)
            && (position?.valid ?? true) && (mask?.valid ?? true)
    }
    static func isColor(_ value: String) -> Bool { value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }
    func lines(_ cue: Caption) -> [(String, ClipTextStyle)] {
        let zh = (SubtitleDocument.completedTranslation(cue) ?? "", chinese)
        let ja = (cue.original, japanese)
        return (mode == .chinese ? [zh] : mode == .japanese ? [ja] : chineseFirst ? [zh, ja] : [ja, zh]).filter { !$0.0.isEmpty }
    }
    func complete(_ cues: [Caption]) -> Bool {
        !cues.isEmpty && cues.allSatisfy {
            (mode == .chinese || mode == .bilingual ? SubtitleDocument.completedTranslation($0) != nil : true)
            && (mode == .japanese || mode == .bilingual ? !$0.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true)
        }
    }
}
extension NSColor {
    static func clipHex(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    var clipHex: String {
        let c = usingColorSpace(.sRGB) ?? .white
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// One CoreText renderer powers the editor, style preview and exported video.
/// Sizes and margins are expressed at a 1920px video width and scale together.
enum ClipSubtitleRenderer {
    static func previewSize(_ media: CGSize) -> CGSize {
        let factor = min(1, 1280 / max(1, media.width))
        return CGSize(width: max(16, media.width * factor), height: max(16, media.height * factor))
    }
    static func overlay(_ cue: Caption, size: CGSize, style requested: ClipSubtitleStyle) -> CGImage? {
        let style = requested.valid ? requested : .classic
        let scale = max(0.05, size.width / 1920), width = max(32, floor(size.width * (style.position?.width ?? 0.92)))
        let padding = max(4, 14 * scale)
        var ratio: CGFloat = 1
        var text = NSMutableAttributedString(string: ""), height: CGFloat = 0
        repeat {
            text = NSMutableAttributedString(string: "")
            for (index, item) in style.lines(cue).enumerated() {
                let (line, spec) = item
                let fontSize = max(5, spec.size * scale * ratio)
                let base = NSFont(name: spec.font, size: fontSize) ?? .systemFont(ofSize: fontSize)
                let font = spec.bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = style.alignment == 0 ? .left : style.alignment == 2 ? .right : .center
                paragraph.lineSpacing = style.spacing * scale * ratio
                paragraph.paragraphSpacing = style.spacing * scale * ratio
                let ctFont = CTFontCreateWithName(font.fontName as CFString, fontSize, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.clipHex(spec.color).cgColor,
                    NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): false,
                    NSAttributedString.Key(kCTStrokeColorAttributeName as String): NSColor.clipHex(spec.outlineColor).cgColor,
                    NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -spec.outline / spec.size * 100,
                    .paragraphStyle: paragraph]
                text.append(NSAttributedString(string: (index == 0 ? "" : "\n") + line, attributes: attributes))
            }
            guard text.length > 0 else { return nil }
            height = ceil(CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: text.length), nil,
                CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude), nil).height)
            if height + padding * 2 < size.height * 0.7 || ratio <= 0.2 { break }
            ratio *= 0.9
        } while true
        let h = max(1, Int(ceil(height + padding * 2)))
        guard let ctx = CGContext(data: nil, width: Int(width), height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style.background > 0 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(style.background).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: CGFloat(h)), cornerWidth: padding, cornerHeight: padding, transform: nil)); ctx.fillPath()
        }
        let path = CGPath(rect: CGRect(x: padding, y: padding, width: width - padding * 2, height: height), transform: nil)
        let strokeText = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let width = abs(attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] as? Double ?? 0)
            let color = width > 0 ? attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)]! : NSColor.clear.cgColor
            strokeText.addAttributes([NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): color,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): max(0.001, width)], range: range)
        }
        if style.shadow { ctx.setShadow(offset: CGSize(width: scale, height: -scale), blur: 3 * scale, color: NSColor.black.withAlphaComponent(0.8).cgColor) }
        let outlineFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(strokeText), CFRange(location: 0, length: text.length), path, nil)
        CTFrameDraw(outlineFrame, ctx)
        let fillText = NSMutableAttributedString(attributedString: text)
        fillText.removeAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), range: NSRange(location: 0, length: fillText.length))
        fillText.removeAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), range: NSRange(location: 0, length: fillText.length))
        let fillFrame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(fillText), CFRange(location: 0, length: fillText.length), path, nil)
        CTFrameDraw(fillFrame, ctx)
        return ctx.makeImage()
    }
    static func preview(_ cue: Caption, style: ClipSubtitleStyle) -> NSImage? {
        guard let image = overlay(cue, size: CGSize(width: 1920, height: 1080), style: style), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        var minX = image.width, maxX = 0
        for y in 0..<image.height { for x in 0..<image.width {
            if bytes[y * image.bytesPerRow + x * 4 + 3] > 40 { minX = min(minX, x); maxX = max(maxX, x) }
        } }
        let x = max(0, minX - 18), width = min(image.width - x, maxX - x + 19)
        guard width > 0, let cropped = image.cropping(to: CGRect(x: x, y: 0, width: width, height: image.height)) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: cropped.width, height: cropped.height))
    }
    /// Origin in the video pixel coordinate system (bottom-left), shared by preview/export.
    static func origin(size: CGSize, overlay: CGSize, style: ClipSubtitleStyle) -> CGPoint {
        guard let position = style.position, position.valid else {
            return CGPoint(x: (size.width - overlay.width) / 2,
                y: min(max(0, size.height - overlay.height), min(size.height * 0.25, style.bottom * size.width / 1920)))
        }
        return CGPoint(x: min(max(0, size.width * position.x - overlay.width / 2), max(0, size.width - overlay.width)),
            y: min(max(0, size.height * (1 - position.y) - overlay.height / 2), max(0, size.height - overlay.height)))
    }
    static func maskRect(size: CGSize, mask: ClipSubtitleMask) -> CGRect {
        let w = size.width * mask.width, h = size.height * mask.height
        return CGRect(x: min(max(0, size.width * mask.x - w / 2), size.width - w),
                      y: min(max(0, size.height * (1 - mask.y) - h / 2), size.height - h), width: w, height: h)
    }
    static func frame(_ cue: Caption?, size: CGSize, style: ClipSubtitleStyle) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let mask = style.mask, mask.valid, mask.enabled {
            ctx.setFillColor(NSColor.clipHex(mask.color).withAlphaComponent(mask.opacity).cgColor)
            let rect = maskRect(size: size, mask: mask), radius = max(1, size.width / 1920 * 5)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
        }
        if let cue, let overlay = overlay(cue, size: size, style: style) {
            let overlaySize = CGSize(width: overlay.width, height: overlay.height)
            ctx.draw(overlay, in: CGRect(origin: origin(size: size, overlay: overlaySize, style: style), size: overlaySize))
        }
        return ctx.makeImage()
    }
    static func image(_ cue: Caption?, size: CGSize, style: ClipSubtitleStyle) -> NSImage? {
        frame(cue, size: size, style: style).map { NSImage(cgImage: $0, size: size) }
    }
}

struct ClipStylePreset: Identifiable, Codable {
    var id = UUID()
    var name: String
    var style: ClipSubtitleStyle
}
@MainActor
final class ClipStyleLibrary: ObservableObject {
    @Published private(set) var presets: [ClipStylePreset] = []
    private let storage: LiveMonitorStorage
    init(root: URL) { storage = LiveMonitorStorage(root: root); presets = storage.load([ClipStylePreset].self, name: "styles", fallback: []).0 }
    func save(name: String, style: ClipSubtitleStyle) throws {
        guard style.valid else { throw ClipError.message("样式参数无效。") }
        let value = ClipStylePreset(name: String(name.prefix(40)), style: style)
        let next = Array(([value] + presets).prefix(40))
        try storage.save(next, name: "styles"); presets = next
    }
}
