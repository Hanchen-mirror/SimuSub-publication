import Foundation

private actor PrefixTestRecognizer: SpeechRecognizing {
    let texts: [String]
    var index = 0
    init(_ texts: [String]) { self.texts = texts }
    func recognize(samples: [Float]) async throws -> String {
        defer { index += 1 }; return texts[min(index, texts.count - 1)]
    }
}
private actor PrefixTestTranslator: TextTranslating {
    var inputs: [String] = []
    let failFirst: Bool
    let emptyTail: Bool
    nonisolated let requiresFullUtterance: Bool
    init(failFirst: Bool = false, emptyTail: Bool = false, requiresFullUtterance: Bool = false) { self.failFirst = failFirst; self.emptyTail = emptyTail; self.requiresFullUtterance = requiresFullUtterance }
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        inputs.append(text)
        if failFirst && inputs.count == 1 { throw URLError(.timedOut) }
        if emptyTail && inputs.count == 2 { return "" }
        return "译:" + text
    }
}
@MainActor
enum ClipV123Checks {
    static func run(directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        let prefix = "今日は阿部寛の映画を見ました"
        var state = StablePrefixConfirmation()
        try require(state.observe(prefix + "とても", samples: 16000) == nil, "v123_one_hypothesis_never_confirms")
        try require(state.observe(prefix + "とても", samples: 16000) == nil, "v123_same_audio_never_confirms")
        try require(state.observe(prefix + "とても楽しい", samples: 32000) == prefix, "v123_agreement_confirms_complete_clause")
        try require(state.observe(prefix + "とても楽しいです", samples: 48000) == nil, "v123_at_most_one_early_request")
        var unstable = StablePrefixConfirmation()
        _ = unstable.observe("今日はゲームをしますそうですね", samples: 16000)
        try require(unstable.observe("今日はゲームをしませんそうですね", samples: 32000) == nil, "v123_changed_negation_not_committed")
        var partial = StablePrefixConfirmation()
        _ = partial.observe("阿部寛の映画はとても面白", samples: 16000)
        try require(partial.observe("阿部寛の映画はとても面白かった", samples: 32000) == nil, "v123_unfinished_clause_waits")
        let plan = ASRHotwordPlan(words: ["阿部寛", "阿部寛", "A", "😀", "阿部:3", "阿部\n寛", "ＡＢ"], tokenTable: "<blk> 0\n阿 1\n部 2\n寛 3\nA 4\nB 5\n")
        try require(plan.accepted == ["阿部寛", "AB"] && plan.rejected.count == 4, "v123_hotwords_validate_normalize_deduplicate_and_reject_injection")
        for mode in ["reuse", "correct", "failure", "disabled", "exact", "fullSentence"] {
            let suite = "simusub.v123." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let full = mode == "correct" ? "今日は阿部寛の映画を見ませんでした" : mode == "exact" ? prefix : prefix + "とても楽しかったです"
            let recognizer = PrefixTestRecognizer([prefix + "とても", prefix + "とても楽しかった", full, full])
            let translator = PrefixTestTranslator(failFirst: mode == "failure", requiresFullUtterance: mode == "fullSentence")
            let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")), recognizer: recognizer, translator: translator)
            model.stablePrefixesEnabled = mode != "disabled"
            let id = UUID()
            await model.process([Float](repeating: 0.1, count: 16000), start: 0, id: id, revision: 1, isFinal: false)
            await model.process([Float](repeating: 0.1, count: 32000), start: 0, id: id, revision: 2, isFinal: false)
            if mode == "fullSentence" { try require(model.captions[0].confirmedPrefix == prefix, "v123_local_keeps_stable_japanese_without_fragment_translation") }
            let early = await translator.inputs
            try require(early == (mode == "disabled" || mode == "fullSentence" ? [] : [prefix]), "v123_early_request_" + mode)
            await model.process([Float](repeating: 0.1, count: 48000), start: 0, id: id, revision: 3, isFinal: true)
            await model.process([Float](repeating: 0.1, count: 48000), start: 0, id: id, revision: 3, isFinal: true)
            let requests = await translator.inputs
            let expected = mode == "reuse" ? [prefix, "とても楽しかったです"] : mode == "disabled" || mode == "exact" || mode == "fullSentence" ? [full] : [prefix, full]
            try require(requests == expected && model.captions.count == 1 && model.captions[0].original == full && !model.captions[0].isDraft, "v123_final_reuse_or_correction_no_duplicate_" + mode)
            try require(!model.captions[0].translated.contains("…") && !model.captions[0].translated.contains("失败"), "v123_final_export_has_no_partial_marker_" + mode)
            await model.clearCaptions()
            try require(model.captions.isEmpty, "v123_clear_removes_prefix_state_" + mode)
        }
        let suite = "simusub.v123.empty." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let empty = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
            recognizer: PrefixTestRecognizer([prefix + "とても", prefix + "とても楽しい", prefix + "楽しいです"]),
            translator: PrefixTestTranslator(emptyTail: true))
        let id = UUID()
        for revision in 1...3 {
            await empty.process([Float](repeating: 0.1, count: revision * 16000), start: 0, id: id, revision: revision, isFinal: revision == 3)
        }
        try require(empty.captions[0].isDraft && SubtitleDocument.render(empty.captions, format: .srt, mode: .bilingual).isEmpty,
                    "v123_empty_suffix_cannot_export_incomplete_translation")
        return checks
    }
}
