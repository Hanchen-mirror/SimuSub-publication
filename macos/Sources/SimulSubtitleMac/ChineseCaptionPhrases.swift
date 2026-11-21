import Foundation
import NaturalLanguage

enum ChineseCaptionPhrases {
    private static let sentenceEnds = Set("。！？!?；;")
    private static let trailingMarks = Set("。！？!?；;….”’」』）》】")
    private static let connectors = ["但是", "然后", "然後", "不过", "不過", "所以", "因为", "因為", "接下来", "接下來", "我们再", "我們再", "最后", "最後", "接着", "接著"]
    private static let budget = 24
    // NLTokenizer may split an identifier before a digit or a date after its year.
    private static let indivisible = try! NSRegularExpression(
        pattern: #"[0-9０-９]{2,4}年(?:[0-9０-９]{1,2}月(?:[0-9０-９]{1,2}[日号號])?)?|[A-Za-z0-9０-９]+(?:[._-][A-Za-z0-9０-９]+)*(?:公里|厘米|毫米|公斤|千克|分钟|分鐘|小时|小時|[年月日号號米秒元%％])?"#)

    static func split(_ speech: RecognizedSpeech, duration: Double, language: SubtitleLanguage) -> [TimedCaptionPhrase] {
        let text = speech.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, duration.isFinite, duration > 0 else { return [] }
        let chars = Array(text)
        var protectedCuts = Set<Int>()
        let indices = Array(text.indices) + [text.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        for match in indivisible.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let range = Range(match.range, in: text), let lower = offsets[range.lowerBound], let upper = offsets[range.upperBound] {
                protectedCuts.formUnion((lower + 1)..<upper)
            }
        }
        var times: [Int: Double] = [:]
        var pauses = Set<Int>()
        if text == speech.text, speech.tokens.map(\.text).joined() == text,
           speech.tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < duration && !$0.text.isEmpty }),
           zip(speech.tokens, speech.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) {
            var offset = 0
            for (index, token) in speech.tokens.enumerated() {
                if index > 0 {
                    let previous = speech.tokens[index - 1]
                    if token.time - previous.time > 0.8 + Double(previous.text.count) * 0.2 { pauses.insert(offset) }
                }
                times[offset] = token.time
                offset += token.text.count
            }
        }
        var sentenceEndsAt: [Int] = []
        var cursor = 0
        while cursor < chars.count {
            let c = chars[cursor]
            cursor += 1
            let period = c == "." && (cursor == chars.count || chars[cursor].isWhitespace || !chars[cursor].isASCII)
            let pause = pauses.contains(cursor) && !protectedCuts.contains(cursor) && cursor - (sentenceEndsAt.last ?? 0) >= 4 && chars.count - cursor >= 4
                && !"的地得着著了嗎吗，、。！？".contains(chars[cursor])
            if sentenceEnds.contains(c) || period || c.isNewline || pause {
                while cursor < chars.count && (trailingMarks.contains(chars[cursor]) || chars[cursor].isWhitespace) {
                    cursor += 1
                }
                sentenceEndsAt.append(cursor)
            }
        }
        if sentenceEndsAt.last != chars.count { sentenceEndsAt.append(chars.count) }

        var wordStarts = Set<Int>()
        if chars.count > budget {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.setLanguage(language == .traditionalChinese ? .traditionalChinese : .simplifiedChinese)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if let n = offsets[range.lowerBound], !protectedCuts.contains(n) { wordStarts.insert(n) }
                return true
            }
        }
        var cuts = [0]
        for end in sentenceEndsAt {
            var first = cuts.last!
            while end - first > budget {
                // Leave room on both sides. Prefer a clause boundary, then a
                // discourse marker, then a word boundary near reading length.
                let limit = min(first + budget, end - 5)
                let candidates = (first + 5...limit).filter { i in
                    wordStarts.contains(i) && !trailingMarks.contains(chars[i]) && !"，、,:：".contains(chars[i])
                }
                let ideal = min(18, (end - first + 1) / 2)
                func score(_ i: Int) -> Int {
                    let punctuation = "，、,:：".contains(chars[i - 1])
                    let connector = connectors.contains { text[indices[i]...].hasPrefix($0) }
                    return (punctuation ? 32 : connector ? 20 : 0) - abs(i - first - ideal)
                }
                // Keep a long indivisible Latin name or number together.
                guard let cut = candidates.max(by: { score($0) < score($1) })
                    ?? wordStarts.filter({ $0 > limit && $0 < end }).min() else { break }
                cuts.append(cut)
                first = cut
            }
            cuts.append(end)
        }
        // Some cloud recognizers return text only. Estimate interior boundaries
        // within the VAD window when the decoded tokens do not align exactly.
        func boundary(_ i: Int) -> Double { duration * Double(i) / Double(chars.count) }
        var edges = cuts.map { times[$0] ?? boundary($0) }
        edges[0] = 0
        edges[edges.count - 1] = duration
        if !zip(edges, edges.dropFirst()).allSatisfy({ $0.isFinite && $0 < $1 }) {
            edges = cuts.map(boundary)
        }
        return cuts.indices.dropLast().compactMap { i in
            let phrase = text[indices[cuts[i]]..<indices[cuts[i + 1]]].trimmingCharacters(in: .whitespacesAndNewlines)
            return phrase.isEmpty ? nil : TimedCaptionPhrase(text: phrase, start: edges[i], end: edges[i + 1])
        }
    }
}
