import Foundation

extension ClipJapaneseGapDetector {
    struct ShortReactionAudio {
        var original: String
        var samples: [Float]
        var tight: Range<Int>
    }

    static func alignedShortUtterance(_ phrase: TimedCaptionPhrase, first: [[RecognizedSpeech.Token]],
                                      other: [[RecognizedSpeech.Token]]) -> Bool {
        guard (0.25...1.35).contains(phrase.end - phrase.start),
              phrase.text.range(of: #"^[ぁ-んー]{3,5}$"#, options: .regularExpression) != nil,
              let group = first.first(where: { $0.first?.time == phrase.start && $0.map(\.text).joined() == phrase.text }) else { return false }
        return other.contains { copy in
            copy.count == group.count && zip(group, copy).allSatisfy { $0.text == $1.text && abs($0.time - $1.time) <= 0.10 }
        }
    }

    static func shortConflict(_ candidate: Caption, primary: [Caption]) -> Bool {
        let overlaps = primary.filter { $0.start < candidate.end && candidate.start < $0.end }
        guard overlaps.count == 1, let original = overlaps.first, original.translated.isEmpty,
              original.original != candidate.original, original.original.prefix(2) == candidate.original.prefix(2),
              original.original.range(of: #"^[ぁ-んー]{3,6}$"#, options: .regularExpression) != nil,
              original.end - original.start <= 1.6, abs(original.start - candidate.start) <= 0.55,
              abs(original.end - candidate.end) <= 0.4 else { return false }
        return min(original.end, candidate.end) - max(original.start, candidate.start) >= 0.7 * (candidate.end - candidate.start)
    }

    struct DisputedReaction {
        var first: String
        var second: String
        var start: Double
        var end: Double

        func confirmed(by decoded: String) -> String? {
            let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.hesitation(first, second) { return ["えと", "えっと"].contains(text) ? text : nil }
            return text == first || text == second ? text : nil
        }

        // Some contexts hear just the onset of a hesitation. A second model
        // must hear the whole word, including its final mora.
        static func hesitation(_ a: String, _ b: String) -> Bool {
            a == "え" && ["えと", "えっと"].contains(b) || b == "え" && ["えと", "えっと"].contains(a)
        }
    }

    static func disputedReactions(_ first: [[RecognizedSpeech.Token]], _ second: [[RecognizedSpeech.Token]],
                                 owned: Range<Double>, end: Double) -> [DisputedReaction] {
        var results: [DisputedReaction] = []
        for a in first {
            guard let begin = a.first?.time, owned.contains(begin), a.count <= 8 else { continue }
            let text = a.map(\.text).joined()
            for b in second {
                guard let other = b.first, b.count <= 8, abs(other.time - begin) <= 0.10 else { continue }
                let alternate = b.map(\.text).joined()
                guard text != alternate,
                      [text, alternate].allSatisfy({ $0.range(of: #"^[ぁ-んァ-ヶ一-龯ー]{1,8}$"#, options: .regularExpression) != nil }) else { continue }
                if !DisputedReaction.hesitation(text, alternate) {
                    // Keep both complete utterances, including the times of
                    // every non-geminate token. Never guess a spelling here.
                    let left = a.filter { $0.text != "っ" }, right = b.filter { $0.text != "っ" }
                    guard a.count + b.count - left.count - right.count == 1,
                          left.count >= 2, left.count == right.count, zip(left, right).allSatisfy({
                              $0.text == $1.text && abs($0.time - $1.time) <= 0.10
                          }) else { continue }
                }
                let finish = min(end, max(a.last!.time, b.last!.time) + 0.30)
                guard finish > begin else { continue }
                results.append(.init(first: text, second: alternate, start: begin, end: finish))
            }
        }
        return results
    }

    /// A primary filler can inherit the beginning of a whole VAD segment. Move
    /// its edge only to its own acoustic anchor when it blocks a separate phrase.
    static func anchoredReaction(_ cue: Caption, verified: [Caption]) -> Caption {
        guard cue.translated.isEmpty, (reactions.contains(cue.original) || cue.original == "えっと") else { return cue }
        let anchors = verified.filter { $0.original == cue.original && $0.start < cue.end && cue.start < $0.end }
        guard anchors.count == 1, let anchor = anchors.first else { return cue }
        var result = cue
        for neighbor in verified where neighbor.id != anchor.id && neighbor.original != cue.original {
            if neighbor.start < cue.end, cue.start < neighbor.end, neighbor.end + 0.10 <= anchor.start {
                result.start = max(result.start, anchor.start)
            }
            if neighbor.start < cue.end, cue.start < neighbor.end, anchor.end + 0.10 <= neighbor.start {
                result.end = min(result.end, anchor.end)
            }
        }
        return result.end > result.start ? result : cue
    }
}
