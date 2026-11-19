import AppKit

@MainActor
enum SubtitleSavePanel {
    private static weak var presented: NSSavePanel?
    static var isPresented: Bool { presented != nil }

    static func present(format: SubtitleExportFormat, suggestedName: String, from owner: NSWindow?, save: @escaping (URL) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let presented, presented.isVisible {
            presented.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.text("导出字幕") + " · " + format.title
        panel.allowedContentTypes = [format.contentType]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = fileName(suggestedName, format: format)
        presented = panel

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            presented = nil
            guard response == .OK, let destination = panel.url else { return }
            // The panel already resolved the user's extension and any replacement prompt.
            save(destination)
        }
        if let owner, owner.isVisible, !owner.styleMask.contains(.nonactivatingPanel), owner.attachedSheet == nil {
            panel.beginSheetModal(for: owner, completionHandler: finish)
        } else {
            // The floating subtitle panel deliberately leaves the keyboard with the
            // source app. Editing a filename explicitly activates a key save panel.
            if let owner, owner.isVisible {
                panel.level = NSWindow.Level(rawValue: max(NSWindow.Level.modalPanel.rawValue, owner.level.rawValue + 1))
            }
            panel.begin(completionHandler: finish)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func fileName(_ suggested: String, format: SubtitleExportFormat) -> String {
        let cleaned = suggested.components(separatedBy: CharacterSet(charactersIn: "/:").union(.newlines))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cleaned.isEmpty ? "SimuSub" : cleaned
        let suffix = "." + format.rawValue
        return name.lowercased().hasSuffix(suffix) ? name : name + suffix
    }
}
