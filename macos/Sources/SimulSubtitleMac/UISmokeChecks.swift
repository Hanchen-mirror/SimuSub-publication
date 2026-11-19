import AppKit
import Foundation

@MainActor
enum UISmokeChecks {
    private static var started = false

    static func runIfRequested(model: AppModel) async {
        if let reportIndex = CommandLine.arguments.firstIndex(of: "--permission-report"),
           CommandLine.arguments.count > reportIndex + 1, !started {
            started = true
            model.permissions.refresh()
            if CommandLine.arguments.contains("--probe-application-access") {
                do { try await model.permissions.authorizeScreen() }
                catch { /* Actual system error is preserved in the snapshot. */ }
            }
            var report = model.permissions.snapshot
            report["processID"] = ProcessInfo.processInfo.processIdentifier
            report["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""
            report["modelsReady"] = model.readinessIssues.isEmpty
            if model.permissions.screenGranted {
                do {
                    report["shareableApplicationCount"] = try await AudioCaptureEngine.availableApplications().count
                    report["shareableContentAccess"] = "passed"
                } catch { report["shareableContentAccess"] = error.localizedDescription }
            } else { report["shareableContentAccess"] = "notAuthorized" }
            do {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: CommandLine.arguments[reportIndex + 1]))
            } catch { fputs("Permission report failed: \(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--relaunch-check"),
           CommandLine.arguments.count > index + 1, !started {
            started = true
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let parentReport: [String: Any] = ["oldPID": ProcessInfo.processInfo.processIdentifier,
                                             "bundle": Bundle.main.bundleURL.path]
            do {
                try JSONSerialization.data(withJSONObject: parentReport).write(to: reportURL.appendingPathExtension("parent.json"))
                try PermissionRecovery.relaunch(arguments: ["--permission-report", reportURL.path])
            } catch { fputs("Relaunch check failed: \(error.localizedDescription)\n", stderr) }
            return
        }
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-smoke-test"),
              CommandLine.arguments.count > index + 1, !started else { return }
        started = true
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [String] = []
        do {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard NSApp.windows.contains(where: { $0.isVisible && $0.contentView != nil }) else { throw UIError.noWindow }
            checks.append("main_window_visible")
            guard PermissionRecovery.relaunchBundleIDs.contains(Bundle.main.bundleIdentifier ?? "") else { throw UIError.initialState }
            checks.append("fresh_application_identity")
            guard model.captions.isEmpty, model.readinessIssues.count == 2 else { throw UIError.initialState }
            checks.append("empty_state_and_missing_models_detected")
            for section in AppSection.allCases {
                model.section = section
                try await Task.sleep(nanoseconds: 300_000_000)
                guard NSApp.windows.contains(where: { $0.isVisible }) else { throw UIError.noWindow }
                checks.append("rendered_\(section.rawValue)")
            }
            for (source, catalogID) in [(SubtitleLanguage.english, "whisper-base"), (.simplifiedChinese, "sensevoice")] {
                model.setSourceLanguage(source)
                let selectedID = model.profiles.first(where: { $0.id == model.selectedASRProfileID })?.localModelID
                guard selectedID == catalogID,
                      let definition = LocalModelDefinition.catalog.first(where: { $0.id == catalogID }) else {
                    throw UIError.unexpectedModel(source.rawValue, selectedID ?? "ReazonSpeech")
                }
                let expected = definition.bytes + model.modelStore.translationDownloadBytes
                let actual = try model.subtitleModelDownloadBytes()
                guard actual == expected else { throw UIError.unexpectedDownloadSize(source.rawValue, actual, expected) }
                checks.append("automatic_plan_and_total_" + source.rawValue)
            }
            model.setSourceLanguage(.japanese)
            guard model.profiles.first(where: { $0.id == model.selectedASRProfileID })?.localModelID == nil,
                  try model.subtitleModelDownloadBytes() == model.modelStore.asrDownloadBytes + model.modelStore.translationDownloadBytes,
                  !model.isStarting, !model.isCapturing, !model.isDownloadingModels else { throw UIError.initialState }
            checks.append("automatic_plan_and_total_ja")
            let report: [String: Any] = ["passed": true, "checks": checks, "bundle": Bundle.main.bundleIdentifier ?? "", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? ""]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
            NSApp.terminate(nil)
        } catch {
            let report: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: reportURL)
            NSApp.terminate(nil)
        }
    }

    private enum UIError: LocalizedError {
        case noWindow, initialState
        case unexpectedModel(String, String), unexpectedDownloadSize(String, Int64, Int64)
        var errorDescription: String? {
            switch self {
            case .noWindow, .initialState: "应用窗口或初始配置检查失败"
            case .unexpectedModel(let source, let selected): "Unexpected recognition model for \(source): \(selected)"
            case .unexpectedDownloadSize(let source, let actual, let expected): "Unexpected download size for \(source): \(actual), expected \(expected)"
            }
        }
    }
}
