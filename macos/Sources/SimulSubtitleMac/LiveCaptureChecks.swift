import AppKit
import Foundation

/// Opt-in diagnostics run inside the real application bundle and capture only the requested app.
@MainActor
enum LiveCaptureChecks {
    private static var started = false

    static func runIfRequested(model: AppModel) async -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--live-capture-test"), arguments.count > index + 3, !started else { return false }
        started = true
        let bundleID = arguments[index + 1]
        let duration = min(45, max(6, Double(arguments[index + 2]) ?? 18))
        let reportURL = URL(fileURLWithPath: arguments[index + 3])
        var result: [String: Any] = ["operation": "liveApplicationCapture", "selectedApplication": bundleID,
                                   "durationRequested": duration, "input": "ScreenCaptureKit live audio", "cloudUsed": false]
        do {
            try await model.permissions.authorizeScreen()
            let apps = try await AudioCaptureEngine.availableApplications()
            result["availableApplications"] = apps.map { ["bundleIdentifier": $0.bundleIdentifier, "name": $0.name] }
            guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else { throw AudioCaptureError.applicationUnavailable }
            model.selectedASRProfileID = model.profiles.first(where: { $0.kind == .local && $0.purpose == .speechRecognition })?.id
            model.selectedTranslationProfileID = model.profiles.first(where: { $0.kind == .local && $0.purpose == .translation })?.id
            model.chooseApplication(app)
            model.startCapture()
            let startupDeadline = Date().addingTimeInterval(60)
            while model.isStarting && Date() < startupDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
            guard model.isCapturing else { throw DiagnosticError.failed(model.errorMessage ?? model.status) }
            result["captureStarted"] = true
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            model.stopCapture()
            let completionDeadline = Date().addingTimeInterval(120)
            while model.isStopping && Date() < completionDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
            guard !model.isStopping else { throw DiagnosticError.failed("字幕处理超时，未完成测试") }
            result["capturedChunkCount"] = model.capturedChunkCount
            result["capturedSampleCount"] = model.capturedSampleCount
            result["audioPeak"] = model.capturedPeak
            result["firstOriginalLatencySeconds"] = model.firstOriginalLatency.map { $0 as Any } ?? NSNull()
            result["firstTranslationLatencySeconds"] = model.firstTranslationLatency.map { $0 as Any } ?? NSNull()
            result["segmentation"] = "Silero VAD pauses, cumulative drafts, 24-second safety limit"
            result["captions"] = model.captions.map { ["start": $0.start, "end": $0.end, "original": $0.original, "translated": $0.translated] as [String: Any] }
            let translated = model.captions.contains { !$0.translated.isEmpty && !$0.translated.hasPrefix("翻译失败") && !$0.translated.hasPrefix("译文未完成") && $0.translated != "正在翻译…" }
            result["passed"] = model.capturedSampleCount > 0 && model.capturedPeak > 0.003 && translated
            result["status"] = model.status
            if !translated { result["error"] = "未生成完整双语字幕，测试未通过" }
            if !model.captions.isEmpty { try AppModel.srt(model.captions).write(to: reportURL.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
        } catch { result["passed"] = false; result["error"] = error.localizedDescription }
        model.permissions.refresh()
        result.merge(model.permissions.snapshot) { _, new in new }
        write(result, to: reportURL)
        NSApp.terminate(nil)
        return true
    }

    private static func write(_ result: [String: Any], to url: URL) {
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url) }
        catch { fputs("Capture diagnostic failed: \(error.localizedDescription)\n", stderr) }
    }

    private enum DiagnosticError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
