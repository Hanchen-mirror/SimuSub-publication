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
            try require(reviewModel.captions[0].original == heard && reviewModel.captions[0].pendingOriginal == lost && before.isEmpty
                && SubtitleDocument.render(reviewModel.captions, format: .srt, mode: .bilingual).isEmpty, "v125_rollback_neither_erases_nor_translates_or_exports_\(chooseNew)")
            if !chooseNew {
                try await ClipV120Checks.snapshot(CaptionRow(caption: reviewModel.captions[0]).environmentObject(reviewModel).preferredColorScheme(.dark),
                    size: CGSize(width: 760, height: 320), output: directory.appendingPathComponent("rollback-review.png"))
                try require(true, "v125_pending_review_native_ui_rendered")
            }
            await reviewModel.resolveRecognition(reviewID, useCandidate: chooseNew)
            let after = await probe.sources
            try require(after == [chooseNew ? lost : heard] && !reviewModel.captions[0].isDraft && reviewModel.captions[0].pendingOriginal == nil,
                "v125_review_choice_translates_once_and_completes_\(chooseNew)")
        }
        let failing = RepairTranslator(failFirst: true)
        let retryModel = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")),
            recognizer: TimedRecognizer([.init(text: heard), .init(text: lost)]), translator: failing)
        let retryID = UUID()
        await retryModel.process([Float](repeating: 0.1, count: 32000), start: 0, id: retryID, revision: 1, isFinal: false)
        await retryModel.process([Float](repeating: 0.1, count: 64000), start: 0, id: retryID, revision: 2)
        await retryModel.resolveRecognition(retryID, useCandidate: false)
        let failedCalls = await failing.sources
        try require(retryModel.captions[0].original == heard && retryModel.captions[0].recognitionNeedsReview && failedCalls.count == 1,
            "v125_review_translation_failure_preserves_choice_no_auto_retry")
        await retryModel.resolveRecognition(retryID, useCandidate: false)
        let retryCalls = await failing.sources
        try require(!retryModel.captions[0].isDraft && retryCalls == [heard, heard], "v125_review_manual_retry_completes_once")
        var temporary = ASRRevisionGuard()
        _ = temporary.protectRollback(heard, start: 0, end: 2)
        try require(temporary.protectRollback(lost, start: 0, end: 3).pending == lost, "v125_temporary_drop_keeps_candidate")
        let resumed = temporary.protectRollback(heard + "そう思います", start: 0, end: 4)
        try require(resumed.pending == nil && resumed.text == heard + "そう思います", "v125_good_later_revision_resumes_without_manual_review")
        return checks
    }
}
