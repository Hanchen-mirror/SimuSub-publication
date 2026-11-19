import Foundation

struct OriginalTextTranslator: TextTranslating {
    func translate(_ text: String, from: String, to: String) async throws -> String { text }
}

enum SubtitleLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .japanese: "日语"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .english: "英语"
        }
    }
    var nativeName: String {
        switch self {
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        }
    }
    var asrCode: String { isChinese ? "zh" : rawValue }
    var isChinese: Bool { self == .simplifiedChinese || self == .traditionalChinese }
    var preview: String {
        switch self {
        case .japanese: "今日も一緒に、ゆっくりいこう。"
        case .simplifiedChinese: "今天也一起，慢慢来吧。"
        case .traditionalChinese: "今天也一起，慢慢來吧。"
        case .english: "Let's take it easy together today."
        }
    }
    var layoutLanguage: SubtitleLineLayout.Language {
        switch self {
        case .japanese: .japanese
        case .simplifiedChinese: .chinese
        case .traditionalChinese: .traditionalChinese
        case .english: .english
        }
    }
    func normalizeScript(_ text: String) -> String {
        guard isChinese else { return text }
        return text.applyingTransform(StringTransform(self == .traditionalChinese ? "Hans-Hant" : "Hant-Hans"), reverse: false) ?? text
    }
    static func resolve(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ja", "日语", "日語", "日本語", "japanese": .japanese
        case "zh", "zh-cn", "zh-hans", "中文", "汉语", "简体中文", "簡體中文", "chinese", "simplified chinese": .simplifiedChinese
        case "zh-tw", "zh-hant", "繁体中文", "繁體中文", "traditional chinese": .traditionalChinese
        case "en", "英语", "英語", "英文", "english": .english
        default: nil
        }
    }
}

/// Script conversion is deterministic; it never sends Chinese script pairs to an LLM.
struct LanguageAwareTranslator: TextTranslating {
    let base: any TextTranslating
    var requiresFullUtterance: Bool { base.requiresFullUtterance }
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        try Task.checkCancellation()
        let from = SubtitleLanguage.resolve(source), to = SubtitleLanguage.resolve(target)
        if from == to, let to { return to.normalizeScript(text) }
        if from?.isChinese == true, to?.isChinese == true { return to!.normalizeScript(text) }
        let result = try await base.translate(text, from: source, to: target, context: context)
        return to?.normalizeScript(result) ?? result
    }
}

struct PromptedLocalTranslator: TextTranslating {
    let base: any TextTranslating
    let instructions: String
    var requiresFullUtterance: Bool { base.requiresFullUtterance }
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        var guided = context; guided.instructions = instructions
        return try await base.translate(text, from: source, to: target, context: guided)
    }
}

/// Conservative mixed-script routing: a dominant-language ID is not proof that
/// every word is in that language. Unknown and mixed speech still goes to MT.
enum LiveLanguageRouting {
    static func translationSource(text: String, detected: SubtitleLanguage?) -> String {
        guard let detected else { return "多语言" }
        let scalars = text.unicodeScalars
        let han = scalars.contains { (0x3400...0x9FFF).contains($0.value) }
        let kana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let latin = scalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) }
        if (latin && (han || kana)) || (detected.isChinese && kana) || (detected == .english && (han || kana)) { return "多语言" }
        return detected.name
    }
}
