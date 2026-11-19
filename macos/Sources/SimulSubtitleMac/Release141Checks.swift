import AppKit
import Foundation
import SwiftUI

private final class LanguageCheckProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// Opt-in, silent checks. API traffic is intercepted; existing models are read only.
@MainActor
enum Release141Checks {
    private static var started = false
    static func runIfRequested(model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore,
                               subtitles: SubtitlePanelController) async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--release-141-check"), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }; started = true
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        var checks: [String] = [], translations: [[String: String]] = []
        var windows: [NSWindow] = []
        let suite = "SimuSub.LanguageChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); LanguageCheckProtocol.handler = nil }
        func require(_ value: Bool, _ name: String) throws {
            guard value else { throw ClipError.message(name) }
            checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func host<V: View>(_ root: V) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root.environmentObject(model).environmentObject(model.permissions)
                .environmentObject(appearance).environmentObject(monitor).environmentObject(subtitles).appTheme().environmentObject(appearance))
            window.orderFront(nil); windows.append(window); return window
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defaults.set(SubtitleLanguage.japanese.rawValue, forKey: "interface.language.v141")
            let isolated = AppModel(defaults: defaults, modelStore: LocalModelStore(root: output.appendingPathComponent("empty-models")))
            try require(isolated.targetLanguage == .japanese && isolated.sourceLanguage == .english, "fresh_target_follows_interface_language")
            isolated.setSourceLanguage(.english); isolated.setTargetLanguage(.traditionalChinese)
            let restored = AppModel(defaults: defaults, modelStore: isolated.modelStore)
            try require(restored.sourceLanguage == .english && restored.targetLanguage == .traditionalChinese, "language_direction_persists")
            defaults.set(["startAfterPicking": "no"], forKey: "subtitle.pendingPermissionSource.v143")
            let pendingPicker = AppModel(defaults: defaults, modelStore: isolated.modelStore)
            try require(pendingPicker.subtitleNeedsPermission && pendingPicker.selectedAppBundleID == nil, "permission_reopen_restores_picker_without_selected_source")
            defaults.set(["id": "com.apple.Safari", "name": "Safari"], forKey: "subtitle.pendingPermissionSource.v143")
            let pendingStart = AppModel(defaults: defaults, modelStore: isolated.modelStore)
            try require(pendingStart.subtitleNeedsPermission && pendingStart.selectedAppBundleID == "com.apple.Safari"
                        && pendingStart.targetLanguage == .traditionalChinese, "permission_reopen_restores_selected_source_and_language")
            pendingStart.cancelSubtitlePermissionResume()
            isolated.swapLanguages()
            try require(isolated.sourceLanguage == .traditionalChinese && isolated.targetLanguage == .english, "swap_direction")
            isolated.setSourceLanguage(.english)
            try require(isolated.sourceLanguage == .english && isolated.targetLanguage == .traditionalChinese, "same_selection_swaps_without_duplicate_languages")
            isolated.isCapturing = true; isolated.swapLanguages(); isolated.setSourceLanguage(.japanese)
            try require(isolated.sourceLanguage == .english && isolated.targetLanguage == .traditionalChinese, "running_session_locks_direction")
            isolated.isCapturing = false
            try require(isolated.recognitionLanguageIssue == nil && isolated.profiles.first { $0.id == isolated.selectedASRProfileID }?.localModelID == "whisper-base",
                        "english_automatically_selects_whisper")
            let reazon = isolated.profiles.first { $0.kind == .local && $0.purpose == .speechRecognition && $0.localModelID == nil }
            isolated.selectedASRProfileID = reazon?.id
            try require(isolated.recognitionLanguageIssue != nil, "explicit_japanese_only_local_asr_blocks_other_sources")
            let restoredExplicit = AppModel(defaults: defaults, modelStore: isolated.modelStore)
            try require(restoredExplicit.selectedASRProfileID == reazon?.id, "explicit_recognition_preference_persists")
            isolated.setSourceLanguage(.japanese)
            try require(isolated.recognitionLanguageIssue == nil, "japanese_local_asr_still_available")
            isolated.isCapturing = true; isolated.selectedAppName = "Safari"
            try require(isolated.subtitleStatus.contains("等待语音") && !isolated.subtitleStatus.contains("日语"), "waiting_for_speech_is_language_neutral")
            isolated.isCapturing = false

            let old = Caption(start: 0, end: 2, original: "テスト", translated: "测试")
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
            legacy.removeValue(forKey: "sourceLanguage"); legacy.removeValue(forKey: "targetLanguage")
            let decoded = try JSONDecoder().decode(Caption.self, from: JSONSerialization.data(withJSONObject: legacy))
            try require(decoded.sourceLanguage == .japanese && decoded.targetLanguage == .simplifiedChinese, "old_caption_language_defaults_decode")
            let english = Caption(start: 0, end: 2, original: "We won't go to school.", translated: "明日は学校に行きません。", sourceLanguage: .english, targetLanguage: .japanese)
            try require(try JSONDecoder().decode(Caption.self, from: JSONEncoder().encode(english)) == english, "caption_direction_roundtrips")
            try require(SubtitleDocument.render([english], format: .srt, mode: .bilingual).contains(english.translated), "multilingual_export_keeps_text")

            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LanguageCheckProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            for source in SubtitleLanguage.allCases {
                var asr = ServiceProfile(name: "Mock", kind: .openAICompatible, purpose: .speechRecognition, baseURL: "https://unit.test/v1", model: "multilingual")
                asr.sourceLanguage = source.name
                LanguageCheckProtocol.handler = { request in
                    let body = String(decoding: requestBody(request), as: UTF8.self)
                    guard body.contains("name=\"language\"\r\n\r\n" + source.asrCode + "\r\n") else { throw ClipError.message("wrong_asr_language_" + source.rawValue) }
                    return try JSONSerialization.data(withJSONObject: ["text": source.isChinese ? "我们去学校。" : source.preview])
                }
                let recognized = try await OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: "mock", session: session).recognize(samples: [0.1])
                try require(!recognized.isEmpty && (source != .traditionalChinese || recognized.contains("學校")), "asr_language_and_script_" + source.rawValue)
                for target in SubtitleLanguage.allCases where source != target {
                    LanguageCheckProtocol.handler = { request in
                        let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
                        let messages = body["messages"] as! [[String: String]]
                        guard let prompt = messages.last?["content"], prompt.contains(source.name), prompt.contains(target.name),
                              prompt.contains("【当前原文】") else { throw ClipError.message("wrong_translation_direction") }
                        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": target.preview]]]])
                    }
                    let profile = ServiceProfile(name: "Mock", kind: .openAICompatible, purpose: .translation, baseURL: "https://unit.test/v1", model: "multilingual")
                    let translator = LanguageAwareTranslator(base: OpenAICompatibleTranslator(profile: profile, apiKey: "mock", session: session))
                    let result = try await translator.translate(source.preview, from: source.name, to: target.name)
                    try require(result == target.preview, "mock_translation_" + source.rawValue + "_" + target.rawValue)
                }
            }
            for source in SubtitleLanguage.allCases {
                for target in SubtitleLanguage.allCases where source != target {
                    defaults.set(source.rawValue, forKey: "subtitle.sourceLanguage.v141")
                    defaults.set(target.rawValue, forKey: "subtitle.targetLanguage.v141")
                    let pipeline = AppModel(defaults: defaults, modelStore: isolated.modelStore,
                        recognizer: LanguageStaticRecognizer(text: source.preview),
                        translator: LanguageDirectionProbe(source: source, target: target))
                    await pipeline.process([Float](repeating: 0.02, count: 16000), start: 0)
                    try require(pipeline.captions.count == 1 && pipeline.captions[0].sourceLanguage == source
                        && pipeline.captions[0].targetLanguage == target && !pipeline.captions[0].isDraft
                        && pipeline.captions[0].translated == target.preview,
                        "caption_pipeline_" + source.rawValue + "_" + target.rawValue)
                }
            }
            let retry = AppModel(defaults: defaults, modelStore: isolated.modelStore,
                translator: LanguageDirectionProbe(source: .japanese, target: .simplifiedChinese))
            retry.captions = [old]
            await retry.retryTranslation(old.id)
            try require(retry.captions[0].translated == SubtitleLanguage.simplifiedChinese.preview, "retry_preserves_caption_direction_after_selection_changes")
            let glossary = GlossaryTranslator(base: LanguagePromptProbe(), terms: VTuberGlossary.defaults)
            _ = try await glossary.translate("雑談", from: "Japanese", to: "English")
            try require(true, "japanese_chinese_glossary_does_not_leak_to_english")

            let localization = AppLocalization.shared
            localization.configure(defaults: defaults)
            let subtitleWindow = host(HStack(spacing: 0) {
                WorkspaceSidebar(selected: .subtitle, onSelect: { _ in }).frame(width: DesignV23.sidebar)
                SubtitleConfiguration(onServices: {})
            })
            let settingsWindow = host(HStack(spacing: 0) {
                WorkspaceSidebar(selected: .settings, onSelect: { _ in }).frame(width: DesignV23.sidebar)
                SettingsWindow(subtitleFontsFirst: true)
            })
            for language in [SubtitleLanguage.simplifiedChinese, .traditionalChinese, .english, .japanese] {
                localization.language = language
                try require(L10n.text("字幕同传") != "字幕同传" || language == .simplifiedChinese, "navigation_translation_" + language.rawValue)
                let reload = AppLocalization(); reload.configure(defaults: defaults)
                try require(reload.language == language, "interface_language_persists_" + language.rawValue)
                for mode in [AppearanceMode.light, .dark] {
                    appearance.mode = mode
                    try await Task.sleep(nanoseconds: 180_000_000)
                    try snapshot(subtitleWindow, output.appendingPathComponent(language.rawValue + "-" + mode.rawValue + "-subtitle.png"))
                    try snapshot(settingsWindow, output.appendingPathComponent(language.rawValue + "-" + mode.rawValue + "-settings.png"))
                }
            }
            localization.language = .simplifiedChinese
            for theme in AppTheme.allCases {
                appearance.theme = theme; appearance.mode = .dark
                model.isSubtitleOnly = true; subtitles.show()
                let frame = subtitles.panel!.frame
                // The actual floating-window entry, with each previously crashing page.
                for category in ["录制", "平台", "权限", "外观"] {
                    subtitles.openSubtitleSettings(initialCategory: category)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    try require(subtitles.settingsWindow?.isVisible == true && subtitles.panel!.frame == frame,
                                "floating_settings_" + theme.rawValue + "_" + category)
                    try snapshot(subtitles.settingsWindow!, output.appendingPathComponent(theme.rawValue + "-floating-" + category + ".png"))
                }
            }
            subtitles.settingsWindow?.close(); subtitles.returnHome()

            if let rootIndex = CommandLine.arguments.firstIndex(of: "--v141-real-models"), CommandLine.arguments.count > rootIndex + 1 {
                let store = LocalModelStore(root: URL(fileURLWithPath: CommandLine.arguments[rootIndex + 1]))
                try require(try await store.verifyInstalled(for: .translation), "shared_translation_model_verified_read_only")
                let engine = try await Task.detached { try LocalLlamaTranslator(modelPath: store.translationModelPath) }.value
                let translator = LanguageAwareTranslator(base: GlossaryTranslator(base: engine, terms: VTuberGlossary.defaults))
                let examples: [SubtitleLanguage: String] = [.japanese: "明日は雨が降るので、学校には行きません。", .simplifiedChinese: "明天会下雨，所以我们不会去学校。", .traditionalChinese: "明天會下雨，所以我們不會去學校。", .english: "It will rain tomorrow, so we won't go to school."]
                for source in SubtitleLanguage.allCases {
                    for target in SubtitleLanguage.allCases where source != target {
                        let result = try await translator.translate(examples[source]!, from: source.name, to: target.name)
                        translations.append(["source": source.rawValue, "target": target.rawValue, "original": examples[source]!, "translated": result])
                        try require(!result.isEmpty && result != examples[source]!, "real_translation_" + source.rawValue + "_" + target.rawValue)
                    }
                }
            }
            try write(["passed": true, "checks": checks, "translations": translations, "network": "mocked", "audioCapture": false, "modelDownloads": false], to: output.appendingPathComponent("release-141-checks.json"))
        } catch {
            print("FAIL: " + error.localizedDescription)
            try? write(["passed": false, "checks": checks, "translations": translations, "error": error.localizedDescription], to: output.appendingPathComponent("release-141-checks.json"))
        }
        for window in windows { window.close() }
        NSApp.terminate(nil)
        return true
    }
    nonisolated private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    private static func snapshot(_ window: NSWindow, _ url: URL) throws {
        let view = window.contentView!; view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

private struct LanguagePromptProbe: TextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String { text }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        guard context.terms.isEmpty else { throw ClipError.message("chinese_glossary_leaked_to_english") }
        return text
    }
}

private struct LanguageStaticRecognizer: SpeechRecognizing {
    let text: String
    func recognize(samples: [Float]) async throws -> String { text }
}
private struct LanguageDirectionProbe: TextTranslating {
    let source: SubtitleLanguage
    let target: SubtitleLanguage
    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        guard SubtitleLanguage.resolve(source) == self.source, SubtitleLanguage.resolve(target) == self.target else {
            throw ClipError.message("pipeline_language_mismatch")
        }
        return self.target.preview
    }
}
