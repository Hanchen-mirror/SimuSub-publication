import Foundation

enum ClipImportLayout: String, CaseIterable, Identifiable {
    case automatic = "自动识别"
    case chineseFirst = "双语：中文在上", japaneseFirst = "双语：日语在上", chinese = "纯中文", japanese = "纯日语"
    var id: String { rawValue }
}
enum ClipSubtitleImport {
    static func parse(_ text: String, extension ext: String, layout: ClipImportLayout, offset: Double, duration: Double) throws -> [Caption] {
        guard text.utf8.count <= 5_000_000 else { throw ClipError.message("字幕文件请控制在 5 MB 以内。") }
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        var entries: [(Double, Double, String)] = []
        if ["ass", "ssa"].contains(ext.lowercased()) {
            var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
            var events = false
            for line in clean.components(separatedBy: "\n") {
                if line.hasPrefix("[") { events = line.lowercased() == "[events]" }
                guard events else { continue }
                if line.lowercased().hasPrefix("format:") { fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
                guard line.lowercased().hasPrefix("dialogue:"), let a = fields.firstIndex(of: "start"), let b = fields.firstIndex(of: "end"), let t = fields.firstIndex(of: "text") else { continue }
                let parts = line.dropFirst(9).split(separator: ",", maxSplits: max(0, fields.count - 1), omittingEmptySubsequences: false).map(String.init)
                guard parts.count == fields.count, let start = ClipTime.parse(parts[a]), let end = ClipTime.parse(parts[b]) else { continue }
                entries.append((start, end, parts[t].replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression).replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")))
            }
        } else {
            let lines = clean.components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let timing = lines[index].components(separatedBy: "-->")
                guard timing.count == 2, let start = ClipTime.parse(timing[0]), let end = ClipTime.parse(String(timing[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { index += 1; continue }
                index += 1; var payload: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { payload.append(lines[index]); index += 1 }
                entries.append((start, end, payload.joined(separator: "\n")))
            }
        }
        let cues = entries.compactMap { a, b, value -> Caption? in
            let lines = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
                .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard b > a, a + offset < duration, b + offset > 0, !lines.isEmpty else { return nil }
            let original: String, translated: String
            switch layout {
            case .automatic:
                let japanese = lines.filter { $0.range(of: "[\\u3040-\\u30ff]", options: .regularExpression) != nil }
                if japanese.isEmpty && lines.count > 1 { original = lines[0]; translated = lines.dropFirst().joined(separator: "\n") }
                else { original = japanese.joined(separator: "\n"); translated = lines.filter { !japanese.contains($0) }.joined(separator: "\n") }

            case .chinese: original = ""; translated = lines.joined(separator: "\n")
            case .japanese: original = lines.joined(separator: "\n"); translated = ""
            case .chineseFirst: translated = lines[0]; original = lines.dropFirst().joined(separator: "\n")
            case .japaneseFirst: original = lines[0]; translated = lines.dropFirst().joined(separator: "\n")
            }
            return Caption(start: max(0, a + offset), end: min(duration, b + offset), original: String(original.prefix(1000)), translated: String(translated.prefix(1000)))
        }.sorted { $0.start < $1.start }
        guard !cues.isEmpty, cues.count <= 50000 else { throw ClipError.message("没有读到有效字幕。支持 SRT / VTT / ASS，请确认格式与时间范围。") }
        return cues
    }
    static func render(_ cues: [Caption], format: SubtitleExportFormat, style: ClipSubtitleStyle) -> String {
        let content = cues.enumerated().compactMap { index, cue -> String? in
            let lines = style.lines(cue).map(\.0).joined(separator: "\n")
            guard !lines.isEmpty else { return nil }
            let a = ClipTime.label(cue.start), b = ClipTime.label(cue.end)
            let timing = format == .srt ? (a + " --> " + b).replacingOccurrences(of: ".", with: ",") : a + " --> " + b
            let payload = format == .vtt ? lines.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") : lines
            return (format == .srt ? "\(index + 1)\n" : "") + timing + "\n" + payload
        }
        return content.isEmpty ? "" : (format == .vtt ? "WEBVTT\n\n" : "") + content.joined(separator: "\n\n") + "\n"
    }
}
