import Foundation
import LlamaSwift

final class LocalLlamaTranslator: TextTranslating, @unchecked Sendable {
    // The bundled 2B model mistranslates context-dependent clause tails in real
    // livestream tests. Keep full sentences until a better model is validated.
    let requiresFullUtterance = true
    private let useModelTemplate: Bool
    private let compactPrompt: Bool
    private let gemma4Prompt: Bool
    private let model: OpaquePointer
    private var audioContext: OpaquePointer?
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let lock = NSLock()
    private static let backendReady: Void = { llama_backend_init() }()
    private static func initializeBackend() { _ = backendReady }


    init(modelPath: String, threads: Int = 4, useModelTemplate: Bool = false, compactPrompt: Bool = false, gemma4Prompt: Bool = false, backendSampling: Bool = false) throws {
        self.useModelTemplate = useModelTemplate
        self.compactPrompt = compactPrompt
        self.gemma4Prompt = gemma4Prompt
        guard FileManager.default.fileExists(atPath: modelPath) else { throw ServiceError.modelFilesMissing }
        Self.initializeBackend()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        let loadedModel = modelPath.withCString { llama_model_load_from_file($0, modelParams) }
        guard let loadedModel else { throw LocalLlamaError.modelLoad }
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_model_free(loadedModel)
            throw LocalLlamaError.sampler
        }
        guard let greedy = llama_sampler_init_greedy() else {
            llama_sampler_free(chain)
            llama_model_free(loadedModel)
            throw LocalLlamaError.sampler
        }
        llama_sampler_chain_add(chain, greedy)
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 512
        contextParams.n_threads = Int32(threads)
        contextParams.n_threads_batch = Int32(threads)
        // Keep the chain alive until after the context is freed. The backend can
        // select the greedy token without transferring the full vocabulary.
        var sampling = llama_sampler_seq_config(seq_id: 0, sampler: chain)
        let createdContext = withUnsafeMutablePointer(to: &sampling) { pointer in
            if backendSampling { contextParams.samplers = pointer; contextParams.n_samplers = 1 }
            return llama_init_from_model(loadedModel, contextParams)
        }
        guard let loadedContext = createdContext else {
            llama_sampler_free(chain)
            llama_model_free(loadedModel)
            throw LocalLlamaError.contextCreate
        }
        guard let vocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_sampler_free(chain)
            llama_model_free(loadedModel)
            throw LocalLlamaError.vocabulary
        }
        model = loadedModel
        context = loadedContext
        vocabulary = vocab
        sampler = chain
    }

    deinit {
        if let audioContext { mtmd_free(audioContext) }
        llama_free(context)
        llama_sampler_free(sampler)
        llama_model_free(model)

    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }

    func translate(_ text: String, from source: String, to target: String, context translationContext: SubtitleTranslationContext) async throws -> String {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) { [self] in
            try lock.withLock {
                try Task.checkCancellation()
                var bounded = (gemma4Prompt ? translationContext.contiguousContext(for: source) : translationContext).localContext(for: text)
                // Index-Translate often translates the previous English turn instead of the
                // current one when both are placed in the user message.
                if !useModelTemplate {
                    bounded.previous = []
                    bounded.following = []
                }
                let indexEnglishToChinese = !useModelTemplate && !gemma4Prompt
                    && SubtitleLanguage.resolve(source) == .english && SubtitleLanguage.resolve(target)?.isChinese == true
                let neutralYears = indexEnglishToChinese ? EnglishLagMeasurement.neutralYears(text).map {
                    SubtitleLanguage.resolve(target)?.normalizeScript($0) ?? $0
                } : nil
                if indexEnglishToChinese,
                   let outputLanguage = SubtitleLanguage.resolve(target), outputLanguage.isChinese,
                   let lag = EnglishLagMeasurement.read(text) {
                    let meaning = outputLanguage.normalizeScript(lag.chinese)
                    if lag.standalone { return meaning + "。" }
                    bounded.terms.insert(.init(japanese: lag.phrase, chinese: meaning), at: 0)
                }
                if !useModelTemplate, !gemma4Prompt,
                   let continuation = EnglishSubtitleContinuation.plan(current: text, source: source, target: target, context: bounded) {
                    let input: String
                    let prefix: String
                    switch continuation {
                    case .completeObject(let clarified):
                        input = clarified
                        prefix = ""
                    case .continueTranslation(let combined, let displayed):
                        input = combined
                        prefix = displayed
                    }
                    let prompt = bounded.hunyuanPrompt(for: input, source: source, target: target)
                    // The sampler returns only newly generated tokens, never the supplied Chinese prefix.
                    do {
                        let value = try generate(try chatPrompt(prompt) + prefix, maxTokens: 512)
                        if let accepted = EnglishSubtitleContinuation.accepted(value, prefix: prefix, original: text) {
                            if let neutralYears, accepted.contains("岁") || accepted.contains("歲"),
                               !EnglishLagMeasurement.ageIsExplicit(in: bounded.adjacentEnglishSource) {
                                return neutralYears + "。"
                            }
                            return accepted
                        }
                    } catch LocalLlamaError.promptTooLong {
                        // The full current cue still fits after dropping optional continuity context.
                    } catch LocalLlamaError.outputTruncated {
                        // Retry only the current cue if a continuation runs past the output limit.
                    }
                }
                if let neutralYears { return neutralYears + "。" }
                for attempt in 0..<3 {
                    do {
                        if gemma4Prompt {
                            return try generate(bounded.gemma4SubtitlePrompt(for: text, source: source, target: target), maxTokens: bounded.isFinal ? 512 : 256)
                        }
                        let compact = !useModelTemplate || (bounded.compactLocalPrompt ?? compactPrompt)
                        let content = compact ? bounded.hunyuanPrompt(for: text, source: source, target: target) : bounded.prompt(for: text, source: source, target: target)
                        let limit = bounded.isFinal ? 512 : 256
                        let result = try generate(try chatPrompt(content), maxTokens: limit)
                        guard SubtitleDocument.isTranslationArtifact(result, original: text) else { return result }
                        // Retry only a malformed answer, without neighboring utterances or terminology.
                        let isolated = SubtitleTranslationContext(isFinal: bounded.isFinal, instructions: bounded.instructions)
                        let retry = compact ? isolated.prompt(for: text, source: source, target: target)
                            : isolated.hunyuanPrompt(for: text, source: source, target: target)
                        let corrected = try generate(try chatPrompt(retry), maxTokens: limit)
                        guard !SubtitleDocument.isTranslationArtifact(corrected, original: text) else { throw LocalLlamaError.unrelatedOutput }
                        return corrected
                    } catch LocalLlamaError.promptTooLong {
                        // Preserve the complete source; shorten only optional context.
                        if attempt == 0 {
                            bounded.previous = Array(bounded.previous.suffix(1)); bounded.following = []
                            bounded.terms = Array(bounded.terms.prefix(3))
                        } else { bounded.previous = []; bounded.terms = [] }
                    }
                }
                throw LocalLlamaError.promptTooLong
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// One resident Gemma language model handles both PCM transcription and text translation.
    func transcribeAudio(samples: [Float], projectionPath: String, instructions: String? = nil) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { [self] in
            try lock.withLock {
                try Task.checkCancellation()
                if audioContext == nil {
                    var params = mtmd_context_params_default()
                    params.use_gpu = true; params.n_threads = 4; params.warmup = false
                    audioContext = projectionPath.withCString { mtmd_init_from_file($0, model, params) }
                }
                guard let audioContext, mtmd_support_audio(audioContext), mtmd_get_audio_sample_rate(audioContext) == 16000 else { throw LocalLlamaError.modelLoad }
                guard let bitmap = samples.withUnsafeBufferPointer({ mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }),
                      let chunks = mtmd_input_chunks_init() else { throw LocalLlamaError.tokenize }
                defer { mtmd_bitmap_free(bitmap); mtmd_input_chunks_free(chunks) }
                let taskPrompt = instructions ?? "Transcribe the following speech segment in its original language. Follow these specific instructions for formatting the answer:\n* Only output the transcription, with no newlines.\n* When transcribing numbers, write the digits, i.e. write 1.7 and not one point seven, and write 3 instead of three."
                let prompt = "<bos><|turn>user\n" + taskPrompt + "\n" + String(cString: mtmd_default_marker()) + "<turn|>\n<|turn>model\n"
                var media: OpaquePointer? = bitmap
                let status = prompt.withCString { pointer in
                    var text = mtmd_input_text(text: pointer, text_len: prompt.utf8.count, add_special: false, parse_special: true)
                    return mtmd_tokenize(audioContext, chunks, &text, &media, 1)
                }
                guard status == 0 else { throw LocalLlamaError.tokenize }
                guard mtmd_helper_get_n_tokens(chunks) + 256 <= 2048 else { throw LocalLlamaError.promptTooLong }
                llama_memory_clear(llama_get_memory(context), true)
                llama_sampler_reset(sampler)
                var position: Int32 = 0
                guard mtmd_helper_eval_chunks(audioContext, context, chunks, 0, 0, 512, true, &position) == 0 else { throw LocalLlamaError.decode }
                return try finishGeneration(startPosition: position, maxTokens: 256)
            }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func chatPrompt(_ content: String) throws -> String {
        guard useModelTemplate else { return "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n" }
        guard let template = llama_model_chat_template(model, nil) else { throw LocalLlamaError.chatTemplate }
        return try "user".withCString { role in
            try content.withCString { text in
                var message = llama_chat_message(role: role, content: text)
                let needed = llama_chat_apply_template(template, &message, 1, true, nil, 0)
                guard needed > 0 else { throw LocalLlamaError.chatTemplate }
                var bytes = [CChar](repeating: 0, count: Int(needed) + 1)
                let count = llama_chat_apply_template(template, &message, 1, true, &bytes, Int32(bytes.count))
                guard count > 0, count < bytes.count else { throw LocalLlamaError.chatTemplate }
                return String(decoding: bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }

    private func generate(_ prompt: String, maxTokens: Int) throws -> String {
        let bytes = prompt.utf8.count
        var tokens = [llama_token](repeating: 0, count: bytes + 16)
        let tokenCount = prompt.withCString { cString in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocabulary, cString, Int32(bytes), buffer.baseAddress!, Int32(buffer.count), false, true)
            }
        }
        guard tokenCount > 0 else { throw LocalLlamaError.tokenize }
        let promptTokens = Array(tokens.prefix(Int(tokenCount)))
        guard promptTokens.count + maxTokens <= 2048 else { throw LocalLlamaError.promptTooLong }
        llama_memory_clear(llama_get_memory(context), true)
        llama_sampler_reset(sampler)
        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        var position: Int32 = 0
        for sliceStart in stride(from: 0, to: promptTokens.count, by: 512) {
            let slice = promptTokens[sliceStart..<min(sliceStart + 512, promptTokens.count)]
            fill(&batch, tokens: Array(slice), startPosition: position, predictLast: sliceStart + slice.count == promptTokens.count)
            guard llama_decode(context, batch) == 0 else { throw LocalLlamaError.decode }
            position += Int32(slice.count)
        }

        return try finishGeneration(startPosition: position, maxTokens: maxTokens)
    }

    private func finishGeneration(startPosition: Int32, maxTokens: Int) throws -> String {
        var position = startPosition
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        var output = Data()
        var completed = false
        for _ in 0..<maxTokens {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { completed = true; break }
            var piece = [CChar](repeating: 0, count: 256)
            let count = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { output.append(contentsOf: piece.prefix(Int(count)).map { UInt8(bitPattern: $0) }) }
            fill(&batch, tokens: [token], startPosition: position, predictLast: true)
            guard llama_decode(context, batch) == 0 else { throw LocalLlamaError.decode }
            position += 1
        }
        guard completed else { throw LocalLlamaError.outputTruncated }
        let decoded = String(decoding: output, as: UTF8.self)
        return decoded.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "</think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fill(_ batch: inout llama_batch, tokens: [llama_token], startPosition: Int32, predictLast: Bool) {
        batch.n_tokens = Int32(tokens.count)
        for (index, token) in tokens.enumerated() {
            batch.token[index] = token
            batch.pos[index] = startPosition + Int32(index)
            batch.n_seq_id[index] = 1
            if let sequenceIDs = batch.seq_id, let sequence = sequenceIDs[index] { sequence[0] = 0 }
            batch.logits[index] = (predictLast && index == tokens.count - 1) ? 1 : 0
        }
    }
}

enum LocalLlamaError: Error, LocalizedError {
    case modelLoad, contextCreate, vocabulary, sampler, tokenize, promptTooLong, decode, outputTruncated, chatTemplate, unrelatedOutput
    var errorDescription: String? {
        switch self {
        case .unrelatedOutput: "模型未返回当前片段的译文"
        case .chatTemplate: "此 GGUF 的对话模板不受当前引擎支持，请选择兼容的指令／翻译模型。"
        case .outputTruncated: "译文超过长度限制，未将截断结果当作完整字幕。"
        case .modelLoad: "无法加载本地翻译模型"
        case .contextCreate: "无法创建本地翻译上下文"
        case .vocabulary: "本地模型缺少词表"
        case .sampler: "无法初始化本地翻译采样器"
        case .tokenize: "无法处理翻译提示词"
        case .promptTooLong: "翻译提示词超过本地模型上下文长度"
        case .decode: "本地翻译模型生成失败"
        }
    }
}

struct GemmaSpeechRecognizer: SpeechRecognizing {
    let engine: LocalLlamaTranslator
    let projectionPath: String
    var instructions: String? = nil
    func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        let text = try await engine.transcribeAudio(samples: samples, projectionPath: projectionPath, instructions: instructions)
        let kana = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        let han = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return RecognizedSpeech(text: text, language: kana ? .japanese : han ? .simplifiedChinese : .english)
    }
}
