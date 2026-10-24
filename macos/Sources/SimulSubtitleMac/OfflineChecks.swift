import Foundation

enum OfflineChecks {
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
