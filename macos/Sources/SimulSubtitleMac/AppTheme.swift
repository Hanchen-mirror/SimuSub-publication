import AppKit
import SwiftUI

// Generated from the approved SimuSub 完整主题基调/theme-palettes.json.
// Each role has a complete light/dark value, including surfaces and typography.
enum AppTheme: String, CaseIterable, Identifiable {
    case blue, green, purple, yellow
    var id: String { rawValue }
    var title: String { switch self { case .blue: "雾蓝"; case .green: "鼠尾草绿"; case .purple: "柔紫"; case .yellow: "奶油黄" } }
}
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String { switch self { case .light: "浅色"; case .dark: "深色"; case .system: "跟随系统" } }
    var symbol: String { switch self { case .light: "sun.max"; case .dark: "moon"; case .system: "desktopcomputer" } }
}
enum ThemeRole: String, CaseIterable {
    case background, sidebar, surface, ink, muted, line, primary, primaryInk, soft, selection, control, caption, preview, dockSelected
}
enum ThemePalette {
    static func hex(_ theme: AppTheme, dark: Bool, role: ThemeRole) -> String {
        values[theme.rawValue]![dark ? "dark" : "light"]![role.rawValue]!
    }
    static func color(_ theme: AppTheme, dark: Bool, role: ThemeRole) -> NSColor {
        let value = UInt32(hex(theme, dark: dark, role: role).dropFirst(), radix: 16)!
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static let values: [String: [String: [String: String]]] = [
        "blue": [
            "light": ["background": "#f3f7fa", "sidebar": "#e8f0f5", "surface": "#fbfdff", "ink": "#2f414f", "muted": "#566c7b", "line": "#dce6ed", "primary": "#50728c", "primaryInk": "#456881", "soft": "#eaf1f6", "selection": "#d4e3ed", "control": "#f4f8fb", "caption": "#f7fbfd", "preview": "#e9f1f6", "dockSelected": "#ffffff"],
            "dark": ["background": "#202730", "sidebar": "#252f3a", "surface": "#2b3743", "ink": "#e5edf4", "muted": "#a8bccd", "line": "#405267", "primary": "#abc9df", "primaryInk": "#c3dbea", "soft": "#334454", "selection": "#405b70", "control": "#334252", "caption": "#191f27", "preview": "#25313d", "dockSelected": "#40576b"],
        ],
        "green": [
            "light": ["background": "#f3f7f3", "sidebar": "#e9f0e9", "surface": "#fcfefb", "ink": "#304337", "muted": "#596e5e", "line": "#dfe8df", "primary": "#53755f", "primaryInk": "#486b54", "soft": "#edf4ed", "selection": "#dae8da", "control": "#f4f8f2", "caption": "#f7fbf5", "preview": "#eaf2e9", "dockSelected": "#ffffff"],
            "dark": ["background": "#202824", "sidebar": "#253029", "surface": "#2b3730", "ink": "#e5eee7", "muted": "#abbfaf", "line": "#405248", "primary": "#b2d0bd", "primaryInk": "#c6dfce", "soft": "#34473b", "selection": "#435f4f", "control": "#334139", "caption": "#19211c", "preview": "#26332b", "dockSelected": "#405b49"],
        ],
        "purple": [
            "light": ["background": "#f8f5fa", "sidebar": "#f0eaf5", "surface": "#fdfbff", "ink": "#403548", "muted": "#70617c", "line": "#e7dfed", "primary": "#817091", "primaryInk": "#756287", "soft": "#f2ecf7", "selection": "#ded3e9", "control": "#faf6fc", "caption": "#faf6fd", "preview": "#efe7f5", "dockSelected": "#ffffff"],
            "dark": ["background": "#25212e", "sidebar": "#2d2637", "surface": "#352d40", "ink": "#eee7f4", "muted": "#bbaaca", "line": "#4d405b", "primary": "#b6a0d6", "primaryInk": "#cfbce8", "soft": "#42354f", "selection": "#59476e", "control": "#3d324a", "caption": "#1d1926", "preview": "#2b2337", "dockSelected": "#51405f"],
        ],
        "yellow": [
            "light": ["background": "#faf7ef", "sidebar": "#f2eddf", "surface": "#fffdf7", "ink": "#484032", "muted": "#72664e", "line": "#e9e1d0", "primary": "#887234", "primaryInk": "#7c682f", "soft": "#f6f0e1", "selection": "#eee2be", "control": "#faf7ee", "caption": "#fffaf0", "preview": "#f2ebda", "dockSelected": "#ffffff"],
            "dark": ["background": "#29261f", "sidebar": "#302c23", "surface": "#3a3429", "ink": "#f0eadc", "muted": "#c4b89d", "line": "#544b38", "primary": "#dfcf9e", "primaryInk": "#e9dcb6", "soft": "#49402d", "selection": "#64583a", "control": "#443c2e", "caption": "#221f19", "preview": "#332e23", "dockSelected": "#5a4d31"],
        ],
    ]
}

// NSColor providers also cover AppKit-hosted controls and independently hosted panels.
// The value is changed only on the main thread by HomeAppearance.
enum ThemeColor {
    static var selected: AppTheme = .purple
    static func color(_ role: ThemeRole) -> Color {
        let theme = selected
        return Color(nsColor: NSColor(name: NSColor.Name("SimuSub.\(theme.rawValue).\(role.rawValue)")) { appearance in
            ThemePalette.color(theme, dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, role: role)
        })
    }
    static var background: Color { color(.background) }
    static var sidebar: Color { color(.sidebar) }
    static var surface: Color { color(.surface) }
    static var ink: Color { color(.ink) }
    static var muted: Color { color(.muted) }
    static var line: Color { color(.line) }
    static var primary: Color { color(.primary) }
    static var primaryInk: Color { color(.primaryInk) }
    static var soft: Color { color(.soft) }
    static var selection: Color { color(.selection) }
    static var control: Color { color(.control) }
    static var caption: Color { color(.caption) }
    static var preview: Color { color(.preview) }
    static var dockSelected: Color { color(.dockSelected) }
}

private struct AppThemeIDKey: EnvironmentKey { static let defaultValue = "purple-system" }
extension EnvironmentValues {
    var appThemeID: String {
        get { self[AppThemeIDKey.self] }
        set { self[AppThemeIDKey.self] = newValue }
    }
}
struct AppThemeModifier: ViewModifier {
    @ObservedObject private var localization = AppLocalization.shared
    var clearBackground = false
    @EnvironmentObject private var appearance: HomeAppearance
    func body(content: Content) -> some View {
        content
            .buttonStyle(ThemeActionButtonStyle())
            .environment(\.appThemeID, appearance.theme.rawValue + "-" + appearance.mode.rawValue + "-" + String(appearance.isDark) + "-" + localization.language.rawValue)
            .environment(\.simuSubReduceMotion, appearance.reduceMotion)
            .environment(\.locale, Locale(identifier: localization.language.rawValue))
            .environment(\.colorScheme, appearance.colorScheme)
            .transaction { transaction in
                if appearance.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
            .preferredColorScheme(appearance.colorScheme)
            .tint(ThemeColor.primary)
            .accentColor(ThemeColor.primary)
            .foregroundStyle(ThemeColor.ink)
            .background(clearBackground ? Color.clear : ThemeColor.background)
    }
}
extension View {
    func appTheme(clearBackground: Bool = false) -> some View { modifier(AppThemeModifier(clearBackground: clearBackground)) }
    func themeCard() -> some View {
        padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ThemeColor.line.opacity(0.55)))
    }
}

struct ThemeActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let _ = appThemeID
        return configuration.label
            .interfaceFont(size: 13, weight: .medium)
            .foregroundStyle(prominent ? ThemeColor.surface : ThemeColor.ink)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(prominent ? ThemeColor.primary : configuration.isPressed ? ThemeColor.selection : ThemeColor.control, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? ThemeColor.primary : ThemeColor.line))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}
