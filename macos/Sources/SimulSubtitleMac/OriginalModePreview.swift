import AppKit
import SwiftUI

/// Native rendering of the floating strip in original-only mode.
@MainActor
enum OriginalModePreview {
    private static var started = false
    static func runIfRequested(appearance: HomeAppearance) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--original-mode-preview"), args.count > i+1 else { return false }
        guard !started else { return true }
        started = true
        let directory = URL(fileURLWithPath: args[i+1])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let samples = ["等一下，我先把麦克风调小一点。", "今天就不打排位了，陪大家聊聊天。", "刚才那个不是我操作的，真的！"]
            let captions = samples.enumerated().map { i, text in
                Caption(start: Double(i*4), end: Double(i*4+3), original: text, translated: text,
                    sourceLanguage: .simplifiedChinese, targetLanguage: .simplifiedChinese)
            }
            for (name, mode, size) in [
                ("original-only-dark.png", AppearanceMode.dark, CGSize(width: 960, height: 230)),
                ("original-only-light.png", AppearanceMode.light, CGSize(width: 960, height: 230)),
                ("original-only-compact.png", AppearanceMode.dark, CGSize(width: 960, height: 70))
            ] {
                appearance.mode = mode
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.isOpaque = false; window.backgroundColor = .clear
                let strip = SubtitleStrip(captions: captions, presentation: .single, size: size, isPinned: false,
                    onTogglePin: {}, onExit: {}, onZoom: {}, onClose: {}, displayMode: .original,
                    onToggleDisplayMode: {}, onExport: { _ in }, onClear: {}, canClear: true,
                    isCapturing: true, onStartStop: {}, previewControlsVisible: true,
                    japaneseSize: 18, chineseSize: 20)
                    .environmentObject(appearance).appTheme().environmentObject(appearance)
                window.contentView = NSHostingView(rootView: strip)
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 250_000_000)
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                }
                window.close()
            }
        } catch { fputs("Original mode preview failed: \(error)\n", stderr) }
        NSApp.terminate(nil)
        return true
    }
}
