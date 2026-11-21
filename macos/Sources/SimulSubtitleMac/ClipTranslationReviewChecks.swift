import Foundation

private actor ReviewPassFixture: TextTranslating {
    let first: String, second: String
    private(set) var calls = 0
    init(_ first: String, _ second: String) { self.first = first; self.second = second }
    func translate(_ text: String, from source: String, to target: String) async throws -> String { first }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        calls += 1
        return context.instructions.isEmpty ? first : second
    }
}

enum ClipTranslationReviewChecks {
    static func run() async throws -> [String] {
        let cases = [
            ("え、待って。", "等一下。", "诶，等一下。", "诶，等一下。", 2, "recovers_audible_reaction"),
            ("でも待って。", "等一下。", "不过，别等一下。", "等一下。", 2, "rejects_new_negation"),
            ("え、1577かな？", "1577吗？", "诶，是1578吗？", "1577吗？", 2, "rejects_changed_code"),
            ("え、1577かな？", "嗯，1577年吧？", "诶，1577吧？", "诶，1577吧？", 2, "bare_code_carries_no_calendar_unit"),
            ("え、-5度？", "-5度？", "诶，5度？", "-5度？", 2, "protects_negative_temperature"),
            ("え、見て。", "看。", "看什么？", "看。", 2, "rejects_new_question_in_imperative"),
            ("おさかな。", "鱼。", "鱼吗？", "鱼。", 1, "word_boundary_protects_fish"),
            ("ちょ、雨が降ってきた。", "啊、下雨了。", "", "等等，下雨了。", 1, "restores_interruption_at_clause_opening"),
            ("え？ は？ どこ？", "咦？是？哪里？", "", "咦？哈？哪里？", 1, "isolated_disbelief_keeps_its_meaning"),
            ("6、8、なんとか！", "6、8、なんとか！", "", "6，8，什么来着！", 1, "numeric_list_translates_recalled_placeholder"),
            ("なんとかなる。", "总会有办法。", "", "总会有办法。", 1, "lexical_somehow_remains_distinct"),
            ("覚えてない。", "没记住。", "诶，没记住。", "没记住。", 1, "ignores_kana_inside_word"),
            ("えっと……", "嗯，这样吧。", "呃……", "呃……", 2, "isolated_hesitation_has_no_decision"),
            ("だから帰ろう。", "所以回去吧。", "", "所以回去吧。", 1, "keeps_existing_connective"),
            ("065、065？", "65。", "", "065、065？", 1, "preserves_repeated_code_and_leading_zero")
        ]
        var checks: [String] = []
        for (source, first, second, expected, calls, label) in cases {
            let fixture = ReviewPassFixture(first, second)
            let result = try await ClipJapaneseTranslationReview(base: fixture).translate(source, from: "ja", to: "zh")
            guard result == expected, await fixture.calls == calls else { throw ClipError.message("CHECK FAILED: " + label) }
            checks.append("clip_translation_" + label)
        }
        return checks
    }

    @MainActor
    static func audit(corpus: URL, modelRoot: URL, directory: URL) async throws {
        let root = LocalModelStore(root: modelRoot)
        let suite = "SimuSub.ClipTranslationAudit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(defaults: defaults, modelStore: root, modelDownloadsAllowed: false)
        let services = try await app.makeClipServices(configured: false, source: .japanese, target: .simplifiedChinese)
        let baseline = try LocalLlamaTranslator(modelPath: root.translationModelPath)
        let lines = try String(contentsOf: corpus, encoding: .utf8).split(whereSeparator: \.isNewline)
        let cues = try lines.map { line -> (Double, Double, String) in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3, let start = Double(fields[0]), let end = Double(fields[1]), start < end else {
                throw ClipError.message("字幕评测需要起点、终点和日语原文三列。")
            }
            return (start, end, String(fields[2]))
        }
        var rows: [[String: Any]] = []
        for (index, cue) in cues.enumerated() {
            let prior = cues[..<index].suffix(2).map { SubtitleTranslationContext.Line(original: $0.2, translated: "") }
            let next = cues.dropFirst(index + 1).prefix(1).map { $0.2 }
            let context = SubtitleTranslationContext(previous: prior, following: next)
            let before = try await baseline.translate(cue.2, from: "日语", to: "简体中文", context: context)
            let reviewed = try await services.translator.translate(cue.2, from: "日语", to: "简体中文", context: context)
            rows.append(["start": cue.0, "end": cue.1, "source": cue.2, "baseline": before, "reviewed": reviewed])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("translations.json"))
    }

    static func compare(base: any TextTranslating, directory: URL) async throws {
        let reviewed = ClipJapaneseTranslationReview(base: base)
        let samples = ["んで、えっと……", "えっと", "え、待って。", "え、1577かな？", "あ、見ちゃダメ、見ちゃダメ！",
                       "数字も……覚えてない。", "すうじも", "三いけんじゃないかな", "入った、入った！", "でもさ、この重いの置いちゃおう。"]
        var rows: [[String: String]] = []
        for text in samples {
            let before = try await base.translate(text, from: "日语", to: "简体中文")
            let after = try await reviewed.translate(text, from: "日语", to: "简体中文")
            rows.append(["original": text, "singlePass": before, "reviewed": after])
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("clip-translation-ab.json"))
    }
}
