import Foundation

enum ClipJapaneseDialogueFragments {
    /// In a list of digits, なんとか can stand for a forgotten part of the
    /// number. In a lexical sentence it can instead mean “somehow”.
    static func numberPlaceholders(source: String, draft: String) -> String? {
        guard source.contains("なんとか"), draft.contains("なんとか"),
              source.range(of: "[0-9０-９]", options: .regularExpression) != nil else { return nil }
        let remainder = source.replacingOccurrences(of: "なんとか", with: "")
        guard remainder.allSatisfy({ $0.isNumber || $0.isWhitespace || $0.isPunctuation }) else { return nil }
        return source.replacingOccurrences(of: "なんとか", with: "什么来着")
            .replacingOccurrences(of: "、", with: "，")
    }

    static func reactions(source: String, draft: String) -> String {
        var result = draft
        // A cut-off ちょ、 is the speaker interrupting themselves. Replace
        // only an isolated generic exclamation at the same clause opening.
        if source.range(of: #"^ちょ[,、]"#, options: .regularExpression) != nil {
            result = result.replacingOccurrences(of: #"^(?:啊|呀|嗯|哦)[,，、]"#, with: "等等，", options: .regularExpression)
        }
        // In a succession of isolated questions, は？ expresses disbelief.
        // Preserve any larger phrase that contains は.
        let clauses = source.components(separatedBy: CharacterSet(charactersIn: "？?"))
        var zh = result.components(separatedBy: CharacterSet(charactersIn: "？?"))
        if clauses.count == zh.count && clauses.count > 1 {
            var changed = false
            for i in clauses.indices.dropLast() where clauses[i].trimmingCharacters(in: .whitespacesAndNewlines) == "は" {
                if zh[i].trimmingCharacters(in: .whitespacesAndNewlines) == "是" { zh[i] = "哈"; changed = true }
            }
            if changed { result = zh.joined(separator: "？") }
        }
        return result
    }
}
