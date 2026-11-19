import Foundation

private actor PrefixTestRecognizer: SpeechRecognizing {
    let texts: [String]
    var index = 0
    init(_ texts: [String]) { self.texts = texts }
    func recognize(samples: [Float]) async throws -> String {
        defer { index += 1 }; return texts[min(index, texts.count - 1)]
    }
}
private actor LateClauseTranslator: TextTranslating {
    private var suspended: CheckedContinuation<Void, Never>?
    var waiting: Bool { suspended != nil }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        if text == "We will leave today" {
            await withCheckedContinuation { suspended = $0 }
        }
        return "译:" + text
    }

    func release() { suspended?.resume(); suspended = nil }
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
        let first = "The bus will not arrive today"
        let second = first + " but we can still leave before noon."
        let finalEnglish = first + " but we cannot leave before noon. The fare is 12 dollars."
        var english = StablePrefixConfirmation()
        _ = english.observe(first + " but we", samples: 16_000, englishClauses: true)
        try require(english.observe(second, samples: 32_000, englishClauses: true) == first, "english_contrast_keeps_negative_clause_and_waits_for_agreement")
        try require(english.observe(second + " The fare", samples: 48_000, englishClauses: true) == nil, "english_second_preview_rate_limited")
        try require(english.observe(second + " The fare is", samples: 64_000, englishClauses: true) == second, "english_second_preview_includes_both_clauses")
        let third = second + " The fare is 12 dollars."
        _ = english.observe(third, samples: 96_000, englishClauses: true)
        try require(english.observe(third + " Next", samples: 112_000, englishClauses: true) == third,
                    "english_third_clause_keeps_advancing")
        for fragment in ["I bought nothing but the blue coat", "It was not only fast but it was also quiet",
                         "I cannot help but wonder why", "The fare rose to 12.50 dollars",
                         "We will leave if", "The new plan does not.", "If we stay here but they leave"] {
            var detector = StablePrefixConfirmation()
            _ = detector.observe(fragment, samples: 16_000, englishClauses: true)
            try require(detector.observe(fragment + " tomorrow", samples: 32_000, englishClauses: true) == nil,
                        "english_incomplete_or_nonclausal_but_waits_" + String(checks.count))
        }

        let englishSuite = "simusub.english.preview." + UUID().uuidString
        let englishDefaults = UserDefaults(suiteName: englishSuite)!
        defer { englishDefaults.removePersistentDomain(forName: englishSuite) }
        englishDefaults.set("en", forKey: "subtitle.sourceLanguage.v141")
        englishDefaults.set("zh-Hans", forKey: "subtitle.targetLanguage.v141")
        let englishTranslator = PrefixTestTranslator(requiresFullUtterance: true)
        let englishModel = AppModel(defaults: englishDefaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
            recognizer: PrefixTestRecognizer([first + " but we", second, second + " The fare", third, third + " The driver", finalEnglish]),
            translator: englishTranslator)
        let englishID = UUID()
        for revision in 1...6 {
            await englishModel.process([Float](repeating: 0.1, count: revision * 32000), start: 0,
                                       id: englishID, revision: revision, isFinal: revision == 6)
            if revision == 5 {
                try require(englishModel.captions[0].translated == "译:" + first + "\n译:but we can still leave before noon.\n译:The fare is 12 dollars. …",
                            "english_three_preview_translations_assemble_in_order")
            }
        }
        try require(await englishTranslator.inputs == [first, "but we can still leave before noon.", "The fare is 12 dollars.", finalEnglish],
                    "english_only_new_clauses_sent_before_full_corrected_final")
        try require(englishModel.captions.count == 1 && !englishModel.captions[0].isDraft &&
                    englishModel.captions[0].translated == "译:" + finalEnglish,
                    "english_final_preserves_corrected_negation_number_and_both_clauses")
        let lateTranslator = LateClauseTranslator()
        let corrected = "We will not leave today but we can meet next week."
        let lateModel = AppModel(defaults: englishDefaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
            recognizer: PrefixTestRecognizer(["We will leave today but we", "We will leave today but we can meet", corrected]), translator: lateTranslator)
        let lateID = UUID()
        func processLate(_ revision: Int, final: Bool = false) async {
            await lateModel.process([Float](repeating: 0.1, count: revision * 16000), start: 0, id: lateID, revision: revision, isFinal: final)
        }
        await processLate(1)
        let oldDraft = Task { await processLate(2) }
        let deadline = Date().addingTimeInterval(2)
        while !(await lateTranslator.waiting), Date() < deadline { await Task.yield() }
        try require(await lateTranslator.waiting, "english_preview_in_flight_for_revision_test")
        await processLate(3, final: true)
        await lateTranslator.release()
        await oldDraft.value
        try require(lateModel.captions[0].translated == "译:" + corrected && !lateModel.captions[0].isDraft,
                    "english_late_positive_draft_cannot_overwrite_corrected_negative_final")
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
            let expected = mode == "disabled" || mode == "fullSentence" ? [full] : [prefix, full]
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
        let flowChecks = try await checkTranslationFlow(directory: directory, defaults: englishDefaults)
        checks += flowChecks
        return checks
    }
}

private actor SlowFinalTranslator: TextTranslating {
    var inputs: [String] = []
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        inputs.append(text)
        try await Task.sleep(for: .milliseconds(35))
        return "译:" + text
    }
}

extension ClipV123Checks {
    @MainActor
    private static func checkTranslationFlow(directory: URL, defaults: UserDefaults) async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
            print("CHECK: " + name)
            fflush(stdout)
        }
        let store = LocalModelStore(root: directory.appendingPathComponent("no-models"))
        let late = LateClauseTranslator()
        let final = "We will not leave today but we can meet next week."
        let model = AppModel(defaults: defaults, modelStore: store,
            recognizer: PrefixTestRecognizer(["We will leave today but we", "We will leave today but we can meet", final]),
            translator: late)
        model.startLiveTranslationWorker()
        let id = UUID()
        for r in 1...2 {
            await model.process([Float](repeating: 0.1, count: r * 16_000), start: 0,
                                queueTranslation: true, id: id, revision: r, isFinal: false)
        }
        let previewDeadline = Date().addingTimeInterval(3)
        while !(await late.waiting), Date() < previewDeadline { try await Task.sleep(for: .milliseconds(5)) }
        let held = await late.waiting
        await model.process([Float](repeating: 0.1, count: 48_000), start: 0, queueTranslation: true, id: id, revision: 3)
        let finalDeadline = Date().addingTimeInterval(3)
        while model.captions.first?.isDraft == true, Date() < finalDeadline { try await Task.sleep(for: .milliseconds(5)) }
        let finishedAhead = model.captions.first?.translated == "译:" + final
        await late.release()
        await model.finishLiveTranslationWorker()
        try require(held && finishedAhead && model.captions.first?.translated == "译:" + final,
                    "english_live_final_finishes_while_old_preview_ignores_cancellation")
        let source = (1...4).map { number in
            "Yes. " + (1...7).map {
                "At stop \(number) the driver will not collect \($0) dollars until the doors open."
            }.joined(separator: " ")
        }
        let oversized = "https://example.invalid/" + String(repeating: "x", count: 450)
        let last = "The last passenger will not have to pay."
        let inputs = source + [oversized, last]
        let slow = SlowFinalTranslator()
        let backlog = AppModel(defaults: defaults, modelStore: store,
                               recognizer: PrefixTestRecognizer(inputs), translator: slow)
        // Reduce only the queue capacity to reach sustained overload in a deterministic short run.
        backlog.startLiveTranslationWorker(capacity: 1)
        for i in inputs.indices {
            await backlog.process([Float](repeating: 0.1, count: 16_000), start: Double(i * 2), queueTranslation: true)
        }
        await backlog.finishLiveTranslationWorker()
        let parts = try source.map(EnglishTranslationChunks.split)
        let flatten = parts.flatMap { $0 }
        try require(zip(source, parts).allSatisfy { original, split in
            split.count > 1 && split.first != "Yes." && split.joined(separator: " ") == original
        } && flatten.allSatisfy {
            $0.count <= EnglishTranslationChunks.characterLimit && $0.split(separator: " ").count <= EnglishTranslationChunks.wordLimit
        }, "english_long_final_preserves_every_word_and_bounded_semantic_chunks")
        try require(await slow.inputs == flatten + [last] && backlog.captions.map(\.original) == inputs
                    && backlog.errorMessage != nil && zip(backlog.captions, parts).allSatisfy { cue, split in
                        !cue.isDraft && cue.translated == split.map { "译:" + $0 }.joined(separator: "\n")
                    }, "english_slow_final_queue_saturation_reports_pressure_and_preserves_triggering_final_in_order")
        let failed = backlog.captions[source.count]
        try require(failed.isDraft && failed.original == oversized && failed.translated.hasPrefix("翻译失败")
                    && SubtitleDocument.completedTranslation(failed) == nil
                    && backlog.captions.last?.translated == "译:" + last,
                    "english_oversized_indivisible_token_has_visible_failure_retains_source_and_next_final_runs")
        let audioQueue = CaptionRevisionQueue<AudioSegment>(capacity: 1)
        func audio(_ final: Bool) -> AudioSegment {
            AudioSegment(id: UUID(), revision: 1, isFinal: final, samples: [1], timestamp: Date())
        }
        let draft = audio(false), first = audio(true), second = audio(true)
        _ = audioQueue.offer(draft)
        _ = audioQueue.offer(first)
        let (signal, started) = AsyncStream<Void>.makeStream()
        let producer = Task.detached {
            audioQueue.offerPreservingFinal(second) { started.yield(()); started.finish() }
        }
        for await _ in signal { break }
        let wasBounded = audioQueue.pendingCount == 1
        let firstOut = audioQueue.take()
        _ = await producer.value
        audioQueue.finish()
        try require(wasBounded && firstOut?.id == first.id && audioQueue.take()?.id == second.id,
                    "asr_bounded_queue_evicts_drafts_and_preserves_blocked_final_on_drain")
        return checks
    }
}
