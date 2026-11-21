import Foundation
import NaturalLanguage

/// Offline review for the installed Index translator. Its greedy decoder will
/// repeat the same answer to the same prompt, so a retry names the missing evidence.
struct ClipJapaneseTranslationReview: TextTranslating {
    let base: any TextTranslating
    var requiresFullUtterance: Bool { base.requiresFullUtterance }

    private struct Marker {
        let source: String
        var clauseOpening = true
        let example: String
        let readings: [String]
    }

    // Match an utterance or clause opening. A single kana inside a word is
    // never evidence of an exclamation (e.g. え in 覚えて).
    private static let markers: [Marker] = [
        .init(source: "えーっと|えっと|ええと|えーと", example: "呃", readings: ["呃", "嗯", "那个", "这个嘛", "让我想"]),
        .init(source: "うーん|うん(?=[、。！？…，!?\\s]|$)|んー", example: "嗯", readings: ["嗯", "唔", "是啊", "对", "好吧"]),
        .init(source: "えっ(?!と|ち)|えぇ|え(?=[、。！？…，!?\\s]|$)", example: "诶", readings: ["诶", "欸", "咦", "啊", "哎", "唉"]),
        .init(source: "あっ(?!た|て|ち|さ|け|と)|あー|あ(?=[、。！？…，!?\\s]|$)", example: "啊", readings: ["啊", "阿", "哦", "噢", "哎", "呀"]),
        .init(source: "でも(?:さ|ね)?|だけど|けれども|しかし", example: "不过", readings: ["不过", "但", "可是", "可我", "可这", "可那", "可你", "然而", "话虽如此", "话说回来"]),
        .init(source: "だから|なので|それで(?=[、。！？…，!?\\s]|$)", example: "所以", readings: ["所以", "因此", "于是", "那就", "难怪", "就是说", "然后", "就因为"]),
        .init(source: "そして|それから|んで", example: "然后", readings: ["然后", "接着", "接下来", "还有", "再", "于是", "那么"]),
        .init(source: "かな(?:あ|ぁ)?[。！？!?…]*$", clauseOpening: false, example: "吗", readings: ["吗", "么", "呢", "吧", "会不会", "能不能", "不知道", "是不是", "行不行"]),
        .init(source: "(?:よね|ね)[。！？!?…]*$", clauseOpening: false, example: "对吧", readings: ["吧", "对不对", "是吗", "没错", "啊", "呀", "呢", "哦", "嘛"]),
        .init(source: "(?<=[ァ-ヶ一-龯ぁ-ん0-9])も[。！？!?…]*$", clauseOpening: false, example: "也", readings: ["也", "还", "都", "连"])
    ]
    private static let patterns = markers.map { try! NSRegularExpression(pattern: ($0.clauseOpening ? "(?:^|[、。！？…，!?\\s])" : "") + "(?:" + $0.source + ")") }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translate(text, from: source, to: target, context: .init())
    }

    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        guard context.isFinal, SubtitleLanguage.resolve(source) == .japanese,
              let language = SubtitleLanguage.resolve(target), language.isChinese else {
            return try await base.translate(text, from: source, to: target, context: context)
        }
        var dialogue = context
        dialogue.japaneseClipDialogue = true
        let initial = try await base.translate(text, from: source, to: target, context: dialogue)
        let sourceText = text.precomposedStringWithCompatibilityMapping
        let digits = Self.numbers(sourceText)
        // A recited sequence has no lexical content to translate. Preserve the
        // exact values, leading zeroes, repetition and separators of the ASR.
        if !digits.isEmpty, sourceText.allSatisfy({ $0.isASCII && $0.isNumber || $0.isPunctuation || $0.isWhitespace }) {
            return text
        }
        // A bare number question is ambiguous. Preserve that ambiguity when
        // neither the source nor its neighbours mention a calendar.
        let bareQuestion = sourceText.range(of: #"^(?:えっ?|あれ|あ)?[,、\s]*[0-9]{3,}(?:かな|かも|だっけ)?[?？。…!！]*$"#, options: .regularExpression) != nil
        let neighbors = context.previous.map(\.original) + context.following
        let protectUnit = bareQuestion && !neighbors.contains {
            $0.range(of: "年|西暦|世紀|時代|歴史", options: .regularExpression) != nil
        }
        func preserveBareNumber(_ value: String) -> String {
            guard protectUnit, let number = digits.first else { return value }
            return value.replacingOccurrences(of: number + "年", with: number)
        }
        if let numbers = ClipJapaneseDialogueFragments.numberPlaceholders(source: text, draft: initial) { return numbers }
        let draft = ClipJapaneseDialogueFragments.reactions(source: sourceText, draft: preserveBareNumber(initial))
        let normalizedDraft = SubtitleLanguage.simplifiedChinese.normalizeScript(draft)
        if let result = try await repeatedProhibition(sourceText: sourceText, draft: normalizedDraft, source: source,
                                                      target: target, context: dialogue) { return result }
        // An isolated hesitation has no propositional content. A fluent
        // continuation such as “嗯，这样吧” introduces a decision.
        let surface = sourceText.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let hesitationOnly = ["えっと", "えーっと", "ええと", "えーと"].contains(surface)
        let shortHesitations = ["呃", "额", "嗯", "唔", "那个", "这个嘛", "让我想想"]
        func pureHesitation(_ value: String) -> Bool {
            shortHesitations.contains(value.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)))
        }
        if hesitationOnly && pureHesitation(normalizedDraft) { return draft }
        let range = NSRange(sourceText.startIndex..., in: sourceText)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sourceText
        tokenizer.setLanguage(.japanese)
        let wordStarts = Set(tokenizer.tokens(for: sourceText.startIndex..<sourceText.endIndex).map(\.lowerBound))
        let present = Self.markers.indices.compactMap { i -> (Marker, String)? in
            guard let match = Self.patterns[i].firstMatch(in: sourceText, range: range),
                  let span = Range(match.range, in: sourceText) else { return nil }
            if !Self.markers[i].clauseOpening && !wordStarts.contains(span.lowerBound) { return nil }
            if Self.markers[i].example == "也", ["いつも", "もっとも", "そもそも", "どうも", "子ども"].contains(where: surface.hasSuffix) { return nil }
            let word = sourceText[span].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return (Self.markers[i], word)
        }
        func missing(_ output: String) -> [(Marker, String)] {
            present.filter { marker, _ in !marker.readings.contains(where: output.contains) }
        }
        let omissions = missing(normalizedDraft)
        let lostDigits = !digits.isEmpty && Self.numbers(normalizedDraft) != digits
        let unsupportedUnit = initial != preserveBareNumber(initial)
        guard hesitationOnly || !omissions.isEmpty || lostDigits || unsupportedUnit else { return draft }
        var review = dialogue
        let hints = omissions.map { "「" + $0.1 + "」的语气可译为「" + $0.0.example + "」" }
        let focus = ((hesitationOnly ? ["这句只有犹豫声，仅译出迟疑"] : []) + hints + (lostDigits ? ["保留数字的数值、顺序和重复次数，使用阿拉伯数字"] : [])).joined(separator: "，")
        let previous = context.previous.last?.original.prefix(100)
        let next = context.following.first?.prefix(100)
        let adjacent = [previous.map { "前句「" + $0 + "」" }, next.map { "后句「" + $0 + "」" }].compactMap { $0 }.joined(separator: "、")
        review.instructions = [context.instructions, adjacent.isEmpty ? "" : "只将" + adjacent + "作为语境。",
                               focus]
            .filter { !$0.isEmpty && $0 != ServiceProfile.defaultTranslationPrompt }.joined(separator: "\n")
        do {
            try Task.checkCancellation()
            let candidate = preserveBareNumber(try await base.translate(text, from: source, to: target, context: review))
            try Task.checkCancellation()
            let normalized = SubtitleLanguage.simplifiedChinese.normalizeScript(candidate)
            if hesitationOnly { return pureHesitation(normalized) ? candidate : "呃……" }
            guard !candidate.isEmpty, !SubtitleDocument.isTranslationArtifact(candidate, original: text),
                  !candidate.contains("\n"), !normalized.contains("译为"), !normalized.contains("阿拉伯数字"),
                  Self.numbers(normalized) == digits, missing(normalized).count <= omissions.count,
                  unsupportedUnit || lostDigits || missing(normalized).count < omissions.count else { return draft }
            // Accept the restored marker/number only if the first pass's
            // wording survives. A more adventurous paraphrase needs human review.
            var body = Self.content(normalizedDraft)
            if omissions.contains(where: { $0.0.example == "诶" }), body.hasPrefix("嗯"), !normalized.hasPrefix("嗯") {
                body.removeFirst()
            }
            var updated = Self.content(normalized)
            for (marker, _) in omissions {
                // Strip only a newly restored expression. Arbitrary new words
                // (especially negation) cannot ride along with the repair.
                let readings = marker.readings.sorted { $0.count > $1.count }
                if marker.clauseOpening, let restored = readings.first(where: updated.hasPrefix) {
                    updated.removeFirst(restored.count)
                } else if !marker.clauseOpening, let restored = readings.first(where: updated.hasSuffix) {
                    updated.removeLast(restored.count)
                }
            }
            guard updated == body else { return draft }
            return candidate
        } catch {
            try Task.checkCancellation()
            return draft
        }
    }

    private func repeatedProhibition(sourceText: String, draft: String, source: String, target: String,
                                     context: SubtitleTranslationContext) async throws -> String? {
        // An immediate repeated clause with an explicit prohibition is easy to
        // lose twice: “見ちゃダメ、見ちゃダメ” needs both the negation and repetition.
        let separated = sourceText.components(separatedBy: CharacterSet(charactersIn: "、，,。！!？?…"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let clause = separated.last ?? ""
        let repetitions = separated.reversed().prefix { $0 == clause }.count
        let repeatedProhibition = repetitions >= 2 && clause.range(of: "(ちゃ|じゃ)(ダメ|だめ)$|てはいけない$", options: .regularExpression) != nil
        let translatedCount = Self.negativePattern.numberOfMatches(in: draft, range: NSRange(draft.startIndex..., in: draft))
        guard repeatedProhibition, translatedCount < repetitions else { return nil }
        // Require an independently translated verb shared with the draft.
        let head = separated.dropLast(repetitions)
        guard head.isEmpty || (head.count == 1 && ["あ", "あっ", "え", "えっ"].contains(head.first ?? "")) else { return nil }
        guard let unit = try? await base.translate(clause, from: source, to: target, context: context) else {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()
        let clean = unit.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let zh = SubtitleLanguage.simplifiedChinese.normalizeScript(clean)
        let verb = zh.replacingOccurrences(of: "^(不能|不可以|不可|不要|别|不准|禁止|不行)", with: "", options: .regularExpression)
        guard !verb.isEmpty, zh != verb, Self.content(draft).contains(verb),
              !clean.contains("\n"), Self.numbers(zh) == Self.numbers(sourceText) else { return nil }
        let reaction = head.first.map { $0.hasPrefix("あ") ? "啊，" : "诶，" } ?? ""
        let punctuation = sourceText.hasSuffix("!") ? "！" : "。"
        return reaction + Array(repeating: clean, count: repetitions).joined(separator: "，") + punctuation
    }

    private static let negativePattern = try! NSRegularExpression(pattern: "不能|不可以|不可|不要|别|不准|禁止|不行")
    private static let numericPattern = try! NSRegularExpression(pattern: #"[+−-]?[0-9]+(?:[.][0-9]+)*"#)

    private static func numbers(_ text: String) -> [String] {
        let value = text.precomposedStringWithCompatibilityMapping
        return numericPattern.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }

    private static func content(_ text: String) -> String {
        String(text.filter { !$0.isPunctuation && !$0.isWhitespace && !($0.isASCII && $0.isNumber) })
    }
}
