import CryptoKit
import Foundation

@MainActor
enum ClipJapaneseRecoveryChecks {
    static func run(fixture: URL, root: URL, output: URL) async throws -> [String] {
        var checks = [String]()
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        let suite = "SimuSub.ClipJapaneseRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: root), modelDownloadsAllowed: false)
        let source = SubtitleLanguage.japanese, target = SubtitleLanguage.simplifiedChinese
        guard let asr = model.recognitionProfile(for: source), asr.kind == .local,
              let mt = model.profiles.first(where: { $0.id == model.selectedTranslationProfileID && $0.kind == .local }) else {
            throw ClipError.message("Missing local test services")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode([asr, mt])
        data.append(contentsOf: try encoder.encode([source, target]))
        data.append(contentsOf: try encoder.encode(model.glossary))
        data.append(model.asrHotwordsEnabled ? 1 : 0)
        let legacyKey = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = try model.clipGenerationKey(source: source, target: target)
        try require(key != legacyKey, "japanese_lamp_invalidates_v161_completed_cache")
        let store = ClipStore(root: output.appendingPathComponent("store"))
        let id = try await store.importVideo(fixture)
        var range = store.projects[0].wholeRange
        let manual = Caption(start: 0.2, end: 0.4, original: "校对原文", translated: "保留手工修改")
        let old = Caption(start: 74.3, end: 78.9, original: "ただいずれにしろね", translated: "总之")
        range.generation = ClipGeneration(serviceKey: legacyKey, span: range.start...range.end, captions: [old], complete: true)
        range.captionEdits = [manual]
        store.update(id) { p in
            p.captions = [old]
            p.ranges = [range]
            p.analysisCoverage = [range.start...range.end]
        }
        store.start(ClipJob(projectID: id, kind: .transcribe, range: range, configuredServices: true,
                            generationServiceKey: key, sourceLanguage: source, targetLanguage: target), model: model)
        while store.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        guard store.jobs.first?.state == .completed else { throw ClipError.message(store.jobs.first?.message ?? "Missing lamp job") }
        let reopened = ClipStore(root: store.root)
        let project = reopened.projects[0], saved = project.ranges[0]
        guard let generated = saved.generation, generated.serviceKey == key, generated.complete else { throw ClipError.message("Missing regenerated track") }
        let cues = generated.captions
        try encoder.encode(cues).write(to: output.appendingPathComponent("captions.json"))
        try SubtitleDocument.render(cues, format: .srt, mode: .bilingual)
            .write(to: output.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)
        try require(project.captions(for: saved).contains(manual), "japanese_lamp_preserves_manual_edit_on_reopen")
        try require(cues.allSatisfy { !$0.original.isEmpty && !$0.translated.isEmpty && $0.start < $0.end }
                    && zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start + 0.001 }, "japanese_lamp_translated_timestamps_do_not_overlap")
        let recovered = cues.filter { $0.start >= 55 && $0.start < 74.3 }.map(\.original).joined()
        for word in ["スポンサ", "十二月四日", "七百八十円", "スマートフォン", "三十", "八百四十円"] {
            try require(recovered.contains(word), "japanese_feedback_recovers_" + word)
        }
        let translated = cues.filter { $0.start >= 55 && $0.start < 74.3 }.map(\.translated).joined()
        try require(translated.range(of: #"(?:十二|12)月(?:四|4)[日号]"#, options: .regularExpression) != nil,
                    "japanese_feedback_translation_december_4")
        for (amount, characters) in [("780", "七百八十"), ("840", "八百四十")] {
            let pattern = "(?:" + amount + "|" + characters + ")\\s*(?:日元|日圆|日圓|日币|日幣|円)"
            try require(translated.range(of: pattern, options: .regularExpression) != nil, "japanese_feedback_translation_yen_" + amount)
        }
        try require(translated.range(of: #"七折|7折|(?:优惠|减价|折扣)(?:30%|30％|百分之三十)"#, options: .regularExpression) != nil,
                    "japanese_feedback_translation_mobile_discount")
        // An unsupported silent hole must not gain text from one decoding pass.
        let tail = TimedCaptionPhrase(text: "おわり", start: 4, end: 12)
        var calls = 0
        let unchanged = try await ClipJapaneseRecovery.fill([tail], samples: Array(repeating: 0.1, count: 192_000),
                                                             forTranslation: false) { _ in
            calls += 1
            let text = calls == 1 ? "ようこそ" : "さよなら"
            return RecognizedSpeech(text: text, tokens: text.enumerated().map { .init(text: String($0.element), time: 0.2 * Double($0.offset)) })
        }
        try require(calls == 2 && unchanged == [tail], "japanese_lamp_rejects_uncorroborated_gap")
        return checks
    }
}
