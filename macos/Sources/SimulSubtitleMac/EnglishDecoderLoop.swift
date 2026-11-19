import Foundation

/// A long tandem repeat inside one short ASR window. Ordinary refrains,
/// repeated opening words and short vocal interjections are left intact.
struct EnglishDecoderLoop {
    private let words: [Substring]
    private let phrase: [String]
    private let span: Range<Int>

    init?(_ text: String) {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= 16 else { return nil }
        let keys = words.map(Self.key)
        let interjections: Set<String> = ["oh", "ooh", "ah", "aah", "uh", "um", "hm", "hmm", "hey", "yeah", "la", "na", "ha", "whoa", "woo"]
        for start in keys.indices {
            let maxWidth = min(12, (keys.count - start) / 4)
            guard maxWidth >= 2 else { break }
            for width in 2...maxWidth {
                let phrase = Array(keys[start..<(start + width)])
                guard !phrase.contains(""), Set(phrase).count >= 2,
                      phrase.contains(where: { !interjections.contains($0) }) else { continue }
                var end = start + width
                while end < keys.count, keys[end] == phrase[(end-start) % width] { end += 1 }
                let spanLength = end - start
                guard spanLength >= max(16, width * 4) else { continue }
                // A partial copy before unrelated words may be the onset of a
                // real new line. Only remove it when the decoder ended inside it.
                if end < keys.count { end -= spanLength % width }
                self.words = words
                self.phrase = phrase
                self.span = start..<end
                return
            }
        }
        return nil
    }

    private static func key(_ word: Substring) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    private func occurrences(in text: String) -> Int {
        let keys = text.split(whereSeparator: { $0.isWhitespace }).map(Self.key)
        var index = 0
        var matches = 0
        while index + phrase.count <= keys.count {
            if keys[index..<(index + phrase.count)].elementsEqual(phrase) {
                matches += 1
                index += phrase.count
            } else { index += 1 }
        }
        return matches
    }

    /// Hypotheses with the loop are never their own confirmation. Adjacent,
    /// nonoverlapping halves can confirm two sung repetitions without doubling
    /// a phrase heard in two overlapping views of the same audio.
    func repaired(prior: String, left: String = "", right: String = "") -> String {
        let halves = [left, right].map { Self($0) == nil ? $0 : "" }.joined(separator: " ")
        let priorCount = Self(prior) == nil ? occurrences(in: prior) : 0
        let verified = max(priorCount, occurrences(in: halves))
        let copies = min(span.count / phrase.count, max(1, verified))
        let keepEnd = span.lowerBound + copies * phrase.count
        return (Array(words[..<keepEnd]) + words[span.upperBound...]).joined(separator: " ")
    }
}
