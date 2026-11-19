import Foundation
import UniformTypeIdentifiers

enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case bilingual = "日中双语"
    case chinese = "仅中文"
    case original = "仅原文"
    var title: String { self == .bilingual ? "双语" : self == .original ? "仅原文" : "仅译文" }
    var id: String { rawValue }
}

enum SubtitleExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, vtt
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var contentType: UTType { UTType(filenameExtension: rawValue) ?? .plainText }
}

enum SubtitleDocument {
    /// Recognize structured model output, not words such as “正在修改” in dialogue.
    static func isTranslationArtifact(_ translation: String, original: String) -> Bool {
        guard translation != original, !translation.isEmpty else { return false }
        let lines = translation.split(whereSeparator: \.isNewline)
        if lines.count > 1 && lines.dropFirst().contains(where: { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            return ["原文：", "原文:", "原句：", "原句:", "【当前原文】"].contains(where: value.hasPrefix)
        }) {
            // An utterance quoting or discussing source text can legitimately contain these labels.
            let quotedSource = ["原文", "原句", "原来的句子", "元の文", "原稿", "original", "source text", "sentence", "quote"]
            return !quotedSource.contains { original.localizedCaseInsensitiveContains($0) }
        }
        // A previous reaction is not the translation of a long, spoken sentence.
        let reaction = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["*笑*", "*笑了*", "（笑）", "(笑)", "[笑声]", "［笑声］"].contains(reaction) else { return false }
        return original.split(whereSeparator: \.isWhitespace).count >= 16 &&
            !["laugh", "笑"].contains { original.localizedCaseInsensitiveContains($0) }
    }

    /// Only live machine-generated captions pass through this projection. Clip edits
    /// and imported subtitles retain exactly the text the user authored.
    static func liveCaption(_ caption: Caption) -> Caption {
        guard isTranslationArtifact(caption.translated, original: caption.original) else { return caption }
        var result = caption
        result.translated = ""
        return result
    }

    static func completedTranslation(_ caption: Caption) -> String? {
        let text = normalized(caption.translated)
        guard !text.isEmpty, text != "正在翻译…", !text.hasPrefix("翻译失败"),
              !text.hasPrefix("译文未完成") else { return nil }
        return text
    }

    static func render(_ captions: [Caption], format: SubtitleExportFormat, mode: SubtitleDisplayMode) -> String {
        let entries = captions.compactMap { caption -> (Caption, String)? in
            guard !caption.isDraft, caption.start.isFinite, caption.end.isFinite else { return nil }
            let original = normalized(caption.original)
            if mode == .original || caption.isOriginalOnly { return original.isEmpty ? nil : (caption, original) }
            guard let chinese = completedTranslation(caption) else { return nil }
            return (caption, mode == .bilingual && !original.isEmpty && original != chinese ? original + "\n" + chinese : chinese)
        }
        guard !entries.isEmpty else { return "" }
        if format == .txt { return entries.map(\.1).joined(separator: "\n\n") + "\n" }
        let cues = entries.enumerated().map { index, entry in
            let (caption, text) = entry
            let start = max(0, Int((caption.start * 1_000).rounded()))
            let end = max(start + 1, Int((caption.end * 1_000).rounded()))
            let payload = format == .vtt ? text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") : text
            let timing = "\(timestamp(start, comma: format == .srt)) --> \(timestamp(end, comma: format == .srt))"
            return (format == .srt ? "\(index + 1)\n" : "") + timing + "\n" + payload
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + cues.joined(separator: "\n\n") + "\n"
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp(_ ms: Int, comma: Bool) -> String {
        String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60,
               (ms / 1_000) % 60, comma ? "," : ".", ms % 1_000)
    }
}
