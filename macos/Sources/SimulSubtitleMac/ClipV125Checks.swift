import Foundation
import SwiftUI

private actor TimedRecognizer: SpeechRecognizing {
    var index = 0
    let outputs: [RecognizedSpeech]
    init(_ outputs: [RecognizedSpeech]) { self.outputs = outputs }
    func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        defer { index += 1 }; return outputs[min(index, outputs.count - 1)]
    }
}
private actor RepairTranslator: TextTranslating {
    var sources: [String] = []
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    nonisolated let requiresFullUtterance = true
    func translate(_ text: String, from source: String, to target: String) async throws -> String { sources.append(text); if failFirst && sources.count == 1 { throw URLError(.timedOut) }; return "译：" + text }
}
@MainActor enum ClipV125Checks {
    static func run(directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func speech(_ text: String, offset: Double = 0) -> RecognizedSpeech {
            .init(text: text, tokens: text.enumerated().map { .init(text: String($0.element), time: offset + Double($0.offset) * 0.2) })
        }
        let full = speech("今日はゲームをしていますとても楽しいです")
        var changedBeginning = full
        changedBeginning.tokens[0].text = "明"
        changedBeginning.text = changedBeginning.tokens.map(\.text).joined()
        var gap = full
        gap.tokens.removeSubrange(5..<14)
        gap.text = gap.tokens.map(\.text).joined()
        var timedGap = ASRRevisionGuard()
        _ = timedGap.reconcile(changedBeginning, start: 0, end: 5, recoverShortOmissions: true)
        _ = timedGap.reconcile(full, start: 0, end: 6, recoverShortOmissions: true)
        try require(timedGap.reconcile(gap, start: 0, end: 7, recoverShortOmissions: true).text == full.text,
                    "japanese_independent_local_agreement_repairs_long_silent_hole")
        var singlePass = ASRRevisionGuard()
        _ = singlePass.reconcile(full, start: 0, end: 5, recoverShortOmissions: true)
        try require(!singlePass.reconcile(gap, start: 0, end: 7, recoverShortOmissions: true).restored,
                    "japanese_unconfirmed_single_pass_cannot_fill_hole")
        var witnesses = JapaneseTimedAgreement()
        witnesses.observe(previous: full.tokens, current: full.tokens, previousEnd: 5)
        let missingHead = Array(full.tokens.dropFirst(14))
        let hole = RecognizedSpeech(text: missingHead.map(\.text).joined(), tokens: missingHead)
        var retries = 0
        let verified = try await witnesses.verifyingAudio(in: hole, preliminary: hole,
            samples: [Float](repeating: 0.1, count: 6 * 16000), start: 0) { _ in
                retries += 1
                return full
            }
        try require(retries == 1 && verified.text == full.text, "japanese_acoustic_gap_verified_from_real_samples")
        let rejected = try await witnesses.verifyingAudio(in: hole, preliminary: hole,
            samples: [Float](repeating: 0.1, count: 6 * 16000), start: 0) { _ in speech("完全別内容") }
        try require(rejected.text == hole.text, "japanese_gap_rejects_unrelated_retry")
        let blank = RecognizedSpeech(text: "", tokens: [])
        let recoveredBlank = try await witnesses.verifyingAudio(in: blank, preliminary: blank,
            samples: [Float](repeating: 0.1, count: 6 * 16000), start: 0) { _ in full }
        try require(recoveredBlank.text == full.text,
                    "japanese_empty_final_requires_matching_draft_and_acoustic_retry")
        func timed(_ text: String, _ times: [Double]) -> RecognizedSpeech {
            .init(text: text, tokens: zip(text, times).map { .init(text: String($0), time: $1) })
        }
        let acoustic = timed("前空色光後", [0.2, 0.65, 1.1, 1.45, 2.1])
        let borders = timed("前後", [0.2, 2.1])
        var gapEvidence = JapaneseTimedAgreement()
        gapEvidence.observe(previous: acoustic.tokens, current: acoustic.tokens, previousEnd: 3)
        let protected = timed("前旧後", [0.2, 1.1, 2.1])
        let recheck = try await gapEvidence.verifyingAudio(in: borders, preliminary: protected,
            samples: [Float](repeating: 0.1, count: 3 * 16000), start: 0) { _ in acoustic }
        try require(recheck.text == protected.text, "japanese_short_retry_never_replaces_existing_timed_word")
        let sparse = timed("前色後", [0.2, 1.1, 2.1])
        let extended = try await gapEvidence.verifyingAudio(in: borders, preliminary: sparse,
            samples: [Float](repeating: 0.1, count: 3 * 16000), start: 0) { _ in acoustic }
        try require(extended.text == acoustic.text, "japanese_short_retry_adds_only_corroborated_timed_words")
        let greeting = "ありがとう君のおかげで全部分かった"
        var greetingSpeech = speech(greeting)
        greetingSpeech.tokens = greeting.enumerated().map { i, char in
            .init(text: String(char), time: i == 0 ? 0 : 12 + Double(i) * 0.25)
        }
        let sungGreeting = JapaneseCaptionPhrase.split(greetingSpeech, duration: 17, forTranslation: true)
        try require(sungGreeting.count == 1 && sungGreeting.first?.text == greeting
                    && (sungGreeting.first?.start ?? 0) > 10,
                    "japanese_initial_timestamp_outlier_cannot_split_word_or_extend_caption_through_intro")
        let farewell = speech("返事を読んだその一言ですべてを知った。外は明るくなった。")
        let units = JapaneseCaptionPhrase.split(farewell, duration: 8, forTranslation: true)
        try require(units.count == 2 && units[0].text == "返事を読んだその一言ですべてを知った。"
                    && units.map(\.text).joined() == farewell.text,
                    "japanese_translation_keeps_particle_and_its_predicate_until_sentence_boundary")
        let repeated = speech(String(repeating: "また明日会いましょう", count: 7))
        let phrases = JapaneseCaptionPhrase.split(repeated, duration: 15)
        try require(phrases.count >= 3 && phrases.map(\.text).joined() == repeated.text
                    && phrases.allSatisfy { $0.text.count <= 22 && $0.end - $0.start <= 7.1 }
                    && zip(phrases, phrases.dropFirst()).allSatisfy { $0.end <= $1.start },
                    "japanese_timed_phrases_preserve_repeats_and_order")
        try require(JapaneseCaptionPhrase.split(.init(text: repeated.text), duration: 15).count == 1,
                    "japanese_untimed_result_remains_whole")
        var omitted = full
        omitted.tokens.removeFirst(3); omitted.text = omitted.tokens.map(\.text).joined()
        var guardState = ASRRevisionGuard()
        _ = guardState.reconcile(full, start: 0, end: 5)
        _ = guardState.reconcile(full, start: 0, end: 6)
        let repaired = guardState.reconcile(omitted, start: 0, end: 7)
        try require(repaired.restored && repaired.text == full.text, "v125_confirmed_timed_prefix_omission_restored_once")
        var middle = full; middle.tokens.removeSubrange(5..<8); middle.text = middle.tokens.map(\.text).joined()
        let middleRepair = guardState.reconcile(middle, start: 0, end: 8)
        try require(middleRepair.restored && middleRepair.text == full.text, "v125_confirmed_timed_middle_omission_restored")
        for count in 1...2 {
            var short = full
            short.tokens.removeSubrange(5..<(5 + count))
            short.text = short.tokens.map(\.text).joined()
            var timed = ASRRevisionGuard()
            _ = timed.reconcile(full, start: 0, end: 5)
            _ = timed.reconcile(full, start: 0, end: 6)
            try require(timed.reconcile(short, start: 0, end: 7, recoverShortOmissions: true).text == full.text,
                        "japanese_short_timed_gap_restored_\(count)")
            var prefix = full
            prefix.tokens.removeFirst(count)
            prefix.text = prefix.tokens.map(\.text).joined()
            try require(!timed.reconcile(prefix, start: 0, end: 8, recoverShortOmissions: true).restored,
                        "japanese_short_unanchored_gap_stays_revisable_\(count)")
        }
        var fresh = ASRRevisionGuard()
        _ = fresh.reconcile(full, start: 0, end: 5)
        try require(!fresh.reconcile(omitted, start: 0, end: 6).restored, "v125_single_hypothesis_not_locked")
        var repeatAudio = ASRRevisionGuard()
        _ = repeatAudio.reconcile(full, start: 0, end: 5)
        _ = repeatAudio.reconcile(full, start: 0, end: 5)
        try require(!repeatAudio.reconcile(omitted, start: 0, end: 6).restored, "v125_same_audio_does_not_confirm")
        var substitution = full
        substitution.tokens[0].text = "明"; substitution.text = substitution.tokens.map(\.text).joined()
        try require(guardState.reconcile(substitution, start: 0, end: 9).text == substitution.text, "v125_real_substitution_remains_allowed")
        try require(!guardState.reconcile(omitted, start: 0, end: 9.5).restored, "v125_corrected_word_never_resurrects_from_old_confirmation")
        var negativeGuard = ASRRevisionGuard()
        let positive = speech("今日はここには行きますけれどそうですね")
        let negative = speech("今日はここには行きませんけれどそうですね")
        _ = negativeGuard.reconcile(positive, start: 0, end: 5)
        _ = negativeGuard.reconcile(positive, start: 0, end: 6)
        try require(negativeGuard.reconcile(negative, start: 0, end: 7).text == negative.text, "v125_negation_correction_preserved")
        var suffix = full; suffix.tokens.removeLast(5); suffix.text = suffix.tokens.map(\.text).joined()
        try require(!guardState.reconcile(suffix, start: 0, end: 10).restored, "v125_unanchored_tail_not_invented")
        try require(!guardState.reconcile(omitted, start: 1, end: 11).restored, "v125_different_audio_start_invalidates_guard")
        try require(!guardState.reconcile(.init(text: full.text), start: 0, end: 12).restored, "v125_no_timestamps_no_guessed_alignment")
        let suite = "simusub.v125." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = RepairTranslator()
        let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")), recognizer: TimedRecognizer([full,full,omitted]), translator: translator)
        let id = UUID()
        for revision in 1...3 {
            await model.process([Float](repeating: 0.1, count: (revision + 4) * 16000), start: 0, id: id, revision: revision, isFinal: revision == 3)
        }
        let sources = await translator.sources
        try require(model.captions[0].original == full.text && !model.captions[0].isDraft && sources == [full.text], "v125_live_pipeline_translates_repaired_source_once")
        try require(model.captions[0].original == full.text, "v125_timed_omission_not_overwritten")
        let lost = "そうですよね"
        let heard = "日本家屋だとたまに不便ですよね"
        for chooseNew in [false, true] {
            let probe = RepairTranslator()
            let reviewModel = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
                recognizer: TimedRecognizer([.init(text: heard), .init(text: lost)]), translator: probe)
            let reviewID = UUID()
            await reviewModel.process([Float](repeating: 0.1, count: 32000), start: 0, id: reviewID, revision: 1, isFinal: false)
            await reviewModel.process([Float](repeating: 0.1, count: 64000), start: 0, id: reviewID, revision: 2)
            let before = await probe.sources
            try require(reviewModel.captions[0].original == lost && reviewModel.captions[0].pendingOriginal == nil && before == [lost]
                && reviewModel.captions[0].originalRevisions.contains(heard) && !SubtitleDocument.render(reviewModel.captions, format: .srt, mode: .bilingual).isEmpty, "v136_revision_translates_immediately_and_keeps_history_\(chooseNew)")
            if !chooseNew {
                try await ClipV120Checks.snapshot(CaptionRow(caption: reviewModel.captions[0]).environmentObject(reviewModel).preferredColorScheme(.dark),
                    size: CGSize(width: 760, height: 320), output: directory.appendingPathComponent("rollback-review.png"))
                try require(true, "v136_completed_revision_native_ui_rendered")
            }
            await reviewModel.resolveRecognition(reviewID, useCandidate: chooseNew)
            let after = await probe.sources
            try require(after == [lost] && !reviewModel.captions[0].isDraft && reviewModel.captions[0].pendingOriginal == nil,
                "v136_legacy_review_action_does_not_duplicate_translation_\(chooseNew)")
        }
        let failing = RepairTranslator(failFirst: true)
        let retryModel = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
            recognizer: TimedRecognizer([.init(text: heard), .init(text: lost)]), translator: failing)
        let retryID = UUID()
        await retryModel.process([Float](repeating: 0.1, count: 32000), start: 0, id: retryID, revision: 1, isFinal: false)
        await retryModel.process([Float](repeating: 0.1, count: 64000), start: 0, id: retryID, revision: 2)
        let failedCalls = await failing.sources
        try require(retryModel.captions[0].original == lost && !retryModel.captions[0].recognitionNeedsReview && failedCalls.count == 1 && retryModel.captions[0].translated.hasPrefix("翻译失败"),
            "v125_review_translation_failure_preserves_choice_no_auto_retry")
        await retryModel.retryTranslation(retryID)
        let retryCalls = await failing.sources
        try require(!retryModel.captions[0].isDraft && retryCalls == [lost, lost], "v125_review_manual_retry_completes_once")
        var temporary = ASRRevisionGuard()
        _ = temporary.protectRollback(heard, start: 0, end: 2)
        try require(temporary.protectRollback(lost, start: 0, end: 3).pending == lost, "v125_temporary_drop_keeps_candidate")
        let resumed = temporary.protectRollback(heard + "そう思います", start: 0, end: 4)
        try require(resumed.pending == nil && resumed.text == heard + "そう思います", "v125_good_later_revision_resumes_without_manual_review")
        return checks
    }
}
