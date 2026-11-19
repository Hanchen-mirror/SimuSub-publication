import Foundation

struct RecognizedSpeech: Sendable {
    struct Token: Sendable, Equatable {
        var text: String
        var time: Double
    }
    var text: String
    var tokens: [Token] = []
    var language: SubtitleLanguage? = nil


}

/// Restores only timestamp gaps anchored by matching tokens. Substitutions,
/// unconfirmed text and unanchored tails remain revisable. No extra ASR request.
struct ASRRevisionGuard {
    private var previous: [RecognizedSpeech.Token] = []
    private var confirmed: [RecognizedSpeech.Token] = []
    private(set) var japaneseAgreement = JapaneseTimedAgreement()
    private var previousEnd = -Double.infinity
    private var previousStart: Double?
    private var visibleText = ""
    private var lastHypothesis = ""
    private var agreedText = ""
    private var reviewStart: Double?
    private var reviewEnd = -Double.infinity

    mutating func protectRollback(_ text: String, start: Double, end: Double) -> (text: String, pending: String?) {
        if reviewStart == nil || abs(start - reviewStart!) > 0.001 || end < reviewEnd {
            visibleText = ""; lastHypothesis = ""; agreedText = ""
        }
        let common = String(zip(visibleText, text).prefix { $0 == $1 }.map { $0.0 })
        let contracted = visibleText.count >= 10 && visibleText.count - text.count >= 6 && text.count * 10 <= visibleText.count * 8
        let erasedAgreement = agreedText.count >= 6 && !text.hasPrefix(agreedText) && common.count < 3
        if !text.isEmpty && (contracted || erasedAgreement) {
            reviewStart = start; reviewEnd = end
            return (visibleText, text)
        }
        if end > reviewEnd + 0.05 {
            let agreement = String(zip(lastHypothesis, text).prefix { $0 == $1 }.map { $0.0 })
            if agreement.count >= 6 { agreedText = agreement }
            else if !text.hasPrefix(agreedText) { agreedText = "" }
        }
        if !text.isEmpty { visibleText = text; lastHypothesis = text }
        reviewStart = start; reviewEnd = end
        return (text, nil)
    }

    mutating func reconcile(_ speech: RecognizedSpeech, start: Double, end: Double,
                            recoverShortOmissions: Bool = false) -> (text: String, restored: Bool, tokens: [RecognizedSpeech.Token]) {
        let current = speech.tokens.map { RecognizedSpeech.Token(text: $0.text, time: $0.time + start) }
        guard !current.isEmpty, current.map(\.text).joined() == speech.text,
              current.allSatisfy({ $0.time.isFinite && $0.time >= start && $0.time <= end }),
              zip(current, current.dropFirst()).allSatisfy({ $0.time <= $1.time }),
              previousStart == nil || start <= previousStart! + 0.001 else {
            // Padding can put a single draft's last token just outside its real
            // samples. Discard that alignment, retaining independent evidence
            // from earlier valid windows of this same utterance.
            if let previousStart, abs(start - previousStart) > 0.001 || end < previousEnd {
                japaneseAgreement = JapaneseTimedAgreement()
            }
            previous = []; confirmed = []; previousStart = start; previousEnd = end
            return (speech.text, false, speech.tokens)
        }
        func matches(_ a: RecognizedSpeech.Token, _ b: RecognizedSpeech.Token) -> Bool {
            a.text == b.text && abs(a.time - b.time) <= 0.12
        }
        // Agreement is from two distinct, growing audio windows, never from
        // repairing our own output. Keep two tail tokens and 350 ms provisional.
        if end > previousEnd + 0.05 {
            if recoverShortOmissions { japaneseAgreement.observe(previous: previous, current: current, previousEnd: previousEnd) }
            let agreement = zip(previous, current).prefix { matches($0, $1) }.count
            let safe = Array(current.prefix(max(0, agreement - 2)).prefix { $0.time < end - 0.35 })
            if safe.count > confirmed.count { confirmed = safe }
        }
        // A new word occupying the same audio position is a correction, not
        // silence. Invalidate old confirmation so it cannot be resurrected later.
        if confirmed.contains(where: { old in
            !current.contains(where: { matches(old, $0) }) && current.contains(where: { abs(old.time - $0.time) <= 0.08 && old.text != $0.text })
        }) { confirmed = [] }
        var insertions: [Int: [RecognizedSpeech.Token]] = [:]
        var lastOld = -1, lastNew = -1
        for newIndex in current.indices {
            guard let oldIndex = confirmed.indices.first(where: { $0 > lastOld && matches(confirmed[$0], current[newIndex]) }) else { continue }
            let missing = Array(confirmed[(lastOld + 1)..<oldIndex])
            // Three matching tokens on the right disambiguate repeated words.
            let rightAnchor = (0..<3).allSatisfy { offset in
                oldIndex + offset < confirmed.count && newIndex + offset < current.count && matches(confirmed[oldIndex + offset], current[newIndex + offset])
            }
            // One missing kana can change the meaning. A short deletion needs
            // two matching timed tokens before it and three matching tokens after.
            let shortGapAnchored = recoverShortOmissions && lastOld >= 1 && lastNew >= 1
                && matches(confirmed[lastOld - 1], current[lastNew - 1])
            if newIndex == lastNew + 1, !missing.isEmpty,
               missing.map(\.text).joined().count >= 3 || shortGapAnchored, rightAnchor,
               let first = missing.first, let last = missing.last,
               last.time < current[newIndex].time - 0.12,
               lastNew < 0 || first.time > current[lastNew].time + 0.12 {
                insertions[newIndex] = missing
            }
            lastOld = oldIndex; lastNew = newIndex
        }
        previous = current; previousStart = start; previousEnd = end
        var repaired = insertions.isEmpty ? current : current.indices.flatMap { (insertions[$0] ?? []) + [current[$0]] }
        if recoverShortOmissions { repaired = japaneseAgreement.fillingGaps(in: repaired, start: start, end: end) }
        guard repaired.count > current.count else { return (speech.text, false, speech.tokens) }
        return (repaired.map(\.text).joined(), true, repaired.map { .init(text: $0.text, time: $0.time - start) })
    }
}
