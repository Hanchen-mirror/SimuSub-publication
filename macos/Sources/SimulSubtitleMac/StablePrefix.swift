import Foundation
import NaturalLanguage

/// Local agreement between two growing hypotheses, with a two-character tail
/// held back. Confirmation is provisional: full-utterance ASR can correct it.
struct StablePrefixConfirmation {
    private var previous = ""
    private var previousSamples = 0
    private(set) var offered = false
    private var lastEnglishPrefix = ""
    private var lastEnglishSamples = 0

    mutating func observe(_ text: String, samples: Int, englishClauses: Bool = false) -> String? {
        defer { previous = text; previousSamples = samples }
        guard samples > previousSamples, !previous.isEmpty else { return nil }
        let common = String(zip(previous, text).prefix { $0 == $1 }.map { $0.0 })
        if englishClauses {
            // Coalesce quicker revisions, without limiting a long turn to its first clauses.
            guard !common.isEmpty,
                  lastEnglishPrefix.isEmpty || samples - lastEnglishSamples >= 32_000,
                  let prefix = Self.englishClause(in: text, agreementCount: common.count),
                  prefix != lastEnglishPrefix else { return nil }
            if prefix.hasPrefix(lastEnglishPrefix), !lastEnglishPrefix.isEmpty,
               prefix.dropFirst(lastEnglishPrefix.count).split(whereSeparator: \.isWhitespace).count < 3 { return nil }
            lastEnglishSamples = samples
            lastEnglishPrefix = prefix
            return prefix
        }
        guard !offered else { return nil }
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

    // A sentence terminator can stand alone. A coordinating conjunction is
    // only a clue: require a separate subject and predicate on its right.
    private static func englishClause(in text: String, agreementCount: Int) -> String? {
        let agreement = text.index(text.startIndex, offsetBy: agreementCount)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        tagger.setLanguage(.english, range: range)
        let tokens = tagger.tags(in: range, unit: .word, scheme: .lexicalClass,
                                 options: [.omitWhitespace, .joinContractions])
        var best: String.Index?
        var clauseStart = 0
        var hasVerb = false
        for (i, token) in tokens.enumerated() {
            let (tag, span) = token
            guard span.upperBound <= agreement else { break }
            let word = text[span].lowercased()
            if tag == .verb { hasVerb = true }
            guard hasVerb, i - clauseStart >= 3 else { continue }
            if tag == .sentenceTerminator || word == ";" {
                let tail = text[tokens[i - 1].1].lowercased()
                guard !["not", "never", "without", "to", "if", "because", "although", "whether", "but", "and", "or", "the", "a", "an"].contains(tail) else { continue }
                best = span.upperBound
                clauseStart = i + 1
                hasVerb = false
            } else if tag == .conjunction, ["but", "yet", "and"].contains(word) {
                let right = tokens.dropFirst(i + 1).prefix(6).prefix {
                    $0.0 != .punctuation && $0.0 != .sentenceTerminator && $0.0 != .conjunction
                }
                guard let subject = right.first, [.pronoun, .noun, .determiner].contains(subject.0),
                      right.dropFirst().contains(where: { $0.0 == .verb })
                         || text[subject.1].range(of: #"['’](m|re|ll|ve|d|s)$"#, options: [.regularExpression, .caseInsensitive]) != nil
                else { continue }
                let left = text[tokens[clauseStart].1.lowerBound..<span.lowerBound].lowercased()
                let first = text[tokens[clauseStart].1].lowercased()
                guard !["if", "although", "unless", "whether", "because", "when", "while"].contains(first),
                      !left.contains("not only"), !left.contains("not just"),
                      !left.hasSuffix("anything "), !left.hasSuffix("nothing "),
                      !left.hasSuffix("all "), !left.hasSuffix("help ") else { continue }
                best = span.lowerBound
                clauseStart = i
                hasVerb = false
            }
        }
        return best.map { String(text[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
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
