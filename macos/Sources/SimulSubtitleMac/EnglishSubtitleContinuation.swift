import Foundation

/// A confirmed source boundary can cut off a predicate from its complement.
/// Index can continue an already displayed Chinese prefix without emitting it again.
enum EnglishSubtitleContinuation: Equatable {
    case completeObject(String)
    case continueTranslation(source: String, prefix: String)

    static func plan(current: String, source: String, target: String, context: SubtitleTranslationContext) -> Self? {
        guard context.isFinal, !context.isStablePrefix, SubtitleLanguage.resolve(source) == .english,
              SubtitleLanguage.resolve(target)?.isChinese == true,
              let preceding = context.adjacentEnglishSource?.trimmingCharacters(in: .whitespacesAndNewlines),
              let displayed = context.adjacentEnglishTranslation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preceding.isEmpty, preceding.count <= 420, !displayed.isEmpty, displayed.count <= 240,
              displayed.range(of: #"\p{Han}"#, options: .regularExpression) != nil,
              !current.isEmpty, current.count <= 420,
              ![preceding, current, displayed].contains(where: { $0.contains("<|") || $0.contains("<think>") }) else { return nil }
        let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = preceding.trimmingCharacters(in: CharacterSet(charactersIn: ".!…。！？”’\"' "))
        let hasStop = stem != preceding || preceding.hasSuffix("?")
        if let complete = completedObject(preceding: stem, current: text), !preceding.hasSuffix("?") { return .completeObject(complete) }
        // ASR can punctuate both halves. Override a period only for a measured
        // complement of an explicitly quantitative predicate (e.g. 'trails by').
        let possibleDifference = text.lowercased().hasPrefix("by ")
            && text.range(of: #"(?i)\b(?:years?|months?|weeks?|days?|hours?|minutes?|seconds?)\b"#, options: .regularExpression) != nil
        if hasStop || possibleDifference {
            let measure = #"(?i)^(?:by|from|for|of|between|to)\s+(?:(?:about|over|under|nearly|around|at least|more than|less than|roughly|approximately)\s+)?(?:[0-9]+(?:[.,][0-9]+)?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|several|a few)\b"#
            let predicate = #"(?i)\b(?:lag(?:ged|s|ging)?(?:\s+behind)?|trail(?:s|ed|ing)?|delayed|postponed|advanced|differ(?:s|ed)?|ahead|behind|older|younger|eldest|senior|age[ds]?|experience|duration|years of service|remain(?:s|ed)? in force|last(?:s|ed)?|increas(?:e|ed|es)|decreas(?:e|ed|es)|rose|fell)\b(?:\s+[[:alpha:]'-]+){0,3}$"#
            guard !preceding.hasSuffix("?"), text.range(of: measure, options: .regularExpression) != nil,
                  stem.range(of: predicate, options: .regularExpression) != nil else { return nil }
        }
        // An independent utterance or short reaction keeps the ordinary current-only prompt.
        // Conjunctions joining two full sentences do not need the previous translation.
        guard text.range(of: #"(?i)^(by|for|from|of|on|in|at|with|without|between|into|out|off|over|than|under|through|to|near|beside|across|before|after|above|below|along|underneath|inside|outside|onto|against)\b"#,
                         options: .regularExpression) != nil else { return nil }
        let prefix = displayed.trimmingCharacters(in: CharacterSet(charactersIn: "。！？、，,.!?;； ").union(.newlines))
        guard !prefix.isEmpty else { return nil }
        return .continueTranslation(source: stem + " " + text, prefix: prefix)
    }

    /// Chinese places time before the verb. Prefilling a finished verb can hide
    /// "yesterday" or "until Friday". Resolve only the open object with its own
    /// governing participle, keeping the entire current clause in the request.
    private static func completedObject(preceding: String, current: String) -> String? {
        let pastParticiples: [String: String] = [
            "receive": "received", "received": "received", "receives": "received",
            "collect": "collected", "collected": "collected", "collects": "collected",
            "accept": "accepted", "accepted": "accepted", "accepts": "accepted",
            "send": "sent", "sent": "sent", "sends": "sent",
            "make": "made", "made": "made", "makes": "made",
            "donate": "donated", "donated": "donated", "donates": "donated",
            "pay": "paid", "paid": "paid", "pays": "paid",
            "deliver": "delivered", "delivered": "delivered", "delivers": "delivered"
        ]
        // Require a genuinely open article or ordinal after the verb; an earlier
        // discussion of money is insufficient evidence about the next sentence.
        let tail = preceding.lowercased().split { !$0.isLetter && $0 != "'" }
        let determiners: Set<Substring> = ["a", "an", "the", "our", "their", "his", "her", "my", "your"]
        let modifiers: Set<Substring> = ["first", "second", "third", "next", "last", "final", "new", "small", "large", "initial", "remaining", "other"]
        var i = tail.count
        while i > 0, modifiers.contains(tail[i - 1]) { i -= 1 }
        guard i >= 2, determiners.contains(tail[i - 1]), let participle = pastParticiples[String(tail[i - 2])] else { return nil }
        // Restrict this transformation to material transfer; "made a mistake",
        // "paid a visit", and colloquial uses must keep the model's normal input.
        let nounPattern = #"(?i)^(?:(?:cash|bank|wire|monthly|rental|charitable|advance|partial|final|annual)\s+)?(?:payments?|funds?|donations?|deposits?|invoices?|checks?|cheques?|transfers?|refunds?|grants?|gifts?|parcels?|packages?|shipments?|deliveries|delivery|letters?|contributions?|scholarships?)\b"#
        guard let head = current.range(of: nounPattern, options: .regularExpression) else { return nil }
        let beforeVerb = tail[..<(i - 2)].suffix(3)
        // Modality and questions require a fuller clause than a passive participle.
        guard !beforeVerb.isEmpty, !beforeVerb.contains("please"),
              !beforeVerb.contains(where: { ["will", "would", "could", "may", "might", "should", "can", "to", "must", "never"].contains($0) }),
              !tail.prefix(1).contains(where: { ["please", "did", "do", "does", "can", "could", "will", "would", "have", "has", "don't", "never"].contains($0) }) else { return nil }
        let negative = beforeVerb.last.map { $0 == "not" || $0.hasSuffix("n't") } ?? false
        if negative {
            let plural = current[head].lowercased().hasSuffix("s")
            let past = beforeVerb.contains(where: { ["did", "didn't", "had", "hadn't"].contains($0) })
            let auxiliary = past ? (plural ? "were" : "was") : (plural ? "are" : "is")
            return current[head] + " " + auxiliary + " not " + participle + current[head.upperBound...]
        }
        return current[head] + " " + participle + current[head.upperBound...]
    }

    /// The generated value contains only new tokens. Reject an empty suffix or
    /// unsolicited repetition of the old Chinese sentence before it reaches history.
    static func accepted(_ candidate: String, prefix: String, original: String) -> String? {
        let result = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = result.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !content.isEmpty, !SubtitleDocument.isTranslationArtifact(result, original: original),
              !(prefix.count >= 5 && result.contains(prefix)) else { return nil }
        return result
    }
}

/// Translate a self-contained comparison with an explicit direction and time
/// measure. In a longer sentence use the same relation as a local glossary
/// entry; the translator still owns the subject, negation and remaining text.
struct EnglishLagMeasurement {
    let phrase: String
    let chinese: String
    let standalone: Bool

    private static let number = #"(?:\d+(?:\.\d+)?|a|an|(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(?:[ -](?:one|two|three|four|five|six|seven|eight|nine))?)"#
    private static let quantityPattern = #"(?:(about|around|approximately|roughly|over|more than|under|less than|at least|at most|up to)\s+)?("# + number
        + #")(?:\s*(?:\bto\b|(?<=\d)[–-](?=\d))\s*("# + number + #"))?\s+"#
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?i)\b(?:back\s+|lag(?:s|ging|ged)?\s+|fall(?:s|ing)?\s+|fell\s+|fallen\s+)?behind\s+by\s+"# + quantityPattern + #"(years?|months?|weeks?|days?|hours?|minutes?|seconds?)\b"#)
    private static let bareYears = try! NSRegularExpression(pattern:
        #"(?i)^by\s+"# + quantityPattern + #"(years?)[.!。！]?$"#)
    private static let qualifiers = ["about": "约", "around": "约", "approximately": "约", "roughly": "约",
        "over": "超过", "more than": "超过", "under": "不到", "less than": "不到",
        "at least": "至少", "at most": "最多", "up to": "最多"]
    private static let units = ["year": "年", "month": "个月", "week": "周", "day": "天",
        "hour": "小时", "minute": "分钟", "second": "秒"]

    static func read(_ text: String) -> Self? {
        guard text.localizedCaseInsensitiveContains("behind"), text.count <= 420,
              let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let span = Range(m.range, in: text) else { return nil }
        guard let amount = amount(in: text, match: m) else { return nil }
        let suffix = text[span.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = text[..<span.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        // These explicit age/time readings need the full sentence.
        if suffix.range(of: #"(?i)^(?:old|of age|ago|back in time)\b"#, options: .regularExpression) != nil { return nil }
        let exact = prefix.isEmpty && ["", ".", "!", "。", "！"].contains(suffix)
        return Self(phrase: String(text[span]), chinese: "落后" + amount, standalone: exact)
    }

    // ASR can drop the entire predicate. Standalone “by X years” supplies a
    // duration but no age, direction, or past/future anchor.
    static func neutralYears(_ original: String) -> String? {
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 100, text.lowercased().hasPrefix("by "),
              let match = bareYears.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return amount(in: text, match: match)
    }

    static func ageIsExplicit(in preceding: String?) -> Bool {
        preceding?.range(of: #"(?i)\b(?:older|younger|eldest|youngest|age[ds]?|age difference|age gap|senior|junior)\b"#, options: .regularExpression) != nil
    }

    /// A cloud provider may independently guess age for an orphan duration.
    /// Limit the repair to age units attached to a number in an otherwise
    /// numeric answer, preserving any other numbers or wording in full dialogue.
    static func repairAgeUnit(in translation: String, original: String, preceding: String?) -> String {
        guard translation.contains("岁") || translation.contains("歲"),
              let neutral = neutralYears(original), !ageIsExplicit(in: preceding) else { return translation }
        let number = #"(?:\d+(?:[.．]\d+)?|[零〇一二两兩三四五六七八九十百千万萬]+)"#
        let age = #"^\s*(?:(?:年龄|年齡|年龄范围|年齡範圍)?(?:大约|大約|约|約|为|為|在|从|從|介于|介於|至少|最多|不满|不滿|超过|超過)?)\s*("#
            + number + #")\s*[岁歲]?\s*(?:(?:至|到|和|与|與|[–~～－—-])\s*("# + number
            + #")\s*[岁歲]?)?(?:之间|之間|左右)?\s*[。.!！]?\s*$"#
        let expression = try! NSRegularExpression(pattern: age)
        guard let match = expression.firstMatch(in: translation, range: NSRange(translation.startIndex..., in: translation)) else { return translation }
        let sourceNumbers = neutral.ranges(of: try! Regex(#"\d+(?:\.\d+)?"#)).map { String(neutral[$0]) }
        let chinese = NumberFormatter()
        chinese.locale = Locale(identifier: "zh_CN")
        chinese.numberStyle = .spellOut
        let answerNumbers = [1, 2].compactMap { i -> String? in
            guard let r = Range(match.range(at: i), in: translation) else { return nil }
            let value = String(translation[r]).replacingOccurrences(of: "．", with: ".")
            if value.first?.isASCII == true { return value }
            return chinese.number(from: value.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? value)?.stringValue
        }
        guard answerNumbers == sourceNumbers else { return translation }
        return neutral + "。"
    }

    private static func amount(in text: String, match: NSTextCheckingResult) -> String? {
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { text[$0].lowercased() }
        }
        guard let from = group(2).flatMap(quantity), let unit = group(4),
              let measure = units[unit.hasSuffix("s") ? String(unit.dropLast()) : unit] else { return nil }
        let qualifier = group(1).flatMap { qualifiers[$0] } ?? ""
        var value = from
        if let upper = group(3) {
            guard let to = quantity(upper) else { return nil }
            value += "到" + to
        }
        return qualifier + value + measure
    }

    private static func quantity(_ token: String) -> String? {
        if token.first?.isNumber == true { return token }
        if token == "a" || token == "an" { return "1" }
        let words = token.replacingOccurrences(of: "-", with: " ")
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .spellOut
        guard let n = formatter.number(from: words.replacingOccurrences(of: " ", with: "-")),
              formatter.string(from: n)?.replacingOccurrences(of: "-", with: " ") == words else { return nil }
        return n.stringValue
    }
}
