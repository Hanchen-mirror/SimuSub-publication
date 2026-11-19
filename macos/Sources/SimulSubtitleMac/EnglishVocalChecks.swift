import Foundation

private actor VocalFixtureRecognizer: SpeechRecognizing {
    let outputs: [String]
    private var index = 0
    init(_ outputs: [String]) { self.outputs = outputs }

    func recognize(samples: [Float]) async throws -> String {
        guard index < outputs.count else { throw ServiceError.invalidResponse }
        defer { index += 1 }
        return outputs[index]
    }
}

private actor VocalTranslationProbe: TextTranslating {
    var requests: [String] = []
    func translate(_ text: String, from: String, to: String) async throws -> String {
        requests.append(text)
        return "已译"
    }
}

@MainActor
enum EnglishVocalChecks {
    static func run(directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ ok: Bool, _ label: String) throws {
            guard ok else { throw ClipError.message("English vocal check failed: " + label) }
            checks.append("english_vocal_" + label)
        }
        var cadence = EnglishVocalCadence()
        let initiallyInactive = !cadence.active(at: 0)
        cadence.observe(at: 16_000)
        try require(initiallyInactive && cadence.active(at: 20 * 16_000) && !cadence.active(at: 30 * 16_000)
            && EnglishVocalTranscript.signalsMusic("[upbeat music]") && EnglishVocalTranscript.signalsMusic("♪ hear me ♪")
            && !EnglishVocalTranscript.signalsMusic("I teach music.")
            && EnglishVocalCadence.musicSearchStart + EnglishAudioEndpoint.lookahead <= 10 * 16_000,
                    "confirmed_music_extends_window_below_ten_seconds_then_expires")
        try require(EnglishVocalRecognition.accepted("Let's drink until we die", first: "Let's tank until we die") == "Let's drink until we die"
            && EnglishVocalRecognition.accepted("[Music]", first: "here we go") == nil
            && EnglishVocalRecognition.accepted("made up an entire verse on a beat where nobody sang", first: "") == nil
            && EnglishVocalRecognition.accepted("里面有其他语言", first: "go go") == nil,
                    "optional_local_refinement_keeps_vocal_language_and_word_evidence")
        let verse = "Before we crossed the bridge we heard the bell again."
        let interior = "We crossed the bridge, we heard the bell."
        try require(EnglishVocalRecognition.needsConfirmation(verse, first: "", samples: 144_000)
            && EnglishVocalRecognition.confirmed(verse, interior: interior, first: "") == "we crossed the bridge we heard the bell"
            && EnglishVocalRecognition.confirmed(verse, interior: interior, first: "Yeah.") == verse,
                    "sparse_music_window_requires_independent_crop_agreement")
        try require(EnglishVocalRecognition.confirmed(verse, interior: "You want to see the bridge.", first: "") == nil
            && EnglishVocalRecognition.confirmed("go go go go go yeah", interior: "go go go go go yeah", first: "oh") == nil
            && !EnglishVocalRecognition.needsConfirmation("The system.", first: "", samples: 144_000)
            && !EnglishVocalRecognition.needsConfirmation(verse, first: "", samples: 16_000),
                    "instrumental_short_decoder_reactions_and_repetitions_remain_suppressed")
        let refrain = "Follow the river through the valley."
        let pair = [refrain, refrain].joined(separator: " ")
        let runaway = Array(repeating: refrain, count: 8).joined(separator: " ")
        guard let loop = EnglishDecoderLoop("Listen now. " + runaway + " Come home.") else {
            throw ClipError.message("English repeated phrase was not detected")
        }
        try require(loop.repaired(prior: "", left: "Listen now. Follow the river", right: "through the valley. Come home.")
                    == "Listen now. " + refrain + " Come home."
                    && loop.repaired(prior: "", left: refrain, right: refrain) == "Listen now. " + pair + " Come home."
                    && loop.repaired(prior: runaway, left: runaway, right: refrain) == "Listen now. " + refrain + " Come home.",
                    "runaway_full_window_uses_independent_nonoverlapping_audio_for_repeat_count")
        try require(EnglishDecoderLoop(pair) == nil
                    && EnglishDecoderLoop(Array(repeating: "Oh yeah", count: 9).joined(separator: " ")) == nil
                    && EnglishDecoderLoop("Follow the river through the valley. Follow the river to the sea.") == nil,
                    "natural_sung_repeats_interjections_and_changing_refrain_stay_intact")
        let labels = ["[Music]", "(upbeat music)", "*Music*", "(Music)", "(", "♪ ♫", "*singing*", "[music] (Upbeat Music)"]
        try require(labels.allSatisfy { EnglishVocalTranscript.words(in: $0).isEmpty }, "annotation_variants")
        try require(EnglishVocalTranscript.words(in: "♪ I love music ♪ [Music] (hold on)") == "I love music (hold on)", "keeps_lyrics_and_backing_voice")

        try require(["(Music", "[upbeat music", "*Music"].allSatisfy {
            EnglishVocalTranscript.words(in: $0).isEmpty && EnglishVocalTranscript.signalsMusic($0)
        } && EnglishVocalTranscript.words(in: "(Music makes the room feel warm") == "(Music makes the room feel warm"
            && EnglishVocalTranscript.words(in: "I am singing") == "I am singing"
            && EnglishVocalTranscript.words(in: "Music keeps me awake") == "Music keeps me awake"
            && EnglishVocalTranscript.words(in: "[Music] The lights are on") == "The lights are on",
                    "unfinished_annotation_only_when_it_occupies_the_whole_hypothesis")
        let suite = "SimuSub.EnglishVocalChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "subtitle.sourceLanguage.v141")
        defaults.set("zh-Hans", forKey: "subtitle.targetLanguage.v141")
        let left = "And the only way to do great work is to love"
        let right = "what you do."
        let recognizer = VocalFixtureRecognizer(["Possible words", "(Music", left, right, "I love music.", "What you do?", "*music*", "♪ hear me ♪"])
        let translator = VocalTranslationProbe()
        let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("empty-vocal-models")),
                             recognizer: recognizer, translator: translator)
        let samples = [Float](repeating: 0.1, count: 16000)
        let draft = UUID()
        await model.process(samples, start: 0, id: draft, isFinal: false)
        await model.process(samples, start: 0, id: draft, revision: 2)
        let suppressedRequests = await translator.requests
        try require(model.captions.isEmpty && suppressedRequests.isEmpty, "nonverbal_final_retires_draft_without_mt")
        await model.process(samples, start: 2)
        await model.process(samples, start: 3)
        try require(model.captions.count == 1 && model.captions.first?.start == 2 && model.captions.first?.end == 4
            && model.captions.first?.original == left + " " + right, "adjacent_object_is_one_final_timed_cue")
        await model.process(samples, start: 4)
        await model.process(samples, start: 5)
        await model.process(samples, start: 6)
        await model.process(samples, start: 7)
        let translated = await translator.requests
        try require(model.captions.count == 4 && translated == [left, left + " " + right, "I love music.", "What you do?", "hear me"],
                    "independent_question_and_real_lyrics_survive_intervening_music")
        let prior = Caption(start: 0, end: 2, original: left, translated: "译", sourceLanguage: .english)
        let parallel = Caption(start: 0, end: 2, original: "It is just as true for beginners.", translated: "译", sourceLanguage: .english)
        try require(EnglishVocalTranscript.joined(previous: parallel, current: "as it is for experts.", start: 2, end: 4)
                    == "It is just as true for beginners as it is for experts."
                    && EnglishVocalTranscript.joined(previous: parallel, current: "As it is getting late.", start: 2, end: 4) == nil,
                    "parallel_comparison_despite_asr_period")
        try require(EnglishVocalTranscript.joined(previous: prior, current: right, start: 3.2, end: 4) == nil
            && EnglishVocalTranscript.joined(previous: prior, current: right, start: 2, end: 8) == nil,
                    "long_cue_and_pause_do_not_merge")
        let decision = Caption(start: 1, end: 3, original: "the tool to help me make", translated: "译", sourceLanguage: .english)
        try require(EnglishVocalTranscript.joined(previous: decision, current: "the big choices in life.", start: 3, end: 4)
            == "the tool to help me make the big choices in life."
            && EnglishVocalTranscript.joined(previous: decision, current: "The decision was final.", start: 3, end: 4) == nil
            && EnglishVocalTranscript.joined(previous: decision, current: "The right choice?", start: 3, end: 4) == nil,
                    "verb_object_tail_rejoins_without_consuming_statement_or_question")
        let hesitation = Caption(start: 3, end: 5, original: "I can understand...", translated: "译", sourceLanguage: .english)
        var alternative = hesitation
        alternative.original = "I can understand…"
        try require([hesitation, alternative].allSatisfy {
            EnglishVocalTranscript.joined(previous: $0, current: "how you feel.", start: 5, end: 6) == "I can understand how you feel."
        } && EnglishVocalTranscript.joined(previous: hesitation, current: "How do you feel?", start: 5, end: 6) == nil
            && EnglishVocalTranscript.joined(previous: hesitation, current: "The concert went well.", start: 5, end: 6) == nil,
                    "hesitation_at_open_predicate_preserves_nominal_clause_and_independent_question")
        return checks
    }
}
