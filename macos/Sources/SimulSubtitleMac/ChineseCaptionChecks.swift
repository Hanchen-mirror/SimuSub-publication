import Foundation

private struct ChineseFixtureRecognizer: SpeechRecognizing {
    let text: String
    func recognize(samples: [Float]) async throws -> String { text }
}

private actor ChineseCueCollector {
    private(set) var captions: [Caption] = []
    func receive(_ cue: Caption) {
        if let i = captions.firstIndex(where: { $0.id == cue.id }) { captions[i] = cue }
        else { captions.append(cue) }
    }
}

@MainActor
enum ChineseCaptionChecks {
    static func run(directory: URL, media: ClipMedia) async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
            print("CHECK: " + name)
        }
        let sentences = ["昨天还剩3.14元。", "今天可以用吗？", "“可以！”"]
        let text = sentences.joined()
        let tokens = [RecognizedSpeech.Token(text: sentences[0], time: 0),
                      .init(text: sentences[1], time: 1.85), .init(text: sentences[2], time: 3.2)]
        let timed = ChineseCaptionPhrases.split(.init(text: text, tokens: tokens), duration: 5, language: .simplifiedChinese)
        try require(timed.map(\.text) == sentences && timed.map(\.start) == [0, 1.85, 3.2] && timed.last?.end == 5,
                    "chinese_aligned_sentence_times_keep_decimal_and_closing_quote")
        let unpunctuated = "我們先把需要的東西放到桌子上然後把昨天收到的數據整理一遍最後一起核對每一項的總數"
        let untimed = ChineseCaptionPhrases.split(.init(text: unpunctuated), duration: 8, language: .traditionalChinese)
        try require(untimed.count >= 2 && untimed.map(\.text).joined() == unpunctuated
                    && untimed.allSatisfy { $0.text.count <= 24 && $0.end > $0.start }
                    && zip(untimed, untimed.dropFirst()).allSatisfy { $0.end == $1.start }
                    && untimed.contains { $0.text.hasPrefix("然後") },
                    "chinese_traditional_untimed_long_transcript_split_without_loss")
        let mixed = "桥下净空15米该项目于2011年8月完工然后换成IntelCorei9处理器重新核算3.14公里的路线"
        let mixedCues = ChineseCaptionPhrases.split(.init(text: mixed), duration: 11, language: .simplifiedChinese)
        try require(mixedCues.count >= 2 && mixedCues.map(\.text).joined() == mixed &&
                    ["15米", "2011年8月", "IntelCorei9", "3.14公里"].allSatisfy { token in mixedCues.contains { $0.text.contains(token) } },
                    "chinese_mixed_text_preserves_dates_units_and_identifiers")
        let suite = "SimuSub.ChinesePhraseCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh-Hans", forKey: "subtitle.sourceLanguage.v141")
        defaults.set("en", forKey: "subtitle.targetLanguage.v141")
        let recognizer = ChineseFixtureRecognizer(text: text)
        let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("empty")),
                             recognizer: recognizer, translator: OriginalTextTranslator(), modelDownloadsAllowed: false)
        let id = UUID()
        let samples = [Float](repeating: 0.1, count: 80_000)
        model.startLiveTranslationWorker()
        await model.process(samples, start: 2, queueTranslation: true, id: id, isFinal: false)
        let draftIDs = model.captions.map(\.id)
        await model.process(samples, start: 2, queueTranslation: true, id: id, revision: 2)
        await model.finishLiveTranslationWorker()
        let srt = SubtitleDocument.render(model.captions, format: .srt, mode: .bilingual)
        try require(model.captions.map(\.original) == sentences && model.captions.map(\.translated) == sentences
                    && model.captions.map(\.id) == draftIDs && model.captions.first?.id == id && model.captions.first?.start == 2
                    && model.captions.last?.end == 7 && model.captions.allSatisfy { !$0.isDraft && $0.sourceLanguage == .simplifiedChinese }
                    && srt.components(separatedBy: " --> ").count == 4,
                    "chinese_live_drafts_finalize_to_individually_translated_exportable_cues")
        let services = ClipServices(recognizer: recognizer, translator: OriginalTextTranslator(),
                                   sourceLanguage: .simplifiedChinese, targetLanguage: .english)
        let cues = try await transcribe(media: media, services: services)
        try require(cues.count >= 3 && cues.map(\.original) == cues.indices.map { sentences[$0 % sentences.count] }
                    && cues.allSatisfy { $0.translated == $0.original && $0.start >= 0 && $0.end > $0.start && $0.end <= media.duration },
                    "chinese_clip_vad_window_translates_and_persists_each_phrase")
        return checks
    }

    static func transcribe(media: ClipMedia, services: ClipServices) async throws -> [Caption] {
        let collector = ChineseCueCollector()
        try await ClipSpeechPipeline.transcribe(media: media, range: .init(title: "", start: 0, end: media.duration),
            services: services, existing: [], progress: { _, _ in }, onCue: { await collector.receive($0) }, onEnergy: { _ in })
        return await collector.captions
    }
}
