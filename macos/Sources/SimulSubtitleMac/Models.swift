import Foundation

struct Caption: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var original: String
    var translated: String
    var isDraft: Bool = false
    var confirmedPrefix: String = ""

    init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval, original: String, translated: String, isDraft: Bool = false) {
        self.id = id; self.start = start; self.end = end
        self.original = original; self.translated = translated; self.isDraft = isDraft
    }
    private enum CodingKeys: String, CodingKey { case id, start, end, original, translated, isDraft, confirmedPrefix }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        start = try values.decode(TimeInterval.self, forKey: .start)
        end = try values.decode(TimeInterval.self, forKey: .end)
        original = try values.decode(String.self, forKey: .original)
        translated = try values.decode(String.self, forKey: .translated)
        isDraft = try values.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        confirmedPrefix = try values.decodeIfPresent(String.self, forKey: .confirmedPrefix) ?? ""
    }
}

enum ServiceKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case local = "本地模型"
    case openAICompatible = "OpenAI 兼容接口"

    var id: String { rawValue }
}

enum ServicePurpose: String, CaseIterable, Identifiable, Codable, Sendable {
    case speechRecognition = "语音识别"
    case translation = "翻译"
    var id: String { rawValue }
}

struct ServiceProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: ServiceKind
    var purpose: ServicePurpose
    var baseURL: String = ""
    var model: String = ""
    var sourceLanguage: String = "日语"
    var targetLanguage: String = "中文"
    var timeoutSeconds: Int = 30
    var isEnabled: Bool = true
}

protocol SpeechRecognizing: Sendable {
    func recognize(samples: [Float]) async throws -> String
}

protocol TextTranslating: Sendable {
    var requiresFullUtterance: Bool { get }
    func translate(_ text: String, from source: String, to target: String) async throws -> String
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String
}

extension TextTranslating {
    var requiresFullUtterance: Bool { false }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        try await translate(text, from: source, to: target)
    }
}

protocol AudioCapturing {
    func start(selectedBundleID: String, generation: UUID) async throws
    func stop() async
}


enum AppSection: String, CaseIterable, Identifiable {
    case live = "实时字幕"
    case services = "服务与模型"
    case history = "字幕记录"
    case permissions = "字幕设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .live: "captions.bubble"
        case .services: "slider.horizontal.3"
        case .history: "text.page"
        case .permissions: "lock.shield"
        }
    }
}

extension ServiceProfile {
    var isDeepSeek: Bool { URL(string: baseURL)?.host?.lowercased() == "api.deepseek.com" }
    static var deepSeek: ServiceProfile {
        ServiceProfile(name: "DeepSeek 字幕核对 / 翻译", kind: .openAICompatible, purpose: .translation,
                       baseURL: "https://api.deepseek.com", model: "deepseek-flash", timeoutSeconds: 60)
    }

    func validatedBaseURL() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ServiceError.invalidURL }
        return url
    }
}

extension String {
    var containsJapaneseScript: Bool {
        range(of: #"[ぁ-ゟ゠-ヿ一-龯]"#, options: .regularExpression) != nil
    }

    var asrLanguageCode: String? {
        let lower = trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("自动") || lower.contains("auto") { return nil }
        if ["日语", "日本語", "ja", "japanese"].contains(lower) { return "ja" }
        if ["英语", "英文", "en", "english"].contains(lower) { return "en" }
        if ["中文", "汉语", "zh", "chinese"].contains(lower) { return "zh" }
        return nil
    }
}
