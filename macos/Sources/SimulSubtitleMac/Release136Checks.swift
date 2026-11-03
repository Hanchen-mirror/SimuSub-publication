import Foundation

private actor Revision136Recognizer: SpeechRecognizing {
    var values: [String]
    init(_ values: [String]) { self.values = values }
    func recognize(samples: [Float]) async throws -> String { values.removeFirst() }
}
private actor Revision136Translator: TextTranslating {
    private(set) var sources: [String] = []
    func translate(_ text: String, from: String, to: String) async throws -> String {
        sources.append(text); return "完整译文：" + text
    }
}
@MainActor
enum Release136Checks {
    static func translation() async throws {
        let suite = "SimuSub.v136.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "speech.stablePrefixes.v123")
        let latest = "だからさ高校の受験勉強はほとんどしてなくて"
        let engine = Revision136Translator()
        let model = AppModel(defaults: defaults,
            recognizer: Revision136Recognizer(["高校入っちゃったからさ", latest, "べんきょうしたといったら", "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "", "以前の長い識別結果をそのままにしない", "短い訂正"]), translator: engine)
        for (index, expected) in [latest, "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "短い訂正"].enumerated() {
            let id = UUID(), start = Double(index * 10)
            await model.process([0.1, 0.2], start: start, id: id, revision: 1, isFinal: false)
            await model.process([0.1, 0.2, 0.3], start: start, id: id, revision: 2, isFinal: true)
            guard let cue = model.captions.last, cue.original == expected, !cue.isDraft,
                  cue.pendingOriginal == nil, !cue.recognitionNeedsReview,
                  SubtitleDocument.completedTranslation(cue) == "完整译文：" + expected else {
                throw ServiceError.invalidResponse
            }
        }
        let sent = await engine.sources
        guard sent == [latest, "勉強したといったら面接と", "長い日語の草稿を最後まで保存します", "短い訂正"] else { throw ServiceError.invalidResponse }
        print("v1.36: revised Japanese, empty final fallback and complete-source translation passed")
    }
}
