import Foundation

enum ClipJapaneseReactionChecks {
    static func run() throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        typealias Token = RecognizedSpeech.Token
        let spaced = [Token(text: " ", time: 0.1), Token(text: " え", time: 0.7),
                      Token(text: " と ", time: 1.4), Token(text: " ", time: 1.8)]
        try require(MultilingualSpeechRecognizer.japaneseTimedTokens(spaced, text: "え と") ==
                    [.init(text: "え", time: 0.7), .init(text: " と", time: 1.4)]
                    && MultilingualSpeechRecognizer.japaneseTimedTokens(spaced, text: "えと").isEmpty,
                    "japanese_native_boundary_spaces_keep_token_timing_and_internal_text")
        func tokens(_ values: [(String, Double)]) -> [Token] { values.map { Token(text: $0.0, time: $0.1) } }
        let small = tokens([("こ", 3.1), ("ち", 3.4), ("か", 3.6)])
        let full = tokens([("こ", 3.12), ("っ", 3.31), ("ち", 3.42), ("か", 3.62)])
        let late = tokens([("こ", 3.12), ("っ", 3.21), ("ち", 3.65), ("か", 3.82)])
        func disputed(_ left: [Token], _ right: [Token]) -> [ClipJapaneseGapDetector.DisputedReaction] {
            ClipJapaneseGapDetector.disputedReactions([left], [right], owned: 0..<8, end: 10)
        }
        let choice = disputed(small, full).first
        try require(choice?.confirmed(by: "こっちか") == "こっちか" && choice?.confirmed(by: "こちら") == nil
                    && disputed(small, late).isEmpty && disputed(full, full).isEmpty
                    && disputed(tokens([("1", 3.1), ("日", 3.2)]), tokens([("1", 3.1), ("っ", 3.15), ("日", 3.2)])).isEmpty,
                    "japanese_optional_geminate_needs_two_timed_spellings_and_exact_separate_model")
        let hesitation = disputed(tokens([("え", 4.2)]), tokens([("え", 4.19), ("と", 4.42)])).first
        try require(hesitation?.confirmed(by: "えっと") == "えっと" && hesitation?.confirmed(by: "え") == nil,
                    "japanese_hesitation_requires_separate_model_to_hear_final_mora")
        let cue = Caption(start: 3.5, end: 4.75, original: "えっと", translated: "")
        let anchor = Caption(start: 4.4, end: 4.82, original: "えっと", translated: "")
        let neighbor = Caption(start: 3.35, end: 3.95, original: "それから", translated: "")
        let adjusted = ClipJapaneseGapDetector.combine(primary: [cue], verified: [anchor, neighbor])
        var edited = cue
        edited.translated = "我改过"
        try require(adjusted.count == 2 && adjusted[0] == neighbor && adjusted[1].id == cue.id
                    && adjusted[1].start == anchor.start && adjusted[1].end == cue.end
                    && ClipJapaneseGapDetector.combine(primary: [edited], verified: [anchor, neighbor]) == [edited]
                    && ClipJapaneseGapDetector.anchoredReaction(cue, verified: [anchor]) == cue,
                    "japanese_anchor_releases_blocked_neighbor_without_rewriting_saved_cue")
        let rival = Caption(start: 3.62, end: 4.02, original: "うん", translated: "")
        let confirmed = Caption(start: 3.4, end: 4.0, original: "えっと", translated: "")
        try require(ClipJapaneseGapDetector.combine(primary: [rival], verified: [confirmed]) == [rival]
                    && ClipJapaneseGapDetector.combine(primary: [rival], verified: [confirmed], confirmedHesitations: [confirmed.id]) == [confirmed],
                    "japanese_filler_conflict_requires_independent_acoustic_confirmation")
        let interjection = Caption(start: 8.50, end: 9.02, original: "やった", translated: "")
        let mistaken = Caption(start: 8.10, end: 9.03, original: "やっぱり", translated: "")
        var protected = mistaken
        protected.translated = "已经校对"
        let long = Caption(start: 8.0, end: 11.0, original: "やっぱり", translated: "")
        let phrase = TimedCaptionPhrase(text: "やった", start: 8.50, end: 9.02)
        let timed = tokens([("や", 8.50), ("っ", 8.62), ("た", 8.72)])
        let partial = timed + tokens([("よ", 8.90)])
        try require(ClipJapaneseGapDetector.alignedShortUtterance(phrase, first: [timed], other: [timed])
                    && !ClipJapaneseGapDetector.alignedShortUtterance(phrase, first: [partial], other: [timed])
                    && ClipJapaneseGapDetector.shortConflict(interjection, primary: [mistaken])
                    && !ClipJapaneseGapDetector.shortConflict(interjection, primary: [long])
                    && !ClipJapaneseGapDetector.shortConflict(interjection, primary: [protected])
                    && !ClipJapaneseGapDetector.shortConflict(interjection, primary: [mistaken, mistaken]),
                    "japanese_recheck_only_complete_short_utterance_with_one_unedited_conflict")
        try require(ClipJapaneseGapDetector.combine(primary: [mistaken], verified: [interjection]) == [mistaken]
                    && ClipJapaneseGapDetector.combine(primary: [mistaken], verified: [interjection], corroboratedShort: [interjection.id]) == [interjection]
                    && ClipJapaneseGapDetector.combine(primary: [protected], verified: [interjection], corroboratedShort: [interjection.id]) == [protected],
                    "japanese_short_primary_conflict_requires_separate_model_and_preserves_edits")
        return checks
    }
}
