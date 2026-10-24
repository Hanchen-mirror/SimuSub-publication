import Foundation

struct OpenAICompatibleSpeechRecognizer: SpeechRecognizing {
    let profile: ServiceProfile
    let apiKey: String
    var session: URLSession = .shared

    func recognize(samples: [Float]) async throws -> String {
        let base = try profile.validatedBaseURL()
        let url = base.appending(path: "audio/transcriptions")
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(profile.timeoutSeconds))
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", profile.model)
        field("language", "ja")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(WAVEncoder.wav(samples: samples, sampleRate: 16_000))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OpenAICompatibleTranslator: TextTranslating {
    let profile: ServiceProfile
    let apiKey: String
    var session: URLSession = .shared

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }

    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        let base = try profile.validatedBaseURL()
        let url = base.appending(path: "chat/completions")
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(context.isStablePrefix ? min(4, profile.timeoutSeconds) : profile.timeoutSeconds))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let prompt = context.prompt(for: text)
        var messages: [[String: String]] = []
        if !profile.effectiveTranslationPrompt.isEmpty {
            messages.append(["role": "system", "content": profile.effectiveTranslationPrompt])
        }
        messages.append(["role": "user", "content": prompt])
        var body: [String: Any] = [
            "model": profile.model,
            "messages": messages,
            "temperature": 0, "stream": false, "max_tokens": 1024
        ]
        if profile.isDeepSeek { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else { throw ServiceError.invalidResponse }
        if decoded.choices.first?.finish_reason == "length" { throw LocalLlamaError.outputTruncated }
        guard let content = decoded.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ServiceError.emptyResponse
        }
        return content
    }
}

private struct TranscriptionResponse: Decodable { let text: String }
private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
}

enum ServiceError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyResponse
    case http(Int, String)
    case missingAPIKey(String)
    case modelFilesMissing
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务地址无效"
        case .invalidResponse: "服务返回了无法识别的响应"
        case .emptyResponse: "服务没有返回内容"
        case .http(let status, _):
            switch status {
            case 401, 403: "API 身份验证失败，请检查密钥和模型权限。［API-\(status)］"
            case 402: "API 余额不足，请充值或切回本地模型。［API-402］"
            case 404: "API 地址或模型不存在，请检查服务地址与模型名称。［API-404］"
            case 429: "API 请求过于频繁或额度不足，请稍后手动重试。已保存的字幕保留。［API-429］"
            case 500...599: "云端服务暂时不可用，请稍后重试或改用本地模型。［API-\(status)］"
            default: "API 请求未完成，请检查模型配置后重试。［API-\(status)］"
            }
        case .missingAPIKey(let name): "请先在设置中保存 \(name) 的 API Key"
        case .modelFilesMissing: "本地引擎文件尚未准备完成，请返回日中同传查看自动安装状态"
        case .modelNotInstalled(let name): "\(name)尚未就绪，请返回日中同传重试自动准备"
        }
    }
}
