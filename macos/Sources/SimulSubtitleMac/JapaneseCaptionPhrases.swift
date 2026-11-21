import Foundation
import NaturalLanguage

struct TimedCaptionPhrase: Equatable {
    let text: String
    let start: Double
    let end: Double
}

enum JapaneseCaptionPhrase {
    private static let dependentWords: Set<String> = ["は", "が", "を", "に", "で", "へ", "と", "の", "も", "から", "まで", "より", "だけ", "こそ", "さえ", "ほど", "て", "た", "だっ", "ます", "まし", "です", "ない", "なかっ", "られ", "れる", "たい"]
    private static let openWords: Set<String> = ["は", "が", "を", "の", "その", "この", "あの", "どの", "だっ", "まし", "なかっ"]

    /// Only the possessive form after a noun and a bound location phrase.
    /// A conversational sentence-ending の after a verb or adjective stays separate.
    static func completesLocation(_ left: String, _ right: String) -> Bool {
        guard left.range(of: #"[一-龯ァ-ヶー]の$"#, options: .regularExpression) != nil else { return false }
        return right.range(of: #"^(?:上|下|中|横|裏|前|後ろ|奥|隣|手前|向こう|外|内側|反対側)(?:で|に|の|から|へ|を|が|だ)"#,
                           options: .regularExpression) != nil
    }

    /// Drafts keep their short display budget. A Chinese final can use a few
    /// extra morae to finish its clause before it is translated and committed.
    static func split(_ speech: RecognizedSpeech, duration: Double, forTranslation: Bool = false) -> [TimedCaptionPhrase] {
        let tokens = speech.tokens
        guard !speech.text.isEmpty else { return [] }
        let single = [TimedCaptionPhrase(text: speech.text, start: 0, end: duration)]
        guard tokens.count > 1, duration > 0, tokens.map(\.text).joined() == speech.text,
              tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < duration }),
              zip(tokens, tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return single }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = speech.text
        tokenizer.setLanguage(.japanese)
        var wordAtStart: [Int: String] = [:], wordAtEnd: [Int: String] = [:]
        tokenizer.enumerateTokens(in: speech.text.startIndex..<speech.text.endIndex) { range, _ in
            let word = String(speech.text[range])
            let start = speech.text.distance(from: speech.text.startIndex, to: range.lowerBound)
            wordAtStart[start] = word
            wordAtEnd[start + word.count] = word
            return true
        }
        var lengths = [0]
        for token in tokens { lengths.append(lengths.last! + token.text.count) }
        let ends = tokens.indices.dropFirst().filter { cursor in
            wordAtEnd[lengths[cursor]] != nil || tokens[cursor - 1].text.last.map { "。！？、".contains($0) } == true
        } + [tokens.count]
        var times = tokens.map(\.time)
        // Reazon can put the first subword at the head of a long instrumental
        // intro. Its next mora in the same lexical word is a closer onset anchor.
        if times[0] <= 0.08, wordAtEnd[lengths[1]] == nil, times[1] - times[0] > 1.4 {
            times[0] = max(0, times[1] - 0.35)
        }
        let limit = forTranslation ? 8.8 : 6.7
        let characterLimit = forTranslation ? 29 : 22
        var lines: [TimedCaptionPhrase] = []
        var first = 0
        while first < tokens.count {
            let begin = first == 0 && times[first] < 0.8 ? 0 : times[first]
            var bestEnd = first, bestScore = -Double.infinity
            for cursor in ends where cursor > first {
                let last = times[cursor - 1]
                let next = cursor == tokens.count ? duration : times[cursor]
                let span = min(next, last + 0.95) - begin
                let count = lengths[cursor] - lengths[first]
                // A single indivisible word can exceed the normal budget.
                if bestEnd > first && (span > limit || count > characterLimit) { break }
                if cursor == tokens.count { bestEnd = cursor; break }
                let left = wordAtEnd[lengths[cursor]] ?? ""
                let right = wordAtStart[lengths[cursor]] ?? ""
                let punctuation = tokens[cursor - 1].text.last.map { "。！？、".contains($0) } == true
                let gap = next - last
                if punctuation || (gap > 1.4 && !dependentWords.contains(right)) {
                    bestEnd = cursor; break
                }
                let target = forTranslation ? 6.4 : 5.2
                var score = min(gap, 1.3) * 2 - abs(span - target) * 0.65
                if count < 4 { score -= 4 }
                if dependentWords.contains(right) { score -= 6 }
                if openWords.contains(left) { score -= 3 }
                if forTranslation {
                    if ["です", "ます", "た", "よ", "ね", "けど", "けれど", "から"].contains(left) { score += 1.4 }
                    if ["その", "この", "あの"].contains(right) && gap < 0.65 { score -= 1.6 }
                }
                if score > bestScore { bestScore = score; bestEnd = cursor }
            }
            guard bestEnd > first else { return single }
            let next = bestEnd == tokens.count ? duration : times[bestEnd]
            let finish = min(next, times[bestEnd - 1] + 0.95)
            guard finish > begin else { return single }
            lines.append(TimedCaptionPhrase(text: tokens[first..<bestEnd].map(\.text).joined(), start: begin, end: finish))
            first = bestEnd
        }
        return lines
    }
}
