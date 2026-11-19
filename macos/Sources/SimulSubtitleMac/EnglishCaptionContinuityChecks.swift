import Foundation

enum EnglishCaptionContinuityChecks {
    static func run() throws -> [String] {
        let lag = Caption(start: 3, end: 6, original: "Styles in the West could lag behind.",
                          translated: "西方的风格可能会落后。", sourceLanguage: .english)
        func history(_ captions: [Caption], at start: Double = 6, sessionStart: Int = 0,
                     pending: UUID? = nil) -> [SubtitleTranslationContext.Line] {
            EnglishCaptionContinuity.previous(in: captions, before: captions.count, startingAt: start,
                sessionStart: sessionStart, target: .simplifiedChinese, recognitionPending: { $0 == pending })
        }
        var other = lag
        other.sourceLanguage = .japanese
        var opposite = lag
        opposite.targetLanguage = .traditionalChinese
        var mixed = lag
        mixed.original = "We 先走"
        var partial = lag
        partial.isDraft = true
        partial.translated = "暂译"
        var untranslated = lag
        untranslated.translated = ""
        let cases = [
            ("close_final", history([lag]).last?.translated == lag.translated),
            ("pause_resets", history([lag], at: 8).isEmpty),
            ("session_resets", history([lag], sessionStart: 1).isEmpty),
            ("language_resets", history([lag, other]).isEmpty && history([mixed]).isEmpty),
            ("target_resets", history([opposite]).isEmpty),
            ("original_only_resets", history([untranslated]).isEmpty),
            ("unfinished_asr_resets", history([partial], pending: partial.id).isEmpty),
            ("confirmed_source_without_unfinished_translation", history([partial]).last?.translated == "" &&
                 history([partial]).last?.original == partial.original)
        ]
        for (name, ok) in cases where !ok { throw ClipError.message("English subtitle continuity: " + name) }
        return cases.map { "english_caption_continuity_" + $0.0 }
    }
}
