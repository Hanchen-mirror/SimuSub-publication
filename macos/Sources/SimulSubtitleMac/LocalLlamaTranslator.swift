import Foundation
import LlamaSwift

final class LocalLlamaTranslator: TextTranslating, @unchecked Sendable {
    // The bundled 2B model mistranslates context-dependent clause tails in real
    // livestream tests. Keep full sentences until a better model is validated.
    let requiresFullUtterance = true
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let lock = NSLock()
    private static let backendReady: Void = { llama_backend_init() }()
    private static func initializeBackend() { _ = backendReady }


    init(modelPath: String, threads: Int = 4) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else { throw ServiceError.modelFilesMissing }
        Self.initializeBackend()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        let loadedModel = modelPath.withCString { llama_model_load_from_file($0, modelParams) }
        guard let loadedModel else { throw LocalLlamaError.modelLoad }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 2048
        contextParams.n_batch = 512
        contextParams.n_threads = Int32(threads)
        contextParams.n_threads_batch = Int32(threads)
        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LocalLlamaError.contextCreate
        }
        guard let vocab = llama_model_get_vocab(loadedModel) else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLlamaError.vocabulary
        }
        let samplerParams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(samplerParams), let greedy = llama_sampler_init_greedy() else {
            llama_free(loadedContext)
            llama_model_free(loadedModel)
            throw LocalLlamaError.sampler
        }
        llama_sampler_chain_add(chain, greedy)
        model = loadedModel
        context = loadedContext
        vocabulary = vocab
        sampler = chain
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
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
                var bounded = translationContext.localContext(for: text)
                for attempt in 0..<3 {
                    do {
                        return try generate("<|im_start|>user\n\(bounded.prompt(for: text))<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", maxTokens: bounded.isFinal ? 512 : 256)
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
    case modelLoad, contextCreate, vocabulary, sampler, tokenize, promptTooLong, decode, outputTruncated
    var errorDescription: String? {
        switch self {
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
