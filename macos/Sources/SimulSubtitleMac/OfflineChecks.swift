import Foundation

enum OfflineChecks {
    @MainActor
    static func runBundled(audio: URL) async throws {
        guard let bundled = LocalModelStore.applicationModels else { throw ServiceError.modelFilesMissing }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-empty-" + UUID().uuidString)
        let suite = "SimuSub.BundleChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalModelStore(root: empty, bundledRoot: bundled)
        let app = AppModel(defaults: defaults, modelStore: store, modelDownloadsAllowed: false)
        guard LocalModelStore(root: empty).isASRInstalled == false,
              try store.missingDownloadBytes(for: .speechRecognition) == 0,
              try store.missingDownloadBytes(for: .translation) == 0,
              store.speechFolder.deletingLastPathComponent().standardizedFileURL.path == bundled.standardizedFileURL.path,
              LocalModelStore.isInsideApplication(URL(fileURLWithPath: store.translationModelPath))
        else { throw ServiceError.modelFilesMissing }
        print("BUNDLED: asr-ja, mt")
        for language in [SubtitleLanguage.japanese, .english, .simplifiedChinese] {
            guard let profile = app.recognitionProfile(for: language), app.localProfileInstalled(profile),
                  app.removal(for: profile) == nil, LocalModelStore.isInsideApplication(app.modelFolder(for: profile))
            else { throw ServiceError.modelNotInstalled(language.name) }
            print("LOCAL ROUTE: " + language.name + " → " + profile.model)
        }
        for id in ["sensevoice", "whisper-base", "whisper-small", "qwen3-asr"] {
            guard let model = LocalModelDefinition.catalog.first(where: { $0.id == id }),
                  app.localModels.isUsable(model), try app.localModels.missingDownloadBytes(for: model) == 0,
                  LocalModelStore.isInsideApplication(app.localModels.folder(for: model)),
                  let profile = app.profiles.first(where: { $0.localModelID == id }),
                  app.removal(for: profile) == nil else { throw ServiceError.modelNotInstalled(id) }
            try await app.localModels.install(model)
            print("BUNDLED: " + id)
        }
        try await store.downloadASR()
        try await store.downloadTranslation()
        let services = try await app.makeClipServices(configured: false, source: .japanese, target: .simplifiedChinese)
        let japanese = try await services.recognizer.recognize(samples: AudioFileReader.read(audio))
        guard !japanese.isEmpty else { throw ServiceError.emptyResponse }
        let chinese = try await services.translator.translate(japanese, from: "Japanese", to: "中文")
        guard !chinese.isEmpty, !FileManager.default.fileExists(atPath: empty.path) else { throw ServiceError.invalidResponse }
        print("LOCAL ASR: " + japanese)
        print("LOCAL TRANSLATION: " + chinese)
    }

    static func run(root: URL, audio: URL) async throws {
        let store = LocalModelStore(root: root)
        guard store.isASRInstalled else { throw ServiceError.modelNotInstalled("测试识别") }
        let samples = try AudioFileReader.read(audio)
        let recognizer = try ReazonSpeechRecognizer(store: store)
        let text = try await recognizer.recognize(samples: samples)
        guard !text.isEmpty else { throw ServiceError.emptyResponse }
        print("LOCAL ASR: \(text)")
        if store.isTranslationInstalled {
            let translator = try LocalLlamaTranslator(modelPath: store.translationModelPath)
            let output = try await translator.translate(text, from: "Japanese", to: "中文")
            guard !output.isEmpty else { throw ServiceError.emptyResponse }
            print("LOCAL TRANSLATION: \(output)")
        } else { print("Translation model is absent; local translation was not tested") }
    }
}
