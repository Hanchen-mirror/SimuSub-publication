import Foundation
import NaturalLanguage
import SherpaOnnx

final class MultilingualSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    private let recognizer: SherpaOnnxOfflineRecognizer
    private let language: SubtitleLanguage?
    let usesEnglishWhisper: Bool
    private let isQwen: Bool
    private let isJapaneseSenseVoice: Bool
    private let lock = NSLock()

    init(model: LocalModelDefinition, folder: URL, language: SubtitleLanguage?, threads: Int = 4, task: String = "transcribe", provider: String = "cpu") throws {
        self.language = language
        self.isQwen = model.engine == "qwen3ASR"
        self.isJapaneseSenseVoice = model.engine == "senseVoice" && language == .japanese
        self.usesEnglishWhisper = model.id == "whisper-base" && language == .english
        func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
        guard model.files.allSatisfy({ FileManager.default.isReadableFile(atPath: path($0.name)) }) else { throw ServiceError.modelFilesMissing }
        switch model.engine {
        case "senseVoice":
            let config = sherpaOnnxOfflineModelConfig(tokens: path("tokens.txt"), numThreads: threads, provider: "cpu",
                senseVoice: sherpaOnnxOfflineSenseVoiceModelConfig(model: path("model.int8.onnx"), language: language?.asrCode ?? "auto", useInverseTextNormalization: true))
            var options = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: config)
            recognizer = withUnsafePointer(to: &options) { SherpaOnnxOfflineRecognizer(config: $0) }
        case "qwen3ASR":
            let config = sherpaOnnxOfflineModelConfig(tokens: "", numThreads: threads, provider: provider,
                qwen3Asr: sherpaOnnxOfflineQwen3ASRModelConfig(convFrontend: path("conv_frontend.onnx"),
                    encoder: path("encoder.int8.onnx"), decoder: path("decoder.int8.onnx"),
                    tokenizer: folder.path, maxTotalLen: 512, maxNewTokens: 256))
            var options = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 128), modelConfig: config)
            recognizer = withUnsafePointer(to: &options) { SherpaOnnxOfflineRecognizer(config: $0) }
        case "whisper":
            let config = sherpaOnnxOfflineModelConfig(tokens: path(model.files.first { $0.name.hasSuffix("tokens.txt") }!.name),
                whisper: sherpaOnnxOfflineWhisperModelConfig(encoder: path(model.files.first { $0.name.contains("encoder") }!.name), decoder: path(model.files.first { $0.name.contains("decoder") }!.name), language: language?.asrCode ?? "", task: task),
                numThreads: threads, provider: "cpu")
            var options = sherpaOnnxOfflineRecognizerConfig(featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: config)
            recognizer = withUnsafePointer(to: &options) { SherpaOnnxOfflineRecognizer(config: $0) }
        default: throw ClipError.message("不支持此语音识别模型格式。")
        }
    }
    private static func inferredLanguage(_ text: String) -> SubtitleLanguage? {
        let detector = NLLanguageRecognizer()
        detector.languageConstraints = [.simplifiedChinese, .traditionalChinese, .english, .japanese]
        detector.processString(text)
        guard let best = detector.languageHypotheses(withMaximum: 1).first, best.value >= 0.8 else { return nil }
        return SubtitleLanguage.resolve(best.key.rawValue)
    }
    func recognize(samples: [Float]) async throws -> String {
        return try await recognizeDetailed(samples: samples).text
    }
    /// SenseVoice trims display whitespace but SentencePiece may attach one or
    /// more boundary spaces to timed tokens. Never change internal boundaries.
    static func japaneseTimedTokens(_ source: [RecognizedSpeech.Token], text: String) -> [RecognizedSpeech.Token] {
        var tokens = source
        for i in tokens.indices {
            tokens[i].text = String(tokens[i].text.drop(while: { $0.isWhitespace }))
            if !tokens[i].text.isEmpty { break }
        }
        for i in tokens.indices.reversed() {
            tokens[i].text = String(tokens[i].text.reversed().drop(while: { $0.isWhitespace }).reversed())
            if !tokens[i].text.isEmpty { break }
        }
        return tokens.map(\.text).joined() == text ? tokens.filter { !$0.text.isEmpty } : []
    }

    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        try await recognizeDetailed(samples: samples, languageHint: language)
    }
    func recognizeDetailed(samples: [Float], languageHint: SubtitleLanguage?) async throws -> RecognizedSpeech {
        guard !samples.isEmpty else { return RecognizedSpeech(text: "") }
        let task = Task.detached(priority: .userInitiated) { [self] in
            try lock.withLock {
                try Task.checkCancellation()
                let stream = recognizer.createStream()
                if isQwen, let languageHint {
                    let name = languageHint.isChinese ? "Chinese" : languageHint == .japanese ? "Japanese" : "English"
                    stream.setOption(key: "language", value: name)
                }
                stream.acceptWaveform(samples: samples, sampleRate: 16000)
                recognizer.decode(stream: stream)
                let decoded = recognizer.getResult(stream: stream)
                let raw = decoded.text
                let clean = raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                let text = language?.normalizeScript(clean) ?? clean
                var tokens: [RecognizedSpeech.Token] = []
                if let language, language.isChinese || isJapaneseSenseVoice, decoded.timestamps.count == decoded.count,
                   let pointers = decoded.result.pointee.tokens_arr {
                    let times = decoded.timestamps
                    for index in 0..<decoded.count {
                        guard let pointer = pointers[index] else { break }
                        let token = String(cString: pointer).replacingOccurrences(of: "▁", with: " ")
                        tokens.append(.init(text: token, time: Double(times[index])))
                    }
                    // Script conversion can be context-dependent. Accept offsets
                    // only when the decoded and displayed characters correspond.
                    if isJapaneseSenseVoice, tokens.count == decoded.count, clean == text {
                        tokens = Self.japaneseTimedTokens(tokens, text: text)
                    } else if tokens.count == decoded.count, tokens.map(\.text).joined() == clean,
                       tokens.reduce(0, { $0 + $1.text.count }) == text.count, clean.count == text.count {
                        var cursor = text.startIndex
                        for i in tokens.indices {
                            let end = text.index(cursor, offsetBy: tokens[i].text.count)
                            tokens[i].text = String(text[cursor..<end])
                            cursor = end
                        }
                    } else { tokens = [] }
                }
                return RecognizedSpeech(text: text, tokens: tokens, language: SubtitleLanguage.resolve(decoded.lang.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")) ?? language ?? Self.inferredLanguage(clean))
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
