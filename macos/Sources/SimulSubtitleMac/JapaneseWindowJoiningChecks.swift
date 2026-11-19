import Foundation

private actor WindowRecognitionFixture: JapaneseWindowRecognizing {
    var utterances: [String]
    init(_ utterances: [String]) { self.utterances = utterances }
    func recognize(samples: [Float]) async throws -> String {
        guard !utterances.isEmpty else { throw ServiceError.emptyResponse }
        return utterances.removeFirst()
    }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        let text = try await recognize(samples: samples)
        return .init(text: text, tokens: text.enumerated().map {
            .init(text: String($0.element), time: Double($0.offset) / Double(text.count) * Double(samples.count) / 16000)
        })
    }
}

@MainActor enum JapaneseWindowJoiningChecks {
    static func run(directory: URL, translator: any TextTranslating) async throws -> [String] {
        let suite = "SimuSub.JapaneseWindows." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ja", forKey: "subtitle.sourceLanguage.v141")
        defaults.set("zh-Hans", forKey: "subtitle.targetLanguage.v141")
        let open = ["私が探していたのは机の", "上ではなく引き出しにあった手帳だ。"]
        let closed = ["鉛筆を買った。", "昼から雨が降った。"]
        var checks: [String] = []
        for (name, source, forced, start, expected) in [
            ("forced_location", open, true, 3.0, 1), ("independent_sentences", closed, true, 3.0, 2),
            ("natural_endpoint", open, false, 3.0, 2), ("long_pause", open, true, 4.1, 2)
        ] {
            let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: directory.appendingPathComponent("japanese-window-fixture")),
                                 recognizer: WindowRecognitionFixture(source), translator: translator)
            let id = UUID()
            // Simulated recognized words and audio timing; use the real AppModel
            // final queue, installed Index translator, and subtitle export code.
            model.startLiveTranslationWorker()
            await model.process([Float](repeating: 0.1, count: 48000), start: 0, queueTranslation: true, id: id)
            await model.process([Float](repeating: 0.1, count: 64000), start: start, queueTranslation: true,
                                continuesForcedWindow: forced ? id : nil)
            await model.finishLiveTranslationWorker()
            let srt = SubtitleDocument.render(model.captions, format: .srt, mode: .bilingual)
            guard model.captions.count == expected, model.captions.map(\.original).joined() == source.joined(),
                  model.captions.allSatisfy({ !$0.isDraft && SubtitleDocument.completedTranslation($0) != nil }),
                  srt.components(separatedBy: " --> ").count - 1 == expected,
                  model.captions.allSatisfy({ srt.contains($0.original) && srt.contains($0.translated) }) else {
                throw ClipError.message("CHECK FAILED: japanese_window_" + name)
            }
            try srt.write(to: directory.appendingPathComponent("japanese-window-" + name + ".srt"), atomically: true, encoding: .utf8)
            let check = "japanese_window_" + name
            checks.append(check)
            print("CHECK: " + check); fflush(stdout)
        }
        return checks
    }
}
