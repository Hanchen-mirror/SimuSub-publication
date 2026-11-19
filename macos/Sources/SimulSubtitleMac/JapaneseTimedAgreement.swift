import Foundation

/// A long singing window can lose a whole stretch that two shorter,
/// independently decoded windows already heard. Retain only consecutive,
/// time-aligned agreements from raw hypotheses of the same utterance.
struct JapaneseTimedAgreement {
    typealias Token = RecognizedSpeech.Token
    private var runs: [[Token]] = []
    private var observed: [[Token]] = []

    private func same(_ a: Token, _ b: Token) -> Bool {
        a.text == b.text && abs(a.time - b.time) <= 0.16
    }

    mutating func observe(previous: [Token], current: [Token], previousEnd: Double) {
        guard !previous.isEmpty else { return }
        observed.append(previous)
        if observed.count > 24 { observed.removeFirst() }
        var nextOld = 0, index = 0
        while index < current.count {
            guard let old = previous.indices.dropFirst(nextOld).first(where: { same(previous[$0], current[index]) }) else {
                index += 1; continue
            }
            var count = 1
            while old + count < previous.count, index + count < current.count,
                  same(previous[old + count], current[index + count]) { count += 1 }
            let run = current[index..<(index + count)].prefix { $0.time <= previousEnd - 0.35 }
            if run.count >= 3 { runs.append(Array(run)) }
            nextOld = old + count
            index += count
        }
        if runs.count > 96 { runs.removeFirst(runs.count - 96) }
    }

    /// Verify a hole in the final with a new decode of its original waveform.
    /// Only inspect intervals where a growing window had already heard words.
    func verifyingAudio(in raw: RecognizedSpeech, preliminary: RecognizedSpeech, samples: [Float], start: Double,
                        recognize: ([Float]) async throws -> RecognizedSpeech) async throws -> RecognizedSpeech {
        guard !observed.isEmpty, raw.tokens.map(\.text).joined() == raw.text else { return preliminary }
        let rate = 16_000.0, duration = Double(samples.count) / rate
        guard raw.tokens.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= duration }),
              zip(raw.tokens, raw.tokens.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return preliminary }
        let boundaries = [0] + raw.tokens.map(\.time) + [duration]
        var tokens = preliminary.tokens
        var changed = false
        var shortRetries = 0
        for index in 0..<(boundaries.count - 1) {
            let left = boundaries[index], right = boundaries[index + 1]
            guard left.isFinite, right.isFinite, left >= 0, right <= duration, right - left >= 1.2 else { continue }
            let short = right - left < 2.5
            if short, shortRetries >= 2 { continue }
            let begin = index == 0 ? left : left + 0.15
            let finish = index + 2 == boundaries.count ? right : right - 0.15
            let windows = max(1, Int(ceil((finish - begin) / 8)))
            for n in 0..<windows {
                let lower = begin + (finish - begin) * Double(n) / Double(windows)
                let upper = begin + (finish - begin) * Double(n + 1) / Double(windows)
                let evidence = observed.map { row in row.filter { lower + start <= $0.time && $0.time < upper + start } }
                let previous = tokens.filter { lower <= $0.time && $0.time < upper }
                let threshold = short ? 2 : 3
                guard evidence.contains(where: { $0.count >= threshold && Set($0.map(\.text)).count >= 2
                    && (!short || $0.count > previous.count) }) else { continue }
                if short { shortRetries += 1 }
                let first = max(0, Int((lower - 0.75) * rate))
                let last = min(samples.count, Int(((upper + 0.75) * rate).rounded(.up)))
                let retry = try await recognize(Array(samples[first..<last]))
                guard !retry.tokens.isEmpty, retry.tokens.map(\.text).joined() == retry.text else { continue }
                let shift = Double(first) / rate
                let candidate = retry.tokens.map { Token(text: $0.text, time: $0.time + shift) }
                    .filter { lower <= $0.time && $0.time < upper }
                let matches = candidate.filter { token in
                    evidence.contains { row in row.contains { $0.text == token.text && abs($0.time - token.time - start) <= 0.36 } }
                }
                // A second pass may hallucinate over instruments. Require multiple
                // localized matches to the earlier voice and preserve stronger evidence.
                // Short holes require every inserted token to agree with both
                // an earlier hypothesis and the fresh local decode.
                if short {
                    guard candidate.count == matches.count, candidate.count > previous.count else { continue }
                    var remaining = candidate[...]
                    let preservesKnown = previous.allSatisfy { known in
                        guard let match = remaining.firstIndex(where: { same($0, known) }) else { return false }
                        remaining = remaining.suffix(from: remaining.index(after: match))
                        return true
                    }
                    guard preservesKnown else { continue }
                }
                guard matches.count >= threshold, Set(matches.map(\.text)).count >= 2,
                      candidate.count >= previous.count else { continue }
                tokens.removeAll { lower <= $0.time && $0.time < upper }
                tokens.append(contentsOf: candidate)
                changed = true
            }
        }
        guard changed else { return preliminary }
        tokens.sort { $0.time < $1.time }
        return RecognizedSpeech(text: tokens.map(\.text).joined(), tokens: tokens, language: raw.language)
    }

    func fillingGaps(in current: [Token], start: Double, end: Double) -> [Token] {
        guard !current.isEmpty, !runs.isEmpty else { return current }
        var result: [Token] = []
        for i in 0...current.count {
            let left = i == 0 ? start : current[i - 1].time
            let right = i == current.count ? end : current[i].time
            var recovered: [Token] = []
            if right - left >= 1.5 {
                // Never replace a final token. Recent corroboration takes priority
                // if two pairs disagree about a previously empty audio interval.
                var occupied: [ClosedRange<Double>] = []
                for run in runs.reversed() {
                    var part: [Token] = []
                    func acceptPart() {
                        if part.count >= 3, let first = part.first, let last = part.last,
                           last.time - first.time >= 0.3 {
                            recovered.append(contentsOf: part)
                            occupied.append((first.time - 0.18)...(last.time + 0.18))
                        }
                        part.removeAll(keepingCapacity: true)
                    }
                    let lower = i == 0 ? start - 0.001 : left + 0.18
                    let upper = i == current.count ? end + 0.001 : right - 0.18
                    for token in run where lower < token.time && token.time < upper {
                        if occupied.contains(where: { $0.contains(token.time) }) { acceptPart() }
                        else { part.append(token) }
                    }
                    acceptPart()
                }
            }
            if recovered.isEmpty, i >= 2, i + 1 < current.count {
                // For just one or two missing characters, demand two matching
                // final anchors on each side of the gap.
                for run in runs.reversed() {
                    guard let a = run.indices.first(where: { same(run[$0], current[i - 1]) }), a > 0,
                          same(run[a - 1], current[i - 2]) else { continue }
                    for count in 1...2 where a + count + 2 < run.count {
                        let b = a + count + 1
                        if same(run[b], current[i]), same(run[b + 1], current[i + 1]),
                           run[a + 1].time > left + 0.08, run[b - 1].time < right - 0.08 {
                            recovered = Array(run[(a + 1)..<b])
                            break
                        }
                    }
                    if !recovered.isEmpty { break }
                }
            }
            result.append(contentsOf: recovered.sorted { $0.time < $1.time })
            if i < current.count { result.append(current[i]) }
        }
        return result
    }
}
