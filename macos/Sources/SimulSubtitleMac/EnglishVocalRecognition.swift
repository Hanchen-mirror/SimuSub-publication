import Foundation

/// During a detected music passage, a locally installed second recognizer can
/// check the final audio again. Its interior crop provides evidence for sparse windows.
@MainActor
final class EnglishVocalRecognition {
    private var loader: Task<Void, Never>?
    private var engine: MultilingualSpeechRecognizer?
    private var activeUntil = -Double.infinity
    private(set) var loopCounts: [String: Int] = [:]
    func resetLoopCounts() { loopCounts.removeAll() }

    func reset() {
        loader?.cancel()
        loader = nil
        engine = nil
        activeUntil = -.infinity
    }

    func noteMusic(endingAt end: Double, models: LocalModelLibrary) {
        activeUntil = end + EnglishVocalCadence.holdSeconds
        guard loader == nil, let qwen = LocalModelDefinition.catalog.first(where: { $0.id == "qwen3-asr" }),
              models.isUsable(qwen) else { return }
        let folder = models.folder(for: qwen)
        loader = Task { [weak self] in
            do {
                try await models.verifyReady(qwen)
                try Task.checkCancellation()
                let recognizer = try await Task.detached(priority: .utility) {
                    try MultilingualSpeechRecognizer(model: qwen, folder: folder, language: .english, threads: 3)
                }.value
                try Task.checkCancellation()
                self?.engine = recognizer
            } catch {
                // Continue with the default engine even if optional files disappear.
            }
        }
    }

    func recover(_ loop: EnglishDecoderLoop, prior: String, samples: [Float], start: Double,
                 isFinal: Bool, localWhisper: any SpeechRecognizing, pending: () -> Int) async throws -> String {
        loopCounts[isFinal ? "whisperFinal" : "whisperDraft", default: 0] += 1
        guard isFinal, (24_000...192_000).contains(samples.count), pending() == 0 else {
            return loop.repaired(prior: prior)
        }
        let verifier: any SpeechRecognizing
        if start < activeUntil, let engine { verifier = engine }
        else { verifier = localWhisper }
        let middle = samples.count / 2
        do {
            let left = try await verifier.recognizeDetailed(samples: Array(samples[..<middle]))
            guard pending() == 0 else { return loop.repaired(prior: prior, left: left.text) }
            let right = try await verifier.recognizeDetailed(samples: Array(samples[middle...]))
            loopCounts["verifiedHalves", default: 0] += 1
            return loop.repaired(prior: prior, left: left.text, right: right.text)
        } catch is CancellationError { throw CancellationError() }
        catch { return loop.repaired(prior: prior) }
    }

    func refine(_ original: RecognizedSpeech, samples: [Float], start: Double, isFinal: Bool, pending: () -> Int) async throws -> RecognizedSpeech {
        if start >= activeUntil {
            if loader != nil { reset() }
            return original
        }
        guard isFinal, pending() == 0, let engine,
              (24_000...180_000).contains(samples.count) else { return original }
        do {
            let second = try await engine.recognizeDetailed(samples: samples)
            if EnglishDecoderLoop(second.text) != nil {
                loopCounts["qwenFullRejected", default: 0] += 1
                return original
            }
            if let text = Self.accepted(second.text, first: original.text) {
                return RecognizedSpeech(text: text, language: .english)
            }
            // Whisper may return only a music tag, a reaction or a short loop
            // during fast vocals. Verify a longer alternative against a shifted
            // excerpt, but yield immediately if live audio has queued more work.
            let candidate = EnglishVocalTranscript.words(in: second.text)
            guard Self.needsConfirmation(candidate, first: original.text, samples: samples.count),
                  pending() == 0 else { return original }
            let lower = samples.count * 15 / 100, upper = samples.count * 90 / 100
            let interior = try await engine.recognizeDetailed(samples: Array(samples[lower..<upper]))
            if EnglishDecoderLoop(interior.text) != nil {
                loopCounts["qwenCropRejected", default: 0] += 1
                return original
            }
            guard let text = Self.confirmed(candidate, interior: interior.text, first: original.text) else { return original }
            return RecognizedSpeech(text: text, language: .english)
        } catch is CancellationError { throw CancellationError() }
        catch { return original }
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0.filter { $0.isLetter || $0.isNumber || $0 == "'" }) }
            .filter { !$0.isEmpty }
    }

    static func needsConfirmation(_ candidate: String, first: String, samples: Int) -> Bool {
        let words = normalizedWords(candidate)
        return samples >= 4 * 16_000 && words.count >= 5 && words.count > normalizedWords(first).count
            && words.count <= samples / 2_000 + 2 && Set(words).count >= 4
            && candidate.range(of: "[A-Za-z]", options: .regularExpression) != nil
            && candidate.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) == nil
    }

    static func confirmed(_ candidate: String, interior: String, first: String) -> String? {
        let full = normalizedWords(candidate)
        let check = normalizedWords(EnglishVocalTranscript.words(in: interior))
        guard full.count >= 5, !check.isEmpty else { return nil }
        // Track the longest *consecutive* agreement. A handful of scattered
        // common words or a decoder repeating one phrase is weak evidence.
        var row = [Int](repeating: 0, count: check.count + 1)
        var best = 0
        var last = 0
        for (index, word) in full.enumerated() {
            for j in check.indices.reversed() {
                row[j+1] = word == check[j] ? row[j] + 1 : 0
                if row[j+1] > best {
                    best = row[j+1]
                    last = index + 1
                }
            }
        }
        guard best >= 5, Set(full[(last-best)..<last]).count >= 4 else { return nil }
        if !first.isEmpty { return candidate }
        // With no first-pass words, only display the words heard in both
        // decodes. Preserve spelling and punctuation from the full hypothesis.
        let originalWords = candidate.split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.allSatisfy { !$0.isLetter && !$0.isNumber } }
        guard originalWords.count == full.count else { return nil }
        return originalWords[(last-best)..<last].joined(separator: " ")
    }

    static func accepted(_ candidate: String, first: String) -> String? {
        let text = EnglishVocalTranscript.words(in: candidate)
        let words = text.split(whereSeparator: \.isWhitespace)
        let initial = first.split(whereSeparator: \.isWhitespace).count
        // Accompaniment can induce a decoder to fill a brief reaction with a
        // whole verse, or loop one word. Keep the first pass in those cases.
        guard initial >= 2, !words.isEmpty, words.count <= 2 * initial + 5,
              words.count * 3 >= initial, text.range(of: "[A-Za-z]", options: .regularExpression) != nil,
              text.range(of: #"[\p{Han}\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) == nil,
              words.count < 8 || Set(words.map { $0.lowercased() }).count >= 3 else { return nil }
        return text
    }
}
