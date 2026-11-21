import CoreFoundation
import Foundation

/// The main VAD can miss quiet Japanese speech over game audio. When the
/// optional timed recognizer is installed, recheck the original PCM in two
/// shifted windows. A word on just one decode never becomes a subtitle.
final class ClipJapaneseGapDetector {
    private let recognizer: any SpeechRecognizing
    private let origin: Double
    private let target: SubtitleLanguage
    private var pcm: [Float] = []
    private var base = 0, next = 0
    private var verified: [Caption] = []
    private var pending: [Caption] = []
    private var lastPrimaryStart: Double = 0
    private static let reactions: Set<String> = ["あ", "あっ", "え", "えっ", "おっ", "うん", "うわ", "あれ", "えと", "んで"]
    private static let rate = 16_000

    init(recognizer: any SpeechRecognizing, start: Double, target: SubtitleLanguage) {
        self.recognizer = recognizer; origin = start; self.target = target
    }

    private typealias Token = RecognizedSpeech.Token

    /// Split on acoustic pauses. In a sequence of spoken digits the shorter
    /// pause between repetitions separates code groups without inventing digits.
    private static func utterances(_ speech: RecognizedSpeech, offset: Double, duration: Double) -> [[Token]] {
        guard !speech.tokens.isEmpty, speech.tokens.map(\.text).joined() == speech.text,
              speech.tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time < duration }),
              zip(speech.tokens, speech.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return [] }
        var groups: [[Token]] = []
        var phrase: [Token] = []
        let tokens = speech.tokens.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (i, token) in tokens.enumerated() {
            let word = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.allSatisfy(\.isPunctuation) {
                let afterDigit = i > 0 && tokens[i - 1].text.trimmingCharacters(in: .whitespaces).last?.isNumber == true
                let beforeDigit = i + 1 < tokens.count && tokens[i + 1].text.trimmingCharacters(in: .whitespaces).first?.isNumber == true
                // The decoder can emit a numerical sign, decimal point, list
                // separator, or percentage as its own token. Never collapse
                // a numerical literal into another value when removing prose stops.
                let notation = afterDigit && beforeDigit || beforeDigit && "-−－+＋".contains(word)
                    || afterDigit && "%％‰‱".contains(word)
                if !notation { continue }
            }
            let time = token.time + offset
            if let previous = phrase.last {
                let digits = previous.text.allSatisfy(\.isNumber) && word.allSatisfy(\.isNumber)
                if time - previous.time > (digits ? 0.42 : 0.62) {
                    groups.append(phrase); phrase.removeAll(keepingCapacity: true)
                }
            }
            phrase.append(.init(text: word, time: time))
        }
        if !phrase.isEmpty { groups.append(phrase) }
        return groups
    }

    static func agreement(_ first: RecognizedSpeech, start: Double, duration: Double,
                          second: RecognizedSpeech, otherStart: Double, otherDuration: Double,
                          owned: Range<Double>, limit: Double, shortOnly: Bool = false) -> [TimedCaptionPhrase] {
        let wide = utterances(second, offset: otherStart, duration: otherDuration)
        let narrow = utterances(first, offset: start, duration: duration)
        var result: [TimedCaptionPhrase] = []
        for (index, group) in narrow.enumerated() {
            let onset = group[0].time, text = group.map(\.text).joined()
            let number = text.contains(where: \.isNumber) && text.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol }
            let eligible = shortOnly ? reactions.contains(text) : number || (text.count >= 3 && Set(text).count >= 2)
            guard owned.contains(onset), eligible,
                  // Mixed names and multi-digit identifiers need a primary ASR
                  // anchor. Two windows of one model can repeat a phonetic guess.
                  number || text.range(of: #"[0-9０-９]{2,}"#, options: .regularExpression) == nil,
                  wide.contains(where: { other in
                      other.count == group.count && zip(group, other).allSatisfy {
                          $0.text == $1.text && abs($0.time - $1.time) <= (shortOnly ? 0.10 : 0.26)
                      }
                  }) else { continue }
            let nextOnset = index + 1 < narrow.count ? narrow[index + 1][0].time : limit
            let end = min(limit, nextOnset, group.last!.time + 0.30)
            guard onset < end else { continue }
            let relative = group.map { Token(text: $0.text, time: $0.time - onset) }
            let phrases = JapaneseCaptionPhrase.split(.init(text: text, tokens: relative),
                                                      duration: end - onset, forTranslation: true)
            result += phrases.map { .init(text: $0.text, start: onset + $0.start, end: onset + $0.end) }
        }
        return result
    }

    func accept(_ samples: [Float], finished: Bool) async throws {
        let rate = Self.rate, core = 8 * rate, near = Int(3.2 * Double(rate)), far = Int(5.4 * Double(rate))
        pcm.append(contentsOf: samples)
        let available = base + pcm.count
        while next < available && (finished || next + core + far <= available) {
            try Task.checkCancellation()
            let end = min(available, next + core)
            let narrow = max(0, next - near)..<min(available, end + near)
            let wide = max(0, next - far)..<min(available, end + far)
            if narrow != wide {
                func slice(_ range: Range<Int>) -> ArraySlice<Float> {
                    pcm[(range.lowerBound - base)..<(range.upperBound - base)]
                }
                if slice(next..<end).contains(where: { abs($0) > 0.003 }) {
                    let first = try await recognizer.recognizeDetailed(samples: Array(slice(narrow)))
                    if !first.tokens.isEmpty {
                        let other = try await recognizer.recognizeDetailed(samples: Array(slice(wide)))
                        func seconds(_ count: Int) -> Double { Double(count) / Double(rate) }
                        let owned = (origin + seconds(next))..<(origin + seconds(end))
                        func compare(_ a: RecognizedSpeech, _ sourceA: Range<Int>, _ b: RecognizedSpeech, _ sourceB: Range<Int>, short: Bool = false) -> [TimedCaptionPhrase] {
                            Self.agreement(a, start: origin + seconds(sourceA.lowerBound), duration: seconds(sourceA.count),
                                second: b, otherStart: origin + seconds(sourceB.lowerBound), otherDuration: seconds(sourceB.count),
                                owned: owned, limit: origin + seconds(available), shortOnly: short)
                        }
                        var agreed = compare(first, narrow, other, wide)
                        let short = compare(first, narrow, other, wide, short: true)
                        if !short.isEmpty {
                            // A third decode is reserved for a plausible standalone
                            // reaction. Use different real context on both sides.
                            let thirdWindow = max(0, next - 24_320)..<min(available, end + 33_920)
                            if thirdWindow != narrow, thirdWindow != wide {
                                let third = try await recognizer.recognizeDetailed(samples: Array(slice(thirdWindow)))
                                let nearThird = compare(first, narrow, third, thirdWindow, short: true)
                                let wideThird = compare(other, wide, third, thirdWindow, short: true)
                                agreed += short.filter { cue in
                                    nearThird.contains(cue) && wideThird.contains { $0.text == cue.text && abs($0.start - cue.start) <= 0.10 }
                                }
                            }
                        }
                        verified += agreed.map { Caption(start: $0.start, end: $0.end, original: $0.text,
                                                        translated: $0.text.allSatisfy({ $0.isASCII && $0.isNumber }) ? $0.text : "",
                                                        sourceLanguage: .japanese, targetLanguage: target) }
                    }
                }
            }
            next = end
        }
        let discard = max(0, next - far - base)
        pcm.removeFirst(discard); base += discard
    }

    func take(_ primary: [Caption], completedStart: Double?, finished: Bool) -> [Caption] {
        pending += primary
        if let completedStart { lastPrimaryStart = max(lastPrimaryStart, completedStart) }
        // Main VAD windows can stay open for up to 24 s. Commit only where no
        // later primary result can overlap, including across audio read chunks.
        // Earlier primary segments are already closed when a later VAD segment
        // has been emitted. Release those captions without waiting a second chunk.
        let primaryThrough = max(lastPrimaryStart, origin + Double(base + pcm.count) / Double(Self.rate) - 26)
        var cutoff = finished ? Double.infinity : min(origin + Double(next) / Double(Self.rate), primaryThrough)
        let all = pending + verified
        while let start = all.filter({ $0.start < cutoff && cutoff < $0.end }).map(\.start).min() { cutoff = start }
        let main = pending.filter { $0.end <= cutoff }, reviewed = verified.filter { $0.end <= cutoff }
        pending.removeAll { $0.end <= cutoff }; verified.removeAll { $0.end <= cutoff }
        return Self.combine(primary: main, verified: reviewed)
    }

    // Reazon often spells Japanese verbs in kana. A candidate such as
    // 重さ覚えてない must keep the complete reading of おぼえてない before
    // it can supply the missing noun. Never equate two different kanji names.
    private static func containsOriginal(_ original: String, candidate: String) -> Bool {
        if candidate.count > original.count, candidate.contains(original) { return true }
        guard original.range(of: #"^[ぁ-んァ-ヶー]+$"#, options: .regularExpression) != nil,
              candidate.range(of: #"\p{Han}"#, options: .regularExpression) != nil else { return false }
        func reading(_ text: String) -> String? {
            let string = text as CFString
            guard let tokenizer = CFStringTokenizerCreate(nil, string, CFRangeMake(0, CFStringGetLength(string)),
                kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale) else { return nil }
            var result = ""
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                guard let word = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String else { return nil }
                result += word
            }
            return result.isEmpty ? nil : result
        }
        guard let before = reading(original), let after = reading(candidate) else { return false }
        return after.contains(before)
    }

    static func combine(primary: [Caption], verified: [Caption]) -> [Caption] {
        func overlap(_ a: Caption, _ b: Caption) -> Bool { a.start < b.end && b.start < a.end }
        let codes = verified.filter { $0.original.count >= 3 && $0.original.allSatisfy(\.isNumber) }
        func repeatedCode(_ cue: Caption) -> Bool {
            codes.contains { $0.id != cue.id && $0.original == cue.original && abs($0.start - cue.start) < 3 }
        }
        var retained = primary.filter { cue in
            // A recognizer can turn a repeated passcode into one large cardinal
            // number. Require a separately timed repetition and no currency/unit.
            if !cue.translated.isEmpty { return true }
            let normalized = cue.original.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.range(of: #"^[0-9０-９〇零一二三四五六七八九十百千万億兆]+$"#, options: .regularExpression) == nil
                || !codes.contains { overlap(cue, $0) && repeatedCode($0) }
        }
        for candidate in verified.sorted(by: { $0.start < $1.start }) {
            let conflicts = retained.indices.filter { overlap(retained[$0], candidate) }
            if conflicts.isEmpty { retained.append(candidate); continue }
            // Keep a complete existing cue unless the independently agreed
            // phrase includes all of it and adds genuinely omitted words.
            if conflicts.count == 1, let i = conflicts.first, retained[i].translated.isEmpty,
               retained[i].original.count >= 3, Self.containsOriginal(retained[i].original, candidate: candidate.original),
               candidate.start <= retained[i].start + 0.15, candidate.end >= retained[i].end - 0.15 {
                retained[i] = candidate
            }
        }
        return retained.sorted { $0.start < $1.start }
    }
}
