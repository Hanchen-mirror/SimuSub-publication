import Foundation

private actor RevisionRecognizer: SpeechRecognizing {
    var index = 0
    let texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func recognize(samples: [Float]) async throws -> String {
        defer { index += 1 }
        return texts[min(index, texts.count - 1)]
    }
}
private struct RevisionTranslator: TextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String { "译：" + text }
}
@MainActor
enum ClipV124Checks {
    static func run(directory: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        try require(SpeechAudioFrontend.finalRange(vad: 120..<300, draft: 100..<320) == 100..<320, "v124_final_covers_draft_start_and_end")
        try require(SpeechAudioFrontend.finalRange(vad: 80..<350, draft: 100..<320) == 80..<350, "v124_vad_extra_audio_preserved")
        try require(SpeechAudioFrontend.finalRange(vad: 400..<600, draft: nil) == 400..<600, "v124_new_utterance_does_not_reuse_old_range")
        try require(SpeechAudioFrontend.originalSamples(fallback: [1,2,3,4,5], start: 10, raw: [30,40,50], rawStart: 12) == [1,2,30,40,50], "v124_missing_raw_prefix_does_not_shift_or_shorten_audio")
        try require(SpeechAudioFrontend.originalSamples(fallback: [1,2,3,4,5], start: 10, raw: [0,10,20], rawStart: 9) == [10,20,3,4,5], "v124_missing_raw_tail_keeps_fallback")
        let voiced = [Float](repeating: 0.15, count: EnglishAudioEndpoint.frame)
        let gap = [Float](repeating: 0.008, count: EnglishAudioEndpoint.frame)
        var englishBoundary = EnglishAudioEndpoint()
        _ = englishBoundary.pause(in: voiced, duration: 63_000)
        try require(englishBoundary.pause(in: gap, duration: 64_000) == nil &&
                    englishBoundary.pause(in: gap, duration: 64_512) == nil &&
                    englishBoundary.pause(in: gap, duration: 65_024) == .afterFrame, "english_audio_prefers_sustained_gap_after_four_seconds")
        let silence = [Float](repeating: 0.0001, count: 512)
        var shortPause = EnglishAudioEndpoint()
        _ = shortPause.pause(in: voiced, duration: 47_000)
        try require(shortPause.pause(in: silence, duration: 47_512) == nil &&
                    shortPause.pause(in: Array(silence.prefix(384)) + Array(voiced.prefix(128)), duration: 48_024) == .beforeFrame,
                    "english_deep_inter_sentence_pause_at_three_seconds_keeps_next_onset")
        var continuousSpeech = EnglishAudioEndpoint()
        try require((1...170).allSatisfy { continuousSpeech.pause(in: voiced, duration: $0 * 512) == nil },
                    "english_continuous_speech_does_not_cut_at_three_seconds")
        var lookahead = [Float](repeating: 0.15, count: EnglishAudioEndpoint.lookahead)
        let quietRange = (7 * 512)..<(9 * 512)
        lookahead.replaceSubrange(quietRange, with: Array(repeating: 0.001, count: quietRange.count))
        let boundary = EnglishAudioEndpoint.quietestOffset(in: lookahead[...])
        try require(boundary == 8 * 512 && lookahead.count - boundary >= 6 * 512,
                    "english_audio_hard_limit_chooses_quietest_boundary_with_following_context")
        try require(!SubtitleProcessingOptions().liveEnglishToChinese, "file_and_other_language_endpoints_remain_opt_in")
        var profile = ServiceProfile.deepSeek
        let cue = [Float](repeating: 0.01, count: 8_000)
        let room = [Float](repeating: 0.0003, count: 5_120)
        let end = cue.count, observedEnd = end + room.count
        let quietTail = SpeechAudioFrontend.quietTail(in: cue + room, endingAt: end, processed: observedEnd, cueLength: end)
        try require(quietTail == room, "quiet_asr_context_uses_the_observed_samples")
        try require(SpeechAudioFrontend.quietTail(in: cue + room, endingAt: end, processed: end + 480, cueLength: end).isEmpty,
                    "quiet_asr_context_cannot_read_unobserved_frames")
        var nextVoice = room
        nextVoice.replaceSubrange(4_096..<4_608, with: [Float](repeating: 0.01, count: 512))
        try require(SpeechAudioFrontend.quietTail(in: cue + nextVoice, endingAt: end, processed: observedEnd, cueLength: end).isEmpty,
                    "quiet_asr_context_rejects_the_next_voice")
        let segment = AudioSegment(id: UUID(), revision: 1, isFinal: true, samples: cue, timestamp: Date(), quietRecognitionTail: quietTail)
        try require(segment.samples.count == end && segment.quietRecognitionTail.count == room.count,
                    "quiet_asr_context_preserves_the_caption_sample_clock")
        let oldData = try JSONEncoder().encode(profile)
        let legacy = try JSONDecoder().decode(ServiceProfile.self, from: oldData)
        try require(legacy.effectiveTranslationPrompt == ServiceProfile.defaultTranslationPrompt, "v124_old_profiles_get_default_prompt")
        profile.translationPrompt = "主播在玩 FF11，不要总结"
        let restored = try JSONDecoder().decode(ServiceProfile.self, from: JSONEncoder().encode(profile))
        try require(restored.translationPrompt == profile.translationPrompt, "v124_custom_prompt_roundtrip")
        profile.translationPrompt = "  "
        try require(profile.effectiveTranslationPrompt.isEmpty, "v124_clear_disables_extra_prompt")
        profile.translationPrompt = String(repeating: "字", count: 2500)
        try require(profile.effectiveTranslationPrompt.count == 2000, "v124_prompt_payload_bounded")
        for final in ["", "明日は行きません", "今日はゲームをして明日は行きません"] {
            let suite = "simusub.v124." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = "今日はゲームをして明日は行きます"
            let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("none")), recognizer: RevisionRecognizer([first, final]), translator: RevisionTranslator())
            let id = UUID()
            await model.process([Float](repeating: 0.1, count: 16000), start: 0, id: id, revision: 1, isFinal: false)
            await model.process([Float](repeating: 0.1, count: 32000), start: 0, id: id, revision: 2)
            try require(model.captions.count == 1, "v124_revision_never_deletes_caption_\(checks.count)")
            let caption = model.captions[0]
            if final.isEmpty {
                try require(caption.original == first && !caption.isDraft && !SubtitleDocument.render([caption], format: .srt, mode: .bilingual).isEmpty, "v136_empty_final_translates_retained_source")
            } else if final == "明日は行きません" {
                try require(caption.original == final && caption.pendingOriginal == nil && !caption.recognitionNeedsReview && !caption.isDraft && caption.originalRevisions.contains(first),
                    "v136_revised_source_translates_without_review_and_keeps_history")
            } else {
                try require(caption.original == final && caption.originalRevisions == [first] && !caption.isDraft, "v124_correction_keeps_prior_text_without_concatenation_\(checks.count)")
            }
            let decoded = try JSONDecoder().decode(Caption.self, from: JSONEncoder().encode(caption))
            try require(decoded == caption, "v124_revision_history_serializes_\(checks.count)")
        }
        return checks
    }
}
