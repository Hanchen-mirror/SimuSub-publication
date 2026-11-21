import Foundation

/// Reazon occasionally keeps only the end of a long utterance. Revisit empty
/// media intervals, keeping the first pass intact wherever it already has cues.
enum ClipJapaneseRecovery {
    static func isBareNumber(_ text: String) -> Bool {
        text.range(of: #"^[〇零一二三四五六七八九十百千万億兆0-9０-９]+$"#, options: .regularExpression) != nil
    }

    // Preserve the number exactly as heard in both decodes. An unpadded
    // decode may additionally resolve a short preceding reaction.
    static func numericReaction(number: String, alternate: RecognizedSpeech, offset: Double) -> RecognizedSpeech? {
        guard isBareNumber(number), alternate.text.hasSuffix(number),
              ["え", "えっ", "あ", "あっ", "あれ", "お", "おっ", "うん", "えっと"].contains(String(alternate.text.dropLast(number.count))),
              !alternate.tokens.isEmpty, alternate.tokens.map(\.text).joined() == alternate.text else { return nil }
        return .init(text: alternate.text, tokens: alternate.tokens.map { .init(text: $0.text, time: $0.time + offset) })
    }

    static func fill(_ original: [TimedCaptionPhrase], samples: [Float], forTranslation: Bool,
                     recognize: ([Float]) async throws -> RecognizedSpeech) async throws -> [TimedCaptionPhrase] {
        let rate = 16_000
        let duration = Double(samples.count) / Double(rate)
        guard duration >= 10 else { return original }
        var additions: [TimedCaptionPhrase] = []
        var cursor = 0.0
        // The final iteration also checks the gap after the last caption.
        for index in 0...original.count {
            let next = index < original.count ? original[index].start : duration
            if next - cursor >= 3 {
                let first = Int((cursor * Double(rate)).rounded(.up))
                let last = min(samples.count, Int((next * Double(rate)).rounded(.down)))
                let count = Int(ceil(Double(last - first) / Double(9 * rate)))
                var lower = first
                for part in 1...count {
                    try Task.checkCancellation()
                    let target = first + (last - first) * part / count
                    let upper = part == count ? last : quietBoundary(near: target, limits: lower..<last, samples: samples)
                    let core = lower..<upper
                    // Change decoder boundaries by about 0.6 s on either side;
                    // only the unpadded core can contribute text to an empty interval.
                    let leadIn = Int((0.62 * Double(rate)).rounded())
                    let leadOut = Int((0.58 * Double(rate)).rounded())
                    let wide = max(0, lower - leadIn)..<min(samples.count, upper + leadOut)
                    if wide != core, samples[core].contains(where: { abs($0) > 0.003 }) {
                        let heard = try await recognize(Array(samples[core]))
                        try Task.checkCancellation()
                        if !heard.text.isEmpty, !heard.tokens.isEmpty {
                            let verified = try await recognize(Array(samples[wide]))
                            try Task.checkCancellation()
                            additions += corroborated(heard, verification: verified, core: core, wide: wide, forTranslation: forTranslation)
                        }
                    }
                    lower = upper
                }
            }
            if index < original.count { cursor = max(cursor, original[index].end) }
        }
        return (original + additions).sorted { $0.start < $1.start }
    }

    // Search for a sustained quiet boundary so a price or clause is less likely
    // to be split in the middle of a word. Never make a core shorter than 2 s.
    private static func quietBoundary(near target: Int, limits: Range<Int>, samples: [Float]) -> Int {
        let rate = 16_000
        let minimumCore = 2 * rate, searchRadius = Int(2.3 * Double(rate))
        let halfWindow = rate / 5  // Average 400 ms of energy around each possible cut.
        let first = max(limits.lowerBound + minimumCore, target - searchRadius)
        let last = min(limits.upperBound - minimumCore, target + searchRadius)
        guard first < last else { return target }
        var best = target, lowest = Double.infinity
        for sample in stride(from: first, through: last, by: rate / 50) {
            var power = 0.0
            for i in stride(from: sample - halfWindow, to: sample + halfWindow, by: 8) {
                power += Double(samples[i] * samples[i])
            }
            if power < lowest { best = sample; lowest = power }
        }
        return best
    }

    private static func corroborated(_ heard: RecognizedSpeech, verification: RecognizedSpeech, core: Range<Int>, wide: Range<Int>,
                                     forTranslation: Bool) -> [TimedCaptionPhrase] {
        let rate = 16_000.0, duration = Double(core.count) / rate
        func timed(_ speech: RecognizedSpeech, count: Int) -> RecognizedSpeech? {
            let end = Double(count) / rate
            // The local recognizer pads audio by 300 ms. Its last timestamp can
            // land a few milliseconds in that pad; the actual cue ends at audio end.
            guard !speech.tokens.isEmpty, speech.tokens.map(\.text).joined() == speech.text,
                  speech.tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= end + 0.3 }),
                  zip(speech.tokens, speech.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return nil }
            var value = speech
            value.tokens = speech.tokens.map { .init(text: $0.text, time: min($0.time, end - 1 / rate)) }
            return value
        }
        guard let heard = timed(heard, count: core.count), let verification = timed(verification, count: wide.count) else { return [] }
        let shift = Double(core.lowerBound - wide.lowerBound) / rate
        var cursor = verification.tokens.startIndex
        var matches: [Int: Int] = [:]
        for (i, token) in heard.tokens.enumerated() {
            if let j = verification.tokens[cursor...].firstIndex(where: {
                $0.text == token.text && abs($0.time - shift - token.time) <= 0.36
            }) {
                matches[i] = j
                cursor = j + 1
            }
        }
        // Reazon can pin the first token to zero in both windows. The same
        // first subword plus two consecutive timed anchors identifies that onset.
        if heard.tokens[0].time == 0, verification.tokens[0].time == 0,
           heard.tokens[0].text == verification.tokens[0].text, matches[1] == 1, matches[2] == 2 {
            matches[0] = 0
        }
        let offset = Double(core.lowerBound) / rate
        var index = 0
        return JapaneseCaptionPhrase.split(heard, duration: duration, forTranslation: forTranslation).compactMap { phrase in
            let start = index
            var characters = 0
            while index < heard.tokens.count, characters < phrase.text.count {
                characters += heard.tokens[index].text.count
                index += 1
            }
            let agreed = (start..<index).filter { matches[$0] != nil }
            guard agreed.count >= 3, agreed.count * 3 >= (index - start) * 2,
                  Set(agreed.map { heard.tokens[$0].text }).count >= 2 else { return nil }
            return TimedCaptionPhrase(text: phrase.text, start: offset + phrase.start, end: offset + phrase.end)
        }
    }
}
