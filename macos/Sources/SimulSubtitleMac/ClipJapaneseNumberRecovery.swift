import Foundation

/// Recovers explicitly spoken digits with timestamps from two real CTC decodes.
/// A surrounding sentence may differ between decodes. Units and phonetic
/// lookalikes are never stripped from a number to manufacture agreement.
enum ClipJapaneseNumberRecovery {
    private typealias Token = RecognizedSpeech.Token
    struct Group {
        fileprivate let digits: [RecognizedSpeech.Token]
        var text: String { digits.map(\.text).joined() }
        var start: Double { digits[0].time }
    }

    // A wider acoustic context can append an extra digit. Prefer the reading
    // from the VAD span only if two timed CTC decodes independently support it.
    static func confirmsOriginalNumber(_ original: String, insteadOf cue: Caption, verified: [Caption]) -> Bool {
        guard cue.translated.isEmpty, ClipJapaneseRecovery.isBareNumber(cue.original),
              ClipJapaneseRecovery.isBareNumber(original) else { return false }
        let format = NumberFormatter()
        format.locale = Locale(identifier: "ja_JP")
        format.numberStyle = .spellOut
        func digits(_ text: String) -> String? {
            let value = text.precomposedStringWithCompatibilityMapping
            if value.allSatisfy({ $0.isASCII && $0.isNumber }) { return value }
            guard let parsed = format.number(from: value), format.string(from: parsed) == value else { return nil }
            return parsed.stringValue
        }
        guard let expected = digits(original), let expanded = digits(cue.original), expected != expanded else { return false }
        let overlaps = verified.filter { $0.start < cue.end && cue.start < $0.end }
        return !overlaps.isEmpty && overlaps.allSatisfy {
            $0.original == expected && $0.start >= cue.start - 0.13 && $0.end <= cue.end + 0.13
        }
    }

    private static let ideographs = Array("〇一二三四五六七八九")
    private static func digit(_ text: String) -> String? {
        guard text.count == 1, let c = text.first else { return nil }
        if c == "零" { return "0" }
        if let n = ideographs.firstIndex(of: c) { return String(n) }
        if ("0"..."9").contains(text) || ("０"..."９").contains(text), let n = c.wholeNumberValue { return String(n) }
        return nil
    }

    // A decimal, date, signed amount, measure or identifier must retain its
    // complete spelling. Also avoid cutting an Arabic prefix from a kanji number.
    private static let notation = CharacterSet(charactersIn: ".．,，:：/／-−－+＋%％‰¥￥$€£°℃0123456789０１２３４５６７８９〇一二三四五六七八九零十百千万億兆円年月日時分秒個人本枚回匹号番台点階歳倍割章組隊式型代部期位キロメートルグラム")
    private static func isAttachedNotation(_ text: String, before: Bool) -> Bool {
        guard let c = before ? text.unicodeScalars.last : text.unicodeScalars.first else { return false }
        return notation.contains(c) || (c.isASCII && CharacterSet.letters.contains(c))
    }

    private static func groups(_ speech: RecognizedSpeech, start: Double, duration: Double) -> [Group] {
        guard speech.tokens.map(\.text).joined() == speech.text, !speech.tokens.isEmpty,
              speech.tokens.allSatisfy({ !$0.text.isEmpty && $0.time.isFinite && $0.time >= 0 && $0.time < duration }),
              zip(speech.tokens, speech.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return [] }
        let tokens = speech.tokens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [Group] = []
        var index = 0
        while index < tokens.count {
            guard digit(tokens[index].text) != nil else { index += 1; continue }
            let first = index
            var digits: [Token] = []
            while index < tokens.count, let value = digit(tokens[index].text),
                  index == first || tokens[index].time - tokens[index - 1].time <= 1.0 {
                digits.append(Token(text: value, time: start + tokens[index].time))
                index += 1
            }
            let previous = first > 0 ? tokens[first - 1] : nil
            let next = index < tokens.count ? tokens[index] : nil
            let precedingGap = tokens[first].time - (previous?.time ?? 0)
            let followingGap = (next?.time ?? duration) - tokens[index - 1].time
            if let previous, precedingGap < 0.75, isAttachedNotation(previous.text, before: true) { continue }
            if let next, followingGap < 0.75, isAttachedNotation(next.text, before: false) { continue }
            if digits.count == 1 {
                // Accept a single digit only when acoustically isolated on both
                // sides. Do not extract a tail from prose even if both windows
                // produce the same tail.
                if precedingGap >= 0.65 && followingGap >= 0.65 { result.append(.init(digits: digits)) }
                continue
            }
            // A quiet break may separate confidently spoken groups even if a
            // later group is only partially heard. Match each full group across
            // both windows; never complete a missing digit from a neighboring copy.
            let priorGroupCount = result.count
            var groupStart = 0
            for k in 1...digits.count {
                if k < digits.count && digits[k].time - digits[k - 1].time < 0.45 { continue }
                let group = Array(digits[groupStart..<k])
                let hasStart = groupStart > 0 || precedingGap >= 0.45
                let hasEnd = k < digits.count || followingGap >= 0.45
                if hasStart && hasEnd && (3...8).contains(group.count) {
                    result.append(.init(digits: group))
                }
                groupStart = k
            }
            // The same string can be a single ID or repeated spoken groups.
            // Require distinguishable intra-group and inter-group pauses in
            // both decodes before introducing a group boundary.
            guard digits.count >= 4, digits.count <= 96 else { continue }
            for count in 2...min(8, digits.count / 2) where digits.count.isMultiple(of: count) {
                let pattern = digits.prefix(count).map(\.text)
                guard Set(pattern).count > 1,
                      digits.indices.allSatisfy({ digits[$0].text == pattern[$0 % count] }) else { continue }
                var within: [Double] = [], between: [Double] = []
                for k in 1..<digits.count {
                    let pause = digits[k].time - digits[k - 1].time
                    if k.isMultiple(of: count) { between.append(pause) } else { within.append(pause) }
                }
                let ordinary = within.sorted()[within.count / 2]
                guard between.allSatisfy({ $0 >= 0.40 && $0 >= ordinary + 0.05 }) else { continue }
                result.removeLast(result.count - priorGroupCount)
                for k in stride(from: 0, to: digits.count, by: count) {
                    result.append(.init(digits: Array(digits[k..<k + count])))
                }
                break
            }
        }
        return result
    }

    /// A third decode is worthwhile only if one full group and both acoustic
    /// endpoints are already present, with exactly one internal digit missing
    /// from the other hypothesis. A substitution or a discrepant endpoint
    /// cannot trigger another chance at a preferred reading.
    static func disputedGroups(_ first: RecognizedSpeech, start: Double, duration: Double,
                           second: RecognizedSpeech, otherStart: Double, otherDuration: Double,
                           owned: Range<Double>) -> [Group] {
        func missingInterior(_ candidates: [Group], in speech: RecognizedSpeech, offset: Double) -> [Group] {
            guard speech.tokens.map(\.text).joined() == speech.text,
                  speech.tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 }),
                  zip(speech.tokens, speech.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return [] }
            return candidates.filter { group in
                guard owned.contains(group.start), group.digits.count >= 3 else { return false }
                let last = group.digits.last!.time
                let slice = speech.tokens.filter {
                    (group.start - 0.13...last + 0.13).contains(offset + $0.time)
                        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard slice.count == group.digits.count - 1 else { return false }
                for missing in 1..<(group.digits.count - 1) {
                    var expected = group.digits
                    expected.remove(at: missing)
                    if zip(slice, expected).allSatisfy({ raw, original in
                        digit(raw.text) == original.text && abs(offset + raw.time - original.time) <= 0.13
                    }) { return true }
                }
                return false
            }
        }
        return missingInterior(groups(first, start: start, duration: duration), in: second, offset: otherStart)
            + missingInterior(groups(second, start: otherStart, duration: otherDuration), in: first, offset: start)
    }

    static func agreement(_ first: RecognizedSpeech, start: Double, duration: Double,
                          second: RecognizedSpeech, otherStart: Double, otherDuration: Double,
                          owned: Range<Double>, limit: Double) -> [TimedCaptionPhrase] {
        let candidates = groups(first, start: start, duration: duration)
        return corroborate(candidates, with: second, start: otherStart, duration: otherDuration, owned: owned, limit: limit)
    }

    static func corroborate(_ candidates: [Group], with speech: RecognizedSpeech, start: Double, duration: Double,
                            owned: Range<Double>, limit: Double) -> [TimedCaptionPhrase] {
        let corroboration = groups(speech, start: start, duration: duration)
        return candidates.compactMap { candidate in
            guard owned.contains(candidate.start),
                  corroboration.contains(where: { other in
                      other.text == candidate.text && zip(other.digits, candidate.digits).allSatisfy { abs($0.time - $1.time) <= 0.13 }
                  }) else { return nil }
            let end = min(limit, candidate.digits.last!.time + 0.30)
            guard end > candidate.start else { return nil }
            return TimedCaptionPhrase(text: candidate.text, start: candidate.start, end: end)
        }
    }
}
