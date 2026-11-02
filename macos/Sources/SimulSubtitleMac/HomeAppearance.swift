import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared by all windows. Imported wallpaper is copied into Application Support,
/// so removing or moving the user's original file does not break the home page.
@MainActor
final class HomeAppearance: ObservableObject {
    @Published private(set) var backgroundImage: NSImage?
    @Published var importError: String?
    @Published private(set) var isDark: Bool
    @Published var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme.v128"); apply() } }
    @Published var mode: AppearanceMode { didSet { defaults.set(mode.rawValue, forKey: "appearance.mode.v128"); apply() } }
    @Published var japaneseFont: String { didSet { defaults.set(japaneseFont, forKey: "subtitle.japaneseFont.v128") } }
    @Published var chineseFont: String { didSet { defaults.set(chineseFont, forKey: "subtitle.chineseFont.v128") } }
    private var systemObserver: NSObjectProtocol?
    private var effectiveAppearanceObserver: NSKeyValueObservation?
    private let defaults: UserDefaults
    private let backgroundURL: URL

    var hasBackground: Bool { backgroundImage != nil }
    var colorScheme: ColorScheme { isDark ? .dark : .light }

    init(defaults: UserDefaults = .standard, backgroundFile: URL? = nil) {
        self.defaults = defaults
        theme = AppTheme(rawValue: defaults.string(forKey: "appearance.theme.v128") ?? "") ?? .purple
        mode = AppearanceMode(rawValue: defaults.string(forKey: "appearance.mode.v128") ?? "")
            ?? (defaults.object(forKey: "home.dark.v099") == nil ? .system : (defaults.bool(forKey: "home.dark.v099") ? .dark : .light))
        japaneseFont = defaults.string(forKey: "subtitle.japaneseFont.v128") ?? ""
        chineseFont = defaults.string(forKey: "subtitle.chineseFont.v128") ?? ""
        isDark = false
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        backgroundURL = backgroundFile ?? support.appendingPathComponent("SimuSub/Appearance/background.png")
        if let data = try? Data(contentsOf: backgroundURL) {
            backgroundImage = Self.decodePNG(data)
        }
        apply()
        systemObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        effectiveAppearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.mode == .system else { return }
                let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if self.isDark != dark { self.isDark = dark }
            }
        }
    }

    deinit { if let systemObserver { DistributedNotificationCenter.default().removeObserver(systemObserver) } }

    func apply() {
        ThemeColor.selected = theme
        NSApplication.shared.appearance = mode == .system ? nil : NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        isDark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for window in NSApplication.shared.windows {
            window.appearance = NSApplication.shared.appearance
            if window.identifier?.rawValue != "subtitle.panel" {
                window.backgroundColor = ThemePalette.color(theme, dark: isDark, role: .background)
            }
            window.contentView?.needsDisplay = true
        }
    }

    func toggleTheme() { mode = isDark ? .light : .dark }

    func choosePNG() {
        let panel = NSOpenPanel()
        panel.title = "导入首页背景"
        panel.message = "选择一张 PNG 图片作为全窗口壁纸；将保持比例铺满，边缘可能裁切。"
        panel.prompt = "导入背景"
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 40 * 1_024 * 1_024 else { throw WallpaperError.tooLarge }
            let data = try Data(contentsOf: url)
            guard let image = Self.decodePNG(data) else { throw WallpaperError.invalidPNG }
            try FileManager.default.createDirectory(at: backgroundURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backgroundURL, options: .atomic)
            backgroundImage = image
        } catch {
            importError = error.localizedDescription
        }
    }

    func restoreDefault() {
        do {
            if FileManager.default.fileExists(atPath: backgroundURL.path) {
                try FileManager.default.removeItem(at: backgroundURL)
            }
            backgroundImage = nil
        } catch {
            importError = error.localizedDescription
        }
    }

    private static func decodePNG(_ data: Data) -> NSImage? {
        guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              bitmap.pixelsWide <= 16_384, bitmap.pixelsHigh <= 16_384,
              Double(bitmap.pixelsWide) * Double(bitmap.pixelsHigh) <= 50_000_000 else { return nil }
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        return image
    }

    private enum WallpaperError: LocalizedError {
        case tooLarge, invalidPNG
        var errorDescription: String? {
            switch self {
            case .tooLarge: "图片超过 40 MB，请选择较小的 PNG 图片。"
            case .invalidPNG: "无法读取这张 PNG 图片，请使用有效的 PNG，且分辨率不超过 5000 万像素、单边不超过 16384 像素。"
            }
        }
    }
}
