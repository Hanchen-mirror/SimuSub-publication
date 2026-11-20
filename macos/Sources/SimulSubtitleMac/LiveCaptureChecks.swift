import AppKit
import Combine
import Foundation

/// Opt-in diagnostics run inside the real application bundle and capture only the requested app.
@MainActor
enum LiveCaptureChecks {
    private static var started = false

    static func runIfRequested(model: AppModel) async -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--live-capture-test"), arguments.count > index + 3, !started else { return false }
        started = true
        if arguments.contains("--capture-original-only") { model.subtitleDisplayMode = .original }
        let bundleID = arguments[index + 1]
        let trace = arguments.contains("--capture-trace")
        let duration = min(trace ? 180 : 45, max(6, Double(arguments[index + 2]) ?? 18))
        let reportURL = URL(fileURLWithPath: arguments[index + 3])
        var result: [String: Any] = ["operation": "liveApplicationCapture", "selectedApplication": bundleID,
                                   "durationRequested": duration, "input": "ScreenCaptureKit live audio", "cloudUsed": false,
                                   "originalOnly": model.originalOnly]
        do {
            var switchTarget: SubtitleLanguage?
            if let flag = arguments.firstIndex(of: "--capture-switch-target") {
                result["languageSwitch"] = ["passed": false]
                guard flag + 1 < arguments.count,
                      let requested = SubtitleLanguage(rawValue: arguments[flag + 1]),
                      requested != model.targetLanguage, requested != model.sourceLanguage, !model.originalOnly else {
                    throw DiagnosticError.failed("切换测试需要双语模式以及不同于当前源语言和目标语言的有效语言代码")
                }
                switchTarget = requested
            }
            try await model.permissions.authorizeScreen()
            let apps = try await AudioCaptureEngine.availableApplications()
            result["availableApplications"] = apps.map { ["bundleIdentifier": $0.bundleIdentifier, "name": $0.name] }
            if bundleID == AudioCaptureEngine.systemAudioID {
                model.setSubtitleSource(id: bundleID, name: "Mac 声音")
            } else {
                guard let app = apps.first(where: { $0.bundleIdentifier == bundleID }) else { throw AudioCaptureError.applicationUnavailable }
                model.chooseApplication(app)
            }
            let existingCueIDs = Set(model.captions.map(\.id))
            model.startCapture()
            let startupDeadline = Date().addingTimeInterval(60)
            while model.isStarting && Date() < startupDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
            guard model.isCapturing else { throw DiagnosticError.failed(model.errorMessage ?? model.status) }
            result["captureStarted"] = true
            if arguments.contains("--show-capture-panel") {
                model.isSubtitleOnly = true
            }
            // Keep event timing separate from audio timestamps. A preview can be
            // replaced before the final cue is exported.
            var events: [[String: Any]] = []
            var previous: [UUID: String] = [:]
            let captureReady = ProcessInfo.processInfo.systemUptime
            var sourceEvents: [[String: Any]] = []
            var previousSources: [UUID: String] = [:]
            var japaneseWindows: [[String: Any]] = []
            if trace {
                model.onJapaneseHypothesis = { id, start, end, final, raw, repaired in
                    japaneseWindows.append(["id": id.uuidString, "start": start, "end": end, "final": final,
                        "raw": raw.text, "reconciled": repaired, "tokens": raw.tokens.map { ["text": $0.text, "time": $0.time] as [String: Any] }])
                }
            }
            defer { model.onJapaneseHypothesis = nil }
            let observation: AnyCancellable? = trace ? model.$captions.sink { cues in
                let elapsed = ProcessInfo.processInfo.systemUptime - captureReady
                for cue in cues where !cue.original.isEmpty {
                    let state = (cue.isDraft ? "draft" : "final") + cue.original
                    guard previousSources[cue.id] != state else { continue }
                    previousSources[cue.id] = state
                    sourceEvents.append(["secondsFromCaptureReady": elapsed, "cueID": cue.id.uuidString,
                                         "draft": cue.isDraft, "start": cue.start, "end": cue.end, "source": cue.original])
                }
                for cue in cues where !cue.translated.isEmpty && cue.translated != "正在翻译…" {
                    let state = (cue.isDraft ? "draft" : "final") + cue.translated
                    guard previous[cue.id] != state else { continue }
                    previous[cue.id] = state
                    events.append(["secondsFromCaptureReady": elapsed, "start": cue.start, "end": cue.end,
                                   "cueID": cue.id.uuidString, "draft": cue.isDraft,
                                   "source": cue.original, "translation": cue.translated])
                }
            } : nil
            var switchResult = true
            if let target = switchTarget {
                let source = model.sourceLanguage, oldTarget = model.targetLanguage
                func completedCues(for destination: SubtitleLanguage) -> [Caption] {
                    model.captions.filter {
                        !existingCueIDs.contains($0.id) && !$0.isDraft && !$0.original.isEmpty
                            && $0.sourceLanguage == source && $0.targetLanguage == destination
                            && SubtitleDocument.completedTranslation(SubtitleDocument.liveCaption($0)) != nil
                    }
                }
                let beforeDeadline = Date().addingTimeInterval(duration)
                while completedCues(for: oldTarget).isEmpty && model.isCapturing && Date() < beforeDeadline {
                    try await Task.sleep(nanoseconds: 120_000_000)
                }
                let before = completedCues(for: oldTarget)
                var change: [String: Any] = ["passed": false, "sourceLanguage": source.rawValue,
                    "oldTarget": oldTarget.rawValue, "newTarget": target.rawValue, "originalCueCount": before.count,
                    "oldCaptureSampleCount": model.capturedSampleCount]
                result["languageSwitch"] = change
                guard !before.isEmpty, model.isCapturing else { throw DiagnosticError.failed("切换前未收到本次采音产生的完整译文") }
                await model.applySubtitleLanguages(source: source, target: target)
                let restartDeadline = Date().addingTimeInterval(60)
                while model.isStarting && Date() < restartDeadline { try await Task.sleep(nanoseconds: 120_000_000) }
                let resumed = model.isCapturing && model.sourceLanguage == source && model.targetLanguage == target
                change["captureResumed"] = resumed
                result["languageSwitch"] = change
                guard resumed else { throw DiagnosticError.failed(model.errorMessage ?? model.subtitleStartError ?? model.status) }
                let afterDeadline = Date().addingTimeInterval(duration)
                while completedCues(for: target).isEmpty && model.isCapturing && Date() < afterDeadline {
                    try await Task.sleep(nanoseconds: 120_000_000)
                }
                let after = completedCues(for: target)
                let historyPreserved = before.allSatisfy { old in
                    model.captions.contains { $0.id == old.id && $0.original == old.original
                        && $0.translated == old.translated && $0.targetLanguage == old.targetLanguage }
                }
                let sameApp = model.selectedAppBundleID == bundleID
                switchResult = historyPreserved && sameApp && !after.isEmpty
                    && model.capturedSampleCount > 0 && model.capturedPeak > 0.003
                change["historyPreserved"] = historyPreserved
                change["sameAudioApplication"] = sameApp
                change["newCueCount"] = after.count
                change["newCueIDs"] = after.map { $0.id.uuidString }
                change["newCaptureSampleCount"] = model.capturedSampleCount
                change["passed"] = switchResult
                result["languageSwitch"] = change
            } else {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }
            model.stopCapture()
            let completionDeadline = Date().addingTimeInterval(120)
            while model.isStopping && Date() < completionDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
            guard !model.isStopping else { throw DiagnosticError.failed("字幕处理超时，未完成测试") }
            if let observation {
                observation.cancel()
                result["translationEvents"] = events
                result["sourceEvents"] = sourceEvents
                if !japaneseWindows.isEmpty { result["japaneseWindows"] = japaneseWindows }
                result["captureReadyUptime"] = captureReady
            }
            result["capturedChunkCount"] = model.capturedChunkCount
            result["refinedEnglishVocalCues"] = model.refinedEnglishVocalCues
            result["englishVocalLoopCounts"] = model.englishVocalLoopCounts
            result["capturedSampleCount"] = model.capturedSampleCount
            result["audioPeak"] = model.capturedPeak
            result["firstOriginalLatencySeconds"] = model.firstOriginalLatency.map { $0 as Any } ?? NSNull()
            result["firstTranslationLatencySeconds"] = model.firstTranslationLatency.map { $0 as Any } ?? NSNull()
            result["firstPreviewTranslationLatencySeconds"] = model.firstPreviewTranslationLatency.map { $0 as Any } ?? NSNull()
            result["firstFinalTranslationLatencySeconds"] = model.firstFinalTranslationLatency.map { $0 as Any } ?? NSNull()
            result["segmentation"] = "Live ScreenCaptureKit input through the application speech frontend"
            result["captions"] = model.captions.map { ["cueID": $0.id.uuidString, "start": $0.start, "end": $0.end, "original": $0.original, "translated": $0.translated] as [String: Any] }
            let translated = model.captions.contains { !$0.translated.isEmpty && !$0.translated.hasPrefix("翻译失败") && !$0.translated.hasPrefix("译文未完成") && $0.translated != "正在翻译…" }
            let completed = model.originalOnly ? model.captions.contains { $0.isOriginalOnly } : translated
            result["passed"] = model.capturedSampleCount > 0 && model.capturedPeak > 0.003 && completed && switchResult
            result["status"] = model.status
            if !switchResult { result["error"] = "换向后的新字幕、声音来源或旧字幕保留检查失败" }
            if !completed { result["error"] = "未生成完整字幕，测试未通过" }
            if !model.captions.isEmpty { try AppModel.srt(model.captions).write(to: reportURL.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
        } catch { result["passed"] = false; result["error"] = error.localizedDescription }
        model.permissions.refresh()
        result.merge(model.permissions.snapshot) { _, new in new }
        write(result, to: reportURL)
        await model.shutdownLocalEngines()
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
