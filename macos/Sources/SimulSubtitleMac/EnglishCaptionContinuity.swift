import Foundation

enum EnglishCaptionContinuity {
    /// A pause or an intervening cue starts a fresh context, even if an older
    /// English cue happens to have a more useful-looking translation.
    static func previous(in captions: [Caption], before index: Int, startingAt start: Double,
                         sessionStart: Int, target: SubtitleLanguage, recognitionPending: (UUID) -> Bool) -> [SubtitleTranslationContext.Line] {
        guard target.isChinese, sessionStart >= 0, index > sessionStart, index <= captions.count else { return [] }
        var nextStart = start
        var lines: [SubtitleTranslationContext.Line] = []
        for cue in captions[max(sessionStart, index - 2)..<index].reversed() {
            let gap = nextStart - cue.end
            guard (-0.032...1.0).contains(gap), cue.start < nextStart, !cue.isOriginalOnly, !recognitionPending(cue.id),
                  cue.sourceLanguage == .english, cue.targetLanguage == target,
                  LiveLanguageRouting.translationSource(text: cue.original, detected: cue.sourceLanguage) == SubtitleLanguage.english.name
            else { break }
            lines.append(.init(original: cue.original,
                               translated: cue.isDraft ? "" : SubtitleDocument.completedTranslation(cue) ?? "",
                               sourceLanguage: SubtitleLanguage.english.name))
            nextStart = cue.start
        }
        return lines.reversed()
    }
}
