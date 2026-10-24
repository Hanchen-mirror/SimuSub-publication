import Foundation

/// Local agreement between two growing hypotheses, with a two-character tail
/// held back. Confirmation is provisional: full-utterance ASR can correct it.
struct StablePrefixConfirmation {
    private var previous = ""
    private var previousSamples = 0
    private(set) var offered = false
    mutating func observe(_ text: String, samples: Int) -> String? {
        defer { previous = text; previousSamples = samples }
        guard !offered, samples > previousSamples, !previous.isEmpty else { return nil }
        let common = String(zip(previous, text).prefix { $0 == $1 }.map { $0.0 })
        let safe = String(common.dropLast(2))
        // Commit only a complete-looking clause, never a bare proper name or a
        // trailing verb stem. At most one speculative request per utterance.
        let endings = ["。", "！", "？", "でした", "ました", "ません", "ですね", "ですよね", "ます", "です", "だよ", "だね", "なんだ", "けど", "もんね", "んだよ", "かった", "てる", "だって", "だから", "のかな", "じゃない"]
        var boundary: String.Index?
        for ending in endings {
            if let range = safe.range(of: ending, options: .backwards),
               safe.distance(from: safe.startIndex, to: range.upperBound) >= 10,
               boundary == nil || range.upperBound > boundary! { boundary = range.upperBound }
        }
        guard let boundary else { return nil }
        offered = true
        return String(safe[..<boundary])
    }
}

/// ReazonSpeech's token table is character-based. Unsupported words are skipped
/// explicitly; never let unknown symbols reach the native hotword parser.
struct ASRHotwordPlan {
    let accepted: [String]
    let rejected: [String]
    init(words: [String], tokenTable: String) {
        let symbols = Set(tokenTable.components(separatedBy: .newlines).compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, fields[1] != "0", !fields[0].hasPrefix("<") else { return nil }
            return String(fields[0])
        })
        var accepted: [String] = [], rejected: [String] = [], seen = Set<String>()
        for raw in words.prefix(100) {
            let word = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(word).inserted else { continue }
            if word.count >= 2 && word.count <= 40 && !word.contains(":") && word.allSatisfy({ symbols.contains(String($0)) }) {
                accepted.append(word)
            } else { rejected.append(raw) }
        }
        self.accepted = accepted; self.rejected = rejected
    }
}
