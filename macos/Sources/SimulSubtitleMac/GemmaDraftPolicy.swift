import Foundation

/// A shared decoder cannot translate while re-decoding every short ASR draft.
/// Prioritize finals; retain occasional previews for long utterances. Original
/// mode keeps the frontend's normal cadence because no translation competes.
struct GemmaDraftPolicy: Sendable {
    private var lastBucket: [UUID: Int] = [:]

    mutating func shouldRecognize(id: UUID, sampleCount: Int, isFinal: Bool, originalOnly: Bool) -> Bool {
        if isFinal { lastBucket[id] = nil; return true }
        if originalOnly { return true }
        let bucket = sampleCount / (6 * 16_000)
        guard bucket > 0, bucket > (lastBucket[id] ?? 0) else { return false }
        lastBucket[id] = bucket
        return true
    }
}
