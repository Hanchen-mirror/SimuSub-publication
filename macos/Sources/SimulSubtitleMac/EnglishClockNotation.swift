import Foundation

/// Whisper can omit the separator in a clock time. Preserve ambiguous numbers unless
/// their local English phrase identifies a time and the hour/minute pair is valid.
enum EnglishClockNotation {
    private static func pattern(_ text: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: text, options: [.caseInsensitive])
    }

    // The lookarounds exclude parts of dates, versions, addresses with slashes, and IDs.
    private static let number = pattern(#"(?<![\w.:/#$£€¥+\-])([0-9]{1,2})([.:]?)([0-9]{2})(?![\w:/\-]|\.[0-9])"#)
    private static let preposition = pattern(#"\b(at|by|until|before|after|around)\s+$"#)
    private static let action = pattern(#"\b(arriv(?:e[ds]?|ing|al)|depart\w*|leave[sd]?|leaving|left|start\w*|begin\w*|began|end(?:s|ed|ing)?|finish\w*|meet(?:s|ing)?|met|open(?:s|ed|ing)?|clos(?:e[ds]?|ing)|schedul\w*|deadline|due|wake|woke|return\w*|deliver\w*|call(?:s|ed|ing)?|ready|alarm|bedtime|curfew)\b"#)
    private static let financial = pattern(#"\b(pric\w*|cost\w*|bid\w*|paid|pay\w*|trad\w*|quot\w*|valu\w*|rate[sd]?|sold|sell\w*|bought|buy\w*|discount\w*|increas\w*|decreas\w*|reduc\w*|rais\w*|profit\w*|loss\w*|percent\w*|count\w*|population|score\w*|speed\w*|version|model|capacity|temperature)\b"#)
    private static let meridiem = pattern(#"^\s*[ap]\.?m\.?\b"#)
    private static let historical = pattern(#"\b(years?|centur\w*|archive\w*|histor\w*|chronolog\w*|eras?|reign\w*)\b"#)
    private static let timeSuffix = pattern(#"^\s*(?:[ap]\.?m\.?\b|hours\b|(?:local\s+time|UTC|GMT)\b(?!\s+(?:street|avenue|road|boulevard|lane|square)\b)|(?:this|tomorrow|yesterday)\s+(?:morning|afternoon|evening)\b|(?:in the|that)\s+(?:morning|afternoon|evening)\b|tonight\b|tomorrow\b)"#)
    private static let timeZone = pattern(#"^\s*(?:local\s+time|UTC|GMT)\b(?!\s+(?:street|avenue|road|boulevard|lane|square)\b)"#)
    private static let clockReading = pattern(#"\b(?:the\s+(?:(?:local|departure|arrival|start)\s+)?time\s+(?:is|was)|the\s+clock\s+(?:reads?|shows?|says?))\s*$"#)
    private static let asksTime = pattern(#"\bwhat\s+time\b(?!\s+(?:zone|period|signature|limit|of\s+(?:the\s+)?year)\b)|\bwhen\s+(?:does|did|will|shall|do|can)\b[^.!?]*\b(?:leave|arrive|start|begin|depart|meet|open|close)\b"#)
    private static let answerPrefix = pattern(#"^\s*[“\"']?\s*(?:at\s+)?$"#)
    private static let answerEnding = pattern(#"^\s*,?\s*(?:(?:sir|madam|ma['’]am)|(?:mr|mrs|ms|dr|miss)\.?\s+[\p{L}’'-]+)?\s*[.!?…]?[”\"']?\s*$"#)
    private static let chineseAnswerPrefix = pattern(#"(?:^|[。！？!?\n])\s*(?:在|是|在于|約|约)?\s*$"#)
    private static let chineseAnswerEnding = pattern(#"^([号號]?)\s*[,，、]?\s*(?:[\p{Han}·]{0,12}(?:先生|女士|小姐|医生|醫生))?\s*[。！？.!?]?\s*$"#)
    private static let sentenceEnd = CharacterSet(charactersIn: ".!?;\n")
    private static let endOfPhrase = pattern(#"^\s*(?:$|[,;.!?]|and\b|or\b|so\b|to\b|on\b|sharp\b|today\b|yesterday\b|when\b|(?:the|we|he|she|they|you|i)\b)"#)
    private static let initialClause = pattern(#"^\s*,?\s*(?:the|a|an|we|he|she|they|you|i)\s+"#)
    private static let chineseNumber = pattern(#"(?<![0-9A-Za-z.:：￥¥$])([0-9]{1,2})[.:：]?([0-9]{2})(?![0-9A-Za-z:：]|\.[0-9])"#)
    private static let chineseClock = pattern(#"([零〇一二两兩三四五六七八九十0-9]+)[点點时時]([零〇一二三四五六七八九十0-9]+)分?"#)
    private static let temporalPrefix = pattern(#"(?:凌晨|早上|上午|中午|下午|傍晚|晚上|今晚|明早|明晚|定于|定於|从|從|在|于|於|到|至)\s*$"#)
    private static let temporalSuffix = pattern(#"^\s*(?:之前|以前|前|之后|之後|以后|以後|后|後|时|時|开始|開始|出发|出發|发车|發車|开车|開車|到达|到達|抵达|抵達|结束|結束|截止|开场|開場)"#)
    private static let quantitySuffix = pattern(#"^\s*(?:元|美元|美金|日元|港元|英镑|英鎊|吨|噸|公斤|千克|件|箱|个|個|台|号|號|年|万|萬|%|％|米|英尺|度|人|单|單|张|張|页|頁|分钟|分鐘|小时|小時)"#)

    private struct Clock {
        var range: NSRange
        var hour: Int
        var minute: Int
        // Keep an explicitly written leading zero, e.g. 09:05.
        var display: String
        var shortAnswer: Bool
    }

    static func source(_ text: String, previous: String? = nil) -> String {
        let result = NSMutableString(string: text)
        for clock in clocks(in: text, previous: previous).reversed() {
            result.replaceCharacters(in: clock.range, with: clock.display)
        }
        return result as String
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func clocks(in text: String, previous: String? = nil) -> [Clock] {
        let ns = text as NSString
        return number.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let h = ns.substring(with: match.range(at: 1)), m = ns.substring(with: match.range(at: 3))
            guard let hour = Int(h), hour < 24, let minute = Int(m), minute < 60 else { return nil }
            let separator = ns.substring(with: match.range(at: 2))
            let before = ns.substring(to: match.range.location), after = ns.substring(from: NSMaxRange(match.range))
            let clauses = before.components(separatedBy: sentenceEnd)
            let tail = clauses.last ?? ""
            let compactAnswer = matches(answerPrefix, tail) && matches(answerEnding, after)
            let prior = clauses.count > 1 ? clauses.dropLast().last : previous
            let lastQuestion = prior?.components(separatedBy: sentenceEnd)
                .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
            let answersQuestion = compactAnswer && matches(asksTime, lastQuestion)
            // ASR can also omit punctuation between the question and “at [time], sir”.
            let unpunctuatedAnswer = matches(asksTime, tail) && matches(preposition, tail) && matches(answerEnding, after)
            let continued = before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? previous : nil
            let left = ((continued.map { $0 + " " } ?? "") + before)
                .components(separatedBy: CharacterSet(charactersIn: ",.;!?\n")).last ?? ""
            let hasSuffix = matches(timeSuffix, after)
            // 19xx / 20xx are very often years. Require an explicit time marker.
            if separator.isEmpty && (hour == 19 || hour == 20) && !hasSuffix { return nil }
            let marker = preposition.firstMatch(in: left, range: NSRange(left.startIndex..., in: left))
            let prefix = marker.map { (left as NSString).substring(to: $0.range.location) }
            let timeContext = prefix.map { matches(action, $0) && !matches(financial, $0) && !matches(historical, $0) } ?? false
            let fronted = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                && matches(initialClause, after)
            // A dangling prior phrase supplies context only to its opening numeric continuation.
            // A previously normalized cross-cue token carries its explicit colon into translation.
            let barePreposition = prefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let explicitZone = marker != nil && matches(timeZone, after)
                && !matches(financial, left) && !matches(historical, left)
            let anchoredSuffix = hasSuffix && (timeContext || barePreposition || explicitZone || matches(meridiem, after))
            if separator != ":" && !anchoredSuffix && !answersQuestion && !unpunctuatedAnswer
                && !((timeContext || fronted || matches(clockReading, left)) && matches(endOfPhrase, after)) { return nil }
            return Clock(range: match.range, hour: hour, minute: minute, display: h + ":" + m,
                         shortAnswer: compactAnswer || unpunctuatedAnswer)
        }
    }

    /// Reconcile only clock values present in the corresponding English cue. This
    /// prevents an ungrounded change to numbers in an otherwise unrelated translation.
    static func translation(_ text: String, source: String) -> String {
        let known = clocks(in: source)
        guard !known.isEmpty else { return text }
        var result = NSMutableString(string: text)
        for expression in [chineseNumber, chineseClock] {
            let value = result as String
            let ns = value as NSString
            let updates = NSMutableString(string: value)
            for match in expression.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed() {
                let h = chineseValue(ns.substring(with: match.range(at: 1)))
                let m = chineseValue(ns.substring(with: match.range(at: 2)))
                guard let clock = known.first(where: { $0.hour == h && $0.minute == m }) else { continue }
                let before = ns.substring(to: match.range.location), after = ns.substring(from: NSMaxRange(match.range))
                // A bare numeric answer may be mistranslated as a house number. The
                // original must itself be a clock-only reply, and its translated
                // number must cover the whole answer apart from the form of address.
                if expression === chineseNumber, clock.shortAnswer, matches(chineseAnswerPrefix, before),
                   let ending = chineseAnswerEnding.firstMatch(in: after, range: NSRange(after.startIndex..., in: after)) {
                    updates.replaceCharacters(in: NSRange(location: match.range.location, length: match.range.length + ending.range(at: 1).length),
                                              with: clock.display)
                    continue
                }
                guard !matches(quantitySuffix, after) else { continue }
                if expression === chineseNumber {
                    let token = ns.substring(with: match.range)
                    guard token.contains(":") || token.contains("：") || matches(temporalPrefix, before)
                        || matches(temporalSuffix, after) else { continue }
                }
                updates.replaceCharacters(in: match.range, with: clock.display)
            }
            result = updates
        }
        return result as String
    }

    private static func chineseValue(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3,
                                      "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let split = value.firstIndex(of: "十") {
            let tens = value[..<split], units = value[value.index(after: split)...]
            guard tens.count <= 1, units.count <= 1 else { return nil }
            let t = tens.first.flatMap { digits[$0] } ?? 1
            let u = units.first.flatMap { digits[$0] } ?? 0
            return t * 10 + u
        }
        let parts = value.compactMap { digits[$0] }
        guard parts.count == value.count, parts.count <= 2 else { return nil }
        return parts.reduce(0) { $0 * 10 + $1 }
    }
}
