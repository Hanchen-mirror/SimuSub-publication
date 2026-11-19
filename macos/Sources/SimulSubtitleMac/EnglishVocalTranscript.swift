import Foundation

enum EnglishVocalTranscript {
    // Match only explicitly delimited descriptions. Someone saying “I love
    // music”, or singing a parenthetical backing vocal, keeps those words.
    private static let label = #"(?:(?:upbeat|soft|loud|instrumental|background|dramatic|rock|pop|electronic|intro|outro)\s+)*(?:music|instrumental)(?:\s+(?:plays|playing|continues|fades(?:\s+out)?))?"#
    private static let annotations = try! NSRegularExpression(pattern:
        #"(?i)\[\s*"# + label + #"\s*\]|\(\s*"# + label + #"\s*\)|\*\s*"# + label + #"\s*\*|^\s*(?:\[|\(|\*)\s*"# + label + #"\s*$|^\s*\*\s*singing\s*\*\s*$"#)

    static func signalsMusic(_ text: String) -> Bool {
        text.contains(where: { "♪♫♬♩".contains($0) })
            || annotations.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func words(in hypothesis: String) -> String {
        let withoutLabels = annotations.stringByReplacingMatches(in: hypothesis, range: NSRange(hypothesis.startIndex..., in: hypothesis), withTemplate: " ")
        let words = withoutLabels.components(separatedBy: CharacterSet(charactersIn: "♪♫♬♩"))
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.contains { $0.isLetter || $0.isNumber } ? words : ""
    }

    /// Join a short, syntactically dependent tail to a recent open predicate.
    /// The first cue can appear immediately. Only the final tail triggers revision.
    static func joined(previous: Caption, current: String, start: Double, end: Double) -> String? {
        let previousText = previous.original, right = current
        // Some final ASR windows end with a hesitation mark at a mid-sentence
        // cut. Keep ordinary sentence punctuation intact for independence checks.
        let left: String
        if previousText.hasSuffix("...") || previousText.hasSuffix("…") {
            let count = previousText.hasSuffix("...") ? 3 : 1
            left = String(previousText.dropLast(count)).trimmingCharacters(in: .whitespaces)
        } else { left = previousText }
        guard previous.sourceLanguage == .english, previous.targetLanguage.isChinese,
              (-0.032...0.35).contains(start - previous.end), end - previous.start <= 7,
              previous.start < start, right.split(whereSeparator: \.isWhitespace).count <= 7,
              (left + " " + right).count <= 220,
              !right.contains("?") else { return nil }
        // ASR sometimes inserts a period between two parallel comparisons.
        // Both clauses have to supply the same preposition before we remove it.
        if let preposition = ["for", "of"].first(where: {
            right.lowercased().hasPrefix("as it is " + $0 + " ")
        }) {
            let stem = left.hasSuffix(".") ? String(left.dropLast()) : left
            let parallel = #"(?i)\btrue\s+"# + preposition + #"\s+(?:[\w'-]+\s+){0,3}[\w'-]+$"#
            if stem.range(of: parallel, options: .regularExpression) != nil {
                return stem + " " + right
            }
        }
        guard left.last?.isLetter == true else { return nil }
        // Embedded nominal clauses are frequently misread as questions in isolation.
        let governor = #"(?i)\b(?:love|like|enjoy|understand|remember|forget|know|believe|see|do|decide|choose|explain)\s*$"#
        let object = #"(?i)^(?:what|how|where|why)\s+(?:I|you|we|they|he|she|it)\s+\S+"#
        let participle = #"(?i)\b(?:spend|spending|spent|waste|wasting|wasted)\s+(?:it|time|hours?|days?|years?)$"#
        let progressive = #"(?i)^[a-z]{2,}ing\b"#
        // Frequent verb–noun complements. Requiring the noun phrase to exhaust
        // the cue avoids turning an independent “The decision was final” into an object.
        let decisionVerb = #"(?i)\b(?:make|makes|making|made|face|faces|faced|facing|weigh|weighs|weighed|weighing)\s*$"#
        let decision = #"(?i)^(?:a|an|the|my|our|your|their)\s+(?:(?:big|hard|tough|difficult|important|right|wrong|final|next)\s+){0,2}(?:decisions?|choices?)\b(?:\s+(?:in|of|about|for)\s+(?:(?:my|your|our|their|the)\s+)?[a-z]+)?[.!]?$"#
        let matches = (left.range(of: governor, options: .regularExpression) != nil && right.range(of: object, options: .regularExpression) != nil)
            || (left.range(of: decisionVerb, options: .regularExpression) != nil && right.range(of: decision, options: .regularExpression) != nil)
            || (left.range(of: participle, options: .regularExpression) != nil && right.range(of: progressive, options: .regularExpression) != nil)
        return matches ? left + " " + right : nil
    }
}
