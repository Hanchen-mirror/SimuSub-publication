import AppKit
import Foundation

/// Swift adaptation of Google BudouX's plain-text parser.
/// Copyright 2021 Google LLC. Licensed under Apache-2.0.
/// Upstream commit, model hashes, license and local changes: Resources/TextLayout/.
final class BudouXModel {
    private let model: [String: [String: Int]]
    private let baseScore: Double

    init?(url: URL?) {
        guard let url, let data = try? Data(contentsOf: url),
              let model = try? JSONDecoder().decode([String: [String: Int]].self, from: data), !model.isEmpty else { return nil }
        self.model = model
        baseScore = -Double(model.values.reduce(0) { $0 + $1.values.reduce(0, +) }) * 0.5
    }

    func parse(_ text: String) -> [String] {
        let scalars = text.unicodeScalars.map(String.init)
        guard !scalars.isEmpty else { return [] }
        // Python uses Unicode scalar positions. Preserve Swift grapheme clusters
        // as an additional constraint so emoji and combining marks remain whole.
        var graphemeBoundaries: Set<Int> = []
        var position = 0
        for character in text { position += character.unicodeScalars.count; graphemeBoundaries.insert(position) }
        let features: [(String, Int, Int)] = [
            ("UW1", -3, -2), ("UW2", -2, -1), ("UW3", -1, 0), ("UW4", 0, 1), ("UW5", 1, 2), ("UW6", 2, 3),
            ("BW1", -2, 0), ("BW2", -1, 1), ("BW3", 0, 2),
            ("TW1", -3, 0), ("TW2", -2, 1), ("TW3", -1, 2), ("TW4", 0, 3)
        ]
        var chunks = [scalars[0]]
        for index in 1..<scalars.count {
            var score = baseScore
            for (name, lo, hi) in features where index + lo >= 0 && index + hi <= scalars.count {
                score += Double(model[name]?[scalars[(index + lo)..<(index + hi)].joined()] ?? 0)
            }
            if score > 0 && graphemeBoundaries.contains(index) { chunks.append(scalars[index]) }
            else { chunks[chunks.count - 1] += scalars[index] }
        }
        return chunks
    }
}

/// Display only: never modifies the ASR source, translation context, or exports.
enum SubtitleLineLayout {
    enum Language: String { case japanese = "ja", chinese = "zh-hans", traditionalChinese = "zh-hant", english = "en" }
    private static let japanese = load(.japanese)
    private static let chinese = load(.chinese)
    private static let traditionalChinese = load(.traditionalChinese)
    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>(); value.countLimit = 256; return value
    }()
    private static let closing = Set("、。，．？！!?：:；;)）」』】〕〉》｝］…ーぁぃぅぇぉっゃゅょァィゥェォッャュョヵヶ")
    private static let opening = Set("（(「『【〔〈《｛［")
    private static let punctuation = Set("、，。！？!?；;：:")
    private static let attachedJapanese = Set(["は", "が", "を", "に", "へ", "で", "と", "も", "の", "ね", "よ", "だけ", "まで", "ので", "ない", "ません"])

    static var modelsAvailable: Bool { japanese != nil && chinese != nil }
    static func chunks(_ text: String, language: Language) -> [String] {
        switch language {
        case .japanese: return japanese?.parse(text) ?? text.map(String.init)
        case .chinese: return chinese?.parse(text) ?? text.map(String.init)
        case .traditionalChinese: return traditionalChinese?.parse(text) ?? text.map(String.init)
        case .english: return text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { ($0.offset == 0 ? "" : " ") + $0.element }
        }
    }

    static func format(_ text: String, language: Language, width: CGFloat, font: NSFont) -> String {
        guard !text.isEmpty else { return text }
        let limit = max(24, min(width.rounded(.down), font.pointSize * 24))
        let key = "\(language.rawValue)|\(limit)|\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let saved = cache.object(forKey: key) { return saved as String }
        let result = text.components(separatedBy: "\n").map { paragraph -> String in
            var phrases: [String] = []
            for phrase in chunks(paragraph, language: language) {
                if let previous = phrases.last, let last = previous.last, let first = phrase.first,
                   opening.contains(last) || closing.contains(first)
                    || (asciiWord(last) && asciiWord(first))
                    || (language == .japanese && attachedJapanese.contains(phrase)) {
                    phrases[phrases.count - 1] += phrase
                } else { phrases.append(phrase) }
            }
            func measured(_ value: String) -> CGFloat { (value as NSString).size(withAttributes: [.font: font]).width }
            var lines: [String] = []
            var start = 0
            while start < phrases.count {
                var end = start
                var line = ""
                while end < phrases.count && measured(line + phrases[end]) <= limit {
                    line += phrases[end]; end += 1
                }
                if end == start {
                    lines.append(contentsOf: splitOversized(phrases[start], width: limit, font: font))
                    start += 1
                    continue
                }
                var cut = end
                // Prefer a clause punctuation boundary near the end of a full
                // line. Never turn every short phrase into a separate line.
                if end < phrases.count {
                    for candidate in stride(from: end, through: start + 1, by: -1) {
                        if let last = phrases[candidate - 1].last, punctuation.contains(last),
                           measured(phrases[start..<candidate].joined()) >= limit * 0.55 {
                            cut = candidate; break
                        }
                    }
                }
                lines.append(phrases[start..<cut].joined())
                start = cut
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
        cache.setObject(result as NSString, forKey: key)
        return result
    }

    private static func splitOversized(_ text: String, width: CGFloat, font: NSFont) -> [String] {
        var lines: [String] = [], line = ""
        for character in text {
            let next = line + String(character)
            if !line.isEmpty, (next as NSString).size(withAttributes: [.font: font]).width > width,
               !closing.contains(character), !(line.last.map(opening.contains) ?? false) {
                lines.append(line); line = String(character)
            } else { line = next }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func asciiWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
    private static func load(_ language: Language) -> BudouXModel? {
        BudouXModel(url: Bundle.main.resourceURL?.appendingPathComponent("TextLayout/\(language.rawValue).json"))
    }
}
