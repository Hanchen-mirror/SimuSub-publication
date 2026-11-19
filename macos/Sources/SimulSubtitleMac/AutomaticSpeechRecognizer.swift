import Foundation

/// Per-utterance language routing. The complete original PCM always goes to the
/// chosen decoder; language probes are never emitted or stitched into subtitles.
final class AutomaticSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let detector: MultilingualSpeechRecognizer
    private let english: MultilingualSpeechRecognizer
    private let japanese: ReazonSpeechRecognizer
    private let mixed: MultilingualSpeechRecognizer
    private let mixedLanguageHints: Bool
    private let recoverInteriorOmissions: Bool
    init(store: LocalModelStore, folders: [String: URL], mixedLanguageHints: Bool = true, recoverInteriorOmissions: Bool = true) throws {
        self.mixedLanguageHints = mixedLanguageHints
        self.recoverInteriorOmissions = recoverInteriorOmissions
        func definition(_ id: String) throws -> LocalModelDefinition {
            guard let value = LocalModelDefinition.catalog.first(where: { $0.id == id }) else { throw ServiceError.modelFilesMissing }
            return value
        }
        detector = try MultilingualSpeechRecognizer(model: definition("sensevoice"), folder: folders["sensevoice"]!, language: nil)
        english = try MultilingualSpeechRecognizer(model: definition("whisper-base"), folder: folders["whisper-base"]!, language: .english)
        japanese = try ReazonSpeechRecognizer(store: store)
        mixed = try MultilingualSpeechRecognizer(model: definition("qwen3-asr"), folder: folders["qwen3-asr"]!, language: nil)
    }
    func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
    func recognizeDraft(samples: [Float]) async throws -> RecognizedSpeech { try await detector.recognizeDetailed(samples: samples) }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        let first = try await detector.recognizeDetailed(samples: samples)
        guard let language = first.language else { return try await mixed.recognizeDetailed(samples: samples) }
        var multilingual = LiveLanguageRouting.translationSource(text: first.text, detected: language) == "多语言"
        // Overlapping 2-second probes cover the full utterance, including the
        // tail. Never carry a previous segment's language into the next segment.
        if !multilingual && samples.count > 40_000 {
            let width = 32_000
            var offsets = Array(stride(from: 0, through: max(0, samples.count-width), by: 24_000))
            if offsets.last != samples.count-width { offsets.append(samples.count-width) }
            for offset in offsets {
                try Task.checkCancellation()
                let probe = try await detector.recognizeDetailed(samples: Array(samples[offset..<offset+width]))
                if let other = probe.language, other.asrCode != language.asrCode,
                   probe.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 4 {
                    multilingual = true; break
                }
            }
        }
        if multilingual {
            // A CJK language hint prevents the mixed decoder from translating
            // the surrounding CJK speech into its English dominant hypothesis.
            return try await mixed.recognizeDetailed(samples: samples, languageHint: mixedLanguageHints && language != .english ? language : nil)
        }
        switch language {
        case .japanese:
            var result = try await japanese.recognizeDetailed(samples: samples)
            if recoverInteriorOmissions && Self.shortenedAnchoredSpeech(first.text, result.text) {
                return try await mixed.recognizeDetailed(samples: samples, languageHint: mixedLanguageHints ? .japanese : nil)
            }
            result.language = .japanese; return result
        case .english:
            let result = try await english.recognizeDetailed(samples: samples)
            if recoverInteriorOmissions && Self.droppedInteriorWords(first.text, result.text) {
                // Re-decode the entire PCM. Never splice an uncertain name from
                // a different transcript into an otherwise fluent sentence.
                return try await mixed.recognizeDetailed(samples: samples)
            }
            return result
        case .simplifiedChinese, .traditionalChinese: return first
        }
    }

    static func shortenedAnchoredSpeech(_ reference: String, _ candidate: String) -> Bool {
        func letters(_ text: String) -> [Character] { Array(text.filter { $0.isLetter || $0.isNumber }) }
        let a = letters(reference), b = letters(candidate)
        guard b.count >= 3, a.count-b.count >= 6, b.count*5 < a.count*3 else { return false }
        return a.prefix(3).elementsEqual(b.prefix(3)) || a.suffix(3).elementsEqual(b.suffix(3))
    }

    static func droppedInteriorWords(_ reference: String, _ candidate: String) -> Bool {
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let a = words(reference), b = words(candidate)
        guard a.count >= 5, b.count >= 4 else { return false }
        // Two unchanged anchors on either side distinguish deletion from a
        // spelling substitution. Ignore filler/function-word disagreements.
        let ignored: Set<String> = ["the", "and", "but", "that", "this", "just", "uh", "um"]
        for i in 2..<(a.count-2) {
            for count in 1...min(3, a.count-i-2) {
                guard a[i..<i+count].contains(where: { $0.count >= 3 && !ignored.contains($0) && $0.contains(where: \.isLetter) }) else { continue }
                let anchors = Array(a[i-2..<i]) + Array(a[i+count..<i+count+2])
                if (0...(b.count-4)).contains(where: { Array(b[$0..<$0+4]) == anchors }) { return true }
            }
        }
        return false
    }
}
