import Foundation

@MainActor
enum SubtitleLayoutPreview {
    static func renderIfRequested(model: AppModel, controller: SubtitlePanelController) async -> Bool {
        await SubtitlePanelChecks.runIfRequested(model: model, controller: controller, flag: "--preview-subtitle-layout")
    }
}
