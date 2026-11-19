import Foundation

/// Direction policy selected on the development corpus, then frozen for regression.
/// Both engines remain resident; no model swapping, network calls, or extra decoding.
struct LocalSubtitleTranslator: TextTranslating {
    let index: any TextTranslating
    let hunyuan: any TextTranslating
    let requiresFullUtterance = true
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        // Cross-language context made the small model replay prior subtitles.
        // Keep only the contiguous same-language history; mixed/unknown starts fresh.
        var context = context.contiguousContext(for: source)
        let from = SubtitleLanguage.resolve(source), to = SubtitleLanguage.resolve(target)
        if to == .english {
            context.compactLocalPrompt = true
            return try await index.translate(text, from: source, to: target, context: context)
        }
        if from == .english && to?.isChinese == true {
            context.compactLocalPrompt = false
            return try await index.translate(text, from: source, to: target, context: context)
        }
        context.compactLocalPrompt = true
        return try await hunyuan.translate(text, from: source, to: target, context: context)
    }
}
