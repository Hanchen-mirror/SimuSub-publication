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
        try streamCache()
        print("v1.36: revised Japanese, empty final fallback and complete-source translation passed")
    }
    static func streamCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-cache-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var creator = WatchedCreator(.init(platform: .bilibili, address: "https://live.bilibili.com/6", name: "测试"))
        creator.snapshot = .init(state: .live, sessionID: "session1")
        let input = ResolvedLiveInput(tracks: [.init(url: URL(string: "https://example.invalid/stream.flv")!, headers: ["Cookie": "secret", "Authorization": "secret", "Referer": creator.address], hasVideo: true, hasAudio: true)], title: "直播")
        BiliStreamCache(root: root).save(input, for: creator, cookies: "secret")
        let reopened = BiliStreamCache(root: root)
        guard reopened.input(for: creator, cookies: "secret")?.title == "直播" else { throw ServiceError.invalidResponse }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard files.count == 1, !(try String(contentsOf: files[0])).contains("secret"),
              reopened.input(for: creator, cookies: "changed") == nil else { throw ServiceError.invalidResponse }
        reopened.save(input, for: creator, cookies: nil, now: Date().addingTimeInterval(-700))
        guard reopened.input(for: creator, cookies: nil) == nil else { throw ServiceError.invalidResponse }
        reopened.save(input, for: creator, cookies: nil)
        creator.snapshot.sessionID = "session2"
        guard reopened.input(for: creator, cookies: nil) == nil else { throw ServiceError.invalidResponse }
        print("v1.36: private stream cache persistence, account/session invalidation and expiry passed")
    }

}
