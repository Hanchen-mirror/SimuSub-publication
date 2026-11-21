import CoreFoundation
import Foundation

/// The main VAD can miss quiet Japanese speech over game audio. When the
/// optional timed recognizer is installed, recheck the original PCM in two
/// shifted windows. A word on just one decode never becomes a subtitle.
final class ClipJapaneseGapDetector {
    private let recognizer: any SpeechRecognizing
    private let independent: (any SpeechRecognizing)?
    private var confirmedHesitations: Set<UUID> = []
    private var shortAudio: [UUID: ShortReactionAudio] = [:]
    private let origin: Double
    private let target: SubtitleLanguage
    private var pcm: [Float] = []
    private var base = 0, next = 0
    private var verified: [Caption] = []
    private var pending: [Caption] = []
    private var pendingNumberReadings: [UUID: String] = [:]
    private var lastPrimaryStart: Double = 0
    static let reactions: Set<String> = ["あ", "あっ", "え", "えっ", "おっ", "うん", "うわ", "あれ", "えと", "んで"]
    private static let rate = 16_000

    init(recognizer: any SpeechRecognizing, start: Double, target: SubtitleLanguage, independent: (any SpeechRecognizing)? = nil) {
        self.independent = independent
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
                    func seconds(_ count: Int) -> Double { Double(count) / Double(rate) }
                    let owned = (origin + seconds(next))..<(origin + seconds(end))
                    let narrowStart = origin + seconds(narrow.lowerBound)
                    // All verification paths require a first-window token in this core.
                    // Speech entirely in the neighboring context cannot add a cue.
                    if first.tokens.contains(where: { owned.contains(narrowStart + $0.time) }) {
                        let other = try await recognizer.recognizeDetailed(samples: Array(slice(wide)))
                        func compare(_ a: RecognizedSpeech, _ sourceA: Range<Int>, _ b: RecognizedSpeech, _ sourceB: Range<Int>, short: Bool = false) -> [TimedCaptionPhrase] {
                            Self.agreement(a, start: origin + seconds(sourceA.lowerBound), duration: seconds(sourceA.count),
                                second: b, otherStart: origin + seconds(sourceB.lowerBound), otherDuration: seconds(sourceB.count),
                                owned: owned, limit: origin + seconds(available), shortOnly: short)
                        }
                        var agreed = compare(first, narrow, other, wide)
                        var shortSamples: [Double: ShortReactionAudio] = [:]
                        if let independent {
                            let firstGroups = Self.utterances(first, offset: origin + seconds(narrow.lowerBound), duration: seconds(narrow.count))
                            let otherGroups = Self.utterances(other, offset: origin + seconds(wide.lowerBound), duration: seconds(wide.count))
                            // Hold only small original excerpts until the main decoder
                            // has committed its overlapping cue. Most require no replay.
                            for phrase in agreed where Self.alignedShortUtterance(phrase, first: firstGroups, other: otherGroups) {
                                func sample(_ time: Double) -> Int { Int(((time - origin) * Double(rate)).rounded()) }
                                let low = max(base, sample(phrase.start - 0.50)), high = min(available, sample(phrase.end + 0.55))
                                let tightStart = max(low, sample(phrase.start - 0.18)), tightEnd = min(high, sample(phrase.end + 0.24))
                                if low < tightStart, tightStart < tightEnd, tightEnd < high {
                                    shortSamples[phrase.start] = .init(original: phrase.text, samples: Array(slice(low..<high)),
                                                                      tight: (tightStart-low)..<(tightEnd-low))
                                }
                            }
                            let disputed = Self.disputedReactions(firstGroups, otherGroups, owned: owned, end: origin + seconds(available))
                            for candidate in disputed {
                                let low = max(base, Int(((candidate.start - origin - 0.18) * Double(rate)).rounded()))
                                let high = min(available, Int(((candidate.end - origin + 0.24) * Double(rate)).rounded()))
                                guard low < high else { continue }
                                try Task.checkCancellation()
                                let heard = try await independent.recognize(samples: Array(slice(low..<high)))
                                if let text = candidate.confirmed(by: heard) {
                                    let cue = Caption(start: candidate.start, end: candidate.end, original: text, translated: "",
                                                      sourceLanguage: .japanese, targetLanguage: target)
                                    verified.append(cue)
                                    if DisputedReaction.hesitation(candidate.first, candidate.second) { confirmedHesitations.insert(cue.id) }
                                }
                            }
                        }
                        agreed += ClipJapaneseNumberRecovery.agreement(first, start: origin + seconds(narrow.lowerBound), duration: seconds(narrow.count),
                            second: other, otherStart: origin + seconds(wide.lowerBound), otherDuration: seconds(wide.count),
                            owned: owned, limit: origin + seconds(available))
                        let short = compare(first, narrow, other, wide, short: true)
                        let disputedDigits = ClipJapaneseNumberRecovery.disputedGroups(first, start: origin + seconds(narrow.lowerBound), duration: seconds(narrow.count),
                            second: other, otherStart: origin + seconds(wide.lowerBound), otherDuration: seconds(wide.count), owned: owned)
                        if !short.isEmpty || !disputedDigits.isEmpty {
                            // Recheck a short reaction or a number missing one internal digit
                            // with different real audio context on both sides.
                            let thirdWindow = max(0, next - 24_320)..<min(available, end + 33_920)
                            if thirdWindow != narrow, thirdWindow != wide {
                                let third = try await recognizer.recognizeDetailed(samples: Array(slice(thirdWindow)))
                                if !disputedDigits.isEmpty {
                                    agreed += ClipJapaneseNumberRecovery.corroborate(disputedDigits, with: third,
                                        start: origin + seconds(thirdWindow.lowerBound), duration: seconds(thirdWindow.count),
                                        owned: owned, limit: origin + seconds(available))
                                }
                                let nearThird = compare(first, narrow, third, thirdWindow, short: true)
                                let wideThird = compare(other, wide, third, thirdWindow, short: true)
                                agreed += short.filter { cue in
                                    nearThird.contains(cue) && wideThird.contains { $0.text == cue.text && abs($0.start - cue.start) <= 0.10 }
                                }
                            }
                        }
                        let captions = agreed.map { Caption(start: $0.start, end: $0.end, original: $0.text,
                                                        translated: $0.text.allSatisfy({ $0.isASCII && $0.isNumber }) ? $0.text : "",
                                                        sourceLanguage: .japanese, targetLanguage: target) }
                        for cue in captions {
                            if let audio = shortSamples[cue.start], audio.original == cue.original { shortAudio[cue.id] = audio }
                        }
                        verified += captions
                    }
                }
            }
            next = end
        }
        let discard = max(0, next - far - base)
        pcm.removeFirst(discard); base += discard
    }

    func take(_ primary: [Caption], completedStart: Double?, finished: Bool, numberAlternates: [UUID: String] = [:]) async throws -> [Caption] {
        pendingNumberReadings.merge(numberAlternates) { _, current in current }
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
        let reviewed = verified.filter { $0.end <= cutoff }
        let main = pending.filter { $0.end <= cutoff }.filter { cue in
            guard let original = pendingNumberReadings.removeValue(forKey: cue.id) else { return true }
            return !ClipJapaneseNumberRecovery.confirmsOriginalNumber(original, insteadOf: cue, verified: reviewed)
        }
        pending.removeAll { $0.end <= cutoff }; verified.removeAll { $0.end <= cutoff }
        let confirmed = confirmedHesitations
        confirmedHesitations.subtract(reviewed.map(\.id))
        var corroborated: Set<UUID> = []
        for cue in reviewed {
            guard let audio = shortAudio.removeValue(forKey: cue.id), let independent,
                  Self.shortConflict(cue, primary: main) else { continue }
            try Task.checkCancellation()
            let tight = try await independent.recognize(samples: Array(audio.samples[audio.tight]))
            guard tight == cue.original else { continue }
            let wider = try await independent.recognize(samples: audio.samples)
            if wider == cue.original { corroborated.insert(cue.id) }
        }
        return Self.combine(primary: main, verified: reviewed, confirmedHesitations: confirmed, corroboratedShort: corroborated)
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

    static func combine(primary: [Caption], verified: [Caption], confirmedHesitations: Set<UUID> = [], corroboratedShort: Set<UUID> = []) -> [Caption] {
        func overlap(_ a: Caption, _ b: Caption) -> Bool { a.start < b.end && b.start < a.end }
        let codes = verified.filter { $0.original.count >= 3 && $0.original.allSatisfy(\.isNumber) }
        func repeatedCode(_ cue: Caption) -> Bool {
            codes.contains { $0.id != cue.id && $0.original == cue.original && abs($0.start - cue.start) < 3 }
        }
        var retained = primary.map { anchoredReaction($0, verified: verified) }.filter { cue in
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
            if corroboratedShort.contains(candidate.id), conflicts.count == 1, let i = conflicts.first,
               Self.shortConflict(candidate, primary: [retained[i]]) {
                retained[i] = candidate
                continue
            }
            if confirmedHesitations.contains(candidate.id), conflicts.count == 1, let i = conflicts.first {
                let cue = retained[i]
                // Only replace a short automatic filler when two different
                // recognizers hear the last mora in this overlapping utterance.
                if cue.translated.isEmpty, reactions.contains(cue.original), cue.end - cue.start <= 0.8,
                   abs(cue.start - candidate.start) <= 0.5, abs(cue.end - candidate.end) <= 0.30,
                   min(cue.end, candidate.end) - max(cue.start, candidate.start) >= 0.18 {
                    retained[i] = candidate
                    continue
                }
            }
            // Keep a complete existing cue unless the independently agreed
            // phrase includes all of it and adds genuinely omitted words.
            if conflicts.count == 1, let i = conflicts.first, retained[i].translated.isEmpty,
               retained[i].original.count >= 3, Self.containsOriginal(retained[i].original, candidate: candidate.original),
               // The primary segment can include a short lead-in and tail from the
               // original recording. Both independent windows must still cover its words.
               candidate.start <= retained[i].start + 0.42, candidate.end >= retained[i].end - 0.48,
               min(candidate.end, retained[i].end) - max(candidate.start, retained[i].start) >= min(0.28, (retained[i].end - retained[i].start) / 2) {
                retained[i] = candidate
            }
        }
        return retained.sorted { $0.start < $1.start }
    }
}
