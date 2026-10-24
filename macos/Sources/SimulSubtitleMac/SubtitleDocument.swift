import Foundation
import UniformTypeIdentifiers

enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case bilingual = "日中双语"
    case chinese = "仅中文"
    var id: String { rawValue }
}

enum SubtitleExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, vtt
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var contentType: UTType { UTType(filenameExtension: rawValue) ?? .plainText }
}

enum SubtitleDocument {
    static func completedTranslation(_ caption: Caption) -> String? {
        let text = normalized(caption.translated)
        guard !text.isEmpty, text != "正在翻译…", !text.hasPrefix("翻译失败"),
              !text.hasPrefix("译文未完成") else { return nil }
        return text
    }

    static func render(_ captions: [Caption], format: SubtitleExportFormat, mode: SubtitleDisplayMode) -> String {
        let entries = captions.compactMap { caption -> (Caption, String)? in
            guard !caption.isDraft, caption.start.isFinite, caption.end.isFinite,
                  let chinese = completedTranslation(caption) else { return nil }
            let original = normalized(caption.original)
            return (caption, mode == .bilingual && !original.isEmpty ? original + "\n" + chinese : chinese)
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
