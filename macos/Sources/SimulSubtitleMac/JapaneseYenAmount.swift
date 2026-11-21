import Foundation

/// Index sometimes drops a place value when translating a single spoken yen price.
/// Leave conversions, multiple prices, ranges and ambiguous quantities to the translator.
enum JapaneseYenAmount {
    private static let number = "0-9０-９零〇一二三四五六七八九十百千万萬億兆"
    private static let amount = try! NSRegularExpression(pattern:
        "(?<![" + number + "数幾何.,，．・点點~～〜–—\\-])([" + number + "]+)円")
    private static let translation = try! NSRegularExpression(pattern:
        "(?<![" + number + "几幾数數多.,，．点點~～〜–—\\-])([" + number + "]+)\\s*(日[元圆圓币幣]|元)")
    private static let ambiguous = try! NSRegularExpression(pattern:
        "ドル|人民元|ユーロ|ポンド|換算|両替|外貨|為替|通貨換算|[~～〜–—]|[" + number + "]から[" + number + "]")

    static func preserve(in result: String, source: String, target: SubtitleLanguage) -> String {
        let sourceRange = NSRange(source.startIndex..., in: source)
        guard source.filter({ $0 == "円" }).count == 1,
              ambiguous.firstMatch(in: source, range: sourceRange) == nil,
              let match = amount.firstMatch(in: source, range: sourceRange),
              let range = Range(match.range(at: 1), in: source) else { return result }
        let written = String(source[range]).precomposedStringWithCompatibilityMapping
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .spellOut
        let value: Int64
        if let digits = Int64(written) {
            value = digits
        } else if let parsed = formatter.number(from: written), formatter.string(from: parsed) == written {
            value = parsed.int64Value
        } else { return result }

        let matches = translation.matches(in: result, range: NSRange(result.startIndex..., in: result))
        guard matches.count == 1, let price = Range(matches[0].range, in: result),
              let numeral = Range(matches[0].range(at: 1), in: result),
              result.range(of: "美元|美金|人民币|人民幣|港元|港币|港幣|台币|台幣|臺幣|欧元|歐元|折合|折算|换算|換算", options: .regularExpression) == nil
        else { return result }
        formatter.locale = Locale(identifier: "zh_CN")
        let digits = String(result[numeral]).precomposedStringWithCompatibilityMapping
        guard let outputValue = Int64(digits) ?? formatter.number(from: digits)?.int64Value,
              value > 0, value.isMultiple(of: 10), outputValue == value / 10 else { return result }
        return result.replacingCharacters(in: price, with: String(value) + (target == .traditionalChinese ? "日圓" : "日元"))
    }
}
