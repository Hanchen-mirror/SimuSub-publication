import Combine
import Foundation
import SwiftUI

final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    private var defaults: UserDefaults = .standard
    @Published var language: SubtitleLanguage = .simplifiedChinese {
        didSet { defaults.set(language.rawValue, forKey: "interface.language.v141") }
    }
    func configure(defaults: UserDefaults) {
        self.defaults = defaults
        language = Self.preferredLanguage(defaults: defaults)
    }
    static func preferredLanguage(defaults: UserDefaults) -> SubtitleLanguage {
        defaults.string(forKey: "interface.language.v141").flatMap(SubtitleLanguage.init(rawValue:)) ?? .simplifiedChinese
    }
}

enum L10n {
    private static let translations: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "InterfaceStrings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return values
    }()
    private struct Template {
        let expression: NSRegularExpression
        let translations: [String: String]
    }
    private static let templates: [Template] = translations.compactMap { key, values in
        guard key.contains("%@") else { return nil }
        let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern).joined(separator: "(.*?)") + "$"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        return Template(expression: expression, translations: values)
    }
    static func text(_ value: String, language: SubtitleLanguage? = nil) -> String {
        let language = language ?? AppLocalization.shared.language
        if language == .simplifiedChinese { return value }
        if language == .traditionalChinese { return language.normalizeScript(value) }
        if let result = translations[value]?[language.rawValue] { return result }
        let fullRange = NSRange(value.startIndex..., in: value)
        for template in templates {
            guard let match = template.expression.firstMatch(in: value, range: fullRange),
                  let format = template.translations[language.rawValue] else { continue }
            let parts = format.components(separatedBy: "%@")
            var result = parts[0]
            for index in 1..<parts.count {
                if index < match.numberOfRanges, let range = Range(match.range(at: index), in: value) {
                    result += text(String(value[range]), language: language)
                }
                result += parts[index]
            }
            return result
        }
        return value
    }
    static func hasTranslation(_ key: String, language: SubtitleLanguage) -> Bool {
        language.isChinese || translations[key]?[language.rawValue] != nil
    }
}

struct InterfaceLanguageSettings: View {
    @ObservedObject private var localization = AppLocalization.shared
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(ThemeColor.muted)
            DesignMenuField(title: localization.language.nativeName) {
                ForEach([SubtitleLanguage.simplifiedChinese, .traditionalChinese, .english, .japanese]) { language in
                    Button(language.nativeName) { localization.language = language }
                }
            }.frame(width: 150).accessibilityLabel(L10n.text("界面语言"))
                .accessibilityIdentifier("settings.interfaceLanguage")
        }.help(L10n.text("界面语言"))
    }
}
