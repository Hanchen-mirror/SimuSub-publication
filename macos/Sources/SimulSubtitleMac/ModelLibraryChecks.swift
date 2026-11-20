import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
enum ModelLibraryChecks {
    private static var started = false
    static func runIfRequested(model: AppModel, appearance: HomeAppearance, monitor: LiveMonitorStore, clips: ClipStore) async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--model-library-check"), CommandLine.arguments.count > index + 1 else { return false }
        guard !started else { return true }; started = true
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let suite = "SimuSub.ModelLibraryChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var checks: [String] = [], results: [[String: String]] = [], windows: [NSWindow] = []
        defer { defaults.removePersistentDomain(forName: suite) }
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message(name) }; checks.append(name); print("CHECK: " + name); fflush(stdout)
        }
        func host<V: View>(_ root: V) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root.environmentObject(model).environmentObject(model.permissions)
                .environmentObject(appearance).environmentObject(monitor).environmentObject(clips).appTheme().environmentObject(appearance))
            window.orderFront(nil); windows.append(window); return window
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try require(!AppLaunchOptions.isDiagnostic(["SimuSub", "--show-permissions", "--request-audio-access"]), "permission_relaunch_uses_user_theme_and_storage")
            try require(AppLaunchOptions.isDiagnostic(["SimuSub", "--model-library-check", output.path]), "explicit_model_check_is_isolated")
            try require(LocalModelDefinition.catalog.count == 5 && LocalModelDefinition.catalog.allSatisfy { $0.files.allSatisfy { $0.sha256.count == 64 && $0.byteCount > 0 } }, "pinned_catalog_has_five_complete_models")
            let isolated = LocalModelLibrary(defaults: defaults, defaultRoot: output.appendingPathComponent("models"), downloadsAllowed: false)
            let custom = output.appendingPathComponent("custom-model-folder")
            isolated.setDirectory(custom)
            let restored = LocalModelLibrary(defaults: defaults, defaultRoot: output.appendingPathComponent("unused"), downloadsAllowed: false)
            try require(restored.directory == custom && !FileManager.default.fileExists(atPath: custom.path), "model_directory_persists_without_copying_or_moving_files")
            do {
                try await isolated.install(LocalModelDefinition.catalog[0]); throw ClipError.message("unexpected_download")
            } catch { try require(!FileManager.default.fileExists(atPath: custom.path), "ui_check_cannot_download") }
            let invalid = output.appendingPathComponent("invalid.gguf"); try Data("invalid".utf8).write(to: invalid)
            do { try LocalModelLibrary.validateGGUF(invalid); throw ClipError.message("invalid_gguf_accepted") }
            catch { try require(error.localizedDescription.contains("GGUF"), "invalid_gguf_rejected") }
            try FileManager.default.removeItem(at: invalid)
            let probe = PromptCapture()
            _ = try await PromptedLocalTranslator(base: probe, instructions: "保留否定，不要补写。")
                .translate("We won't go.", from: "英语", to: "简体中文")
            try require(await probe.guided, "local_custom_prompt_reaches_inference_context")

            let empty = ClipStore(root: output.appendingPathComponent("empty-library"))
            let emptyWindow = host(ClipLibrarySheet(onProject: { _ in }, onRecording: { _, _ in }, onImport: {}, onClose: {}).environmentObject(empty))
            if let fixtureIndex = CommandLine.arguments.firstIndex(of: "--model-fixture"), CommandLine.arguments.count > fixtureIndex + 1 {
                _ = try await clips.importVideo(URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1]))
            }
            let populated = host(ClipLibrarySheet(onProject: { _ in }, onRecording: { _, _ in }, onImport: {}, onClose: {}))
            let services = host(AdvancedServiceSettings())
            services.setContentSize(NSSize(width: 1100, height: 750))
            let editor = host(ClipWorkspace(onBack: {}))
            editor.setContentSize(NSSize(width: 1320, height: 900))
            for theme in AppTheme.allCases {
                for mode in [AppearanceMode.light, .dark] {
                    appearance.theme = theme; appearance.mode = mode
                    try await Task.sleep(nanoseconds: 180_000_000)
                    let key = theme.rawValue + "-" + mode.rawValue
                    for (name, window) in [("empty-history", emptyWindow), ("project-history", populated), ("models", services), ("editor", editor)] {
                        let bitmap = try capture(window)
                        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(key + "-" + name + ".png"))
                        let pixel = bitmap.colorAt(x: bitmap.pixelsWide - 5, y: 5)!
                        let expected = ThemePalette.color(theme, dark: mode == .dark, role: .background).usingColorSpace(bitmap.colorSpace)!
                        let delta = abs(pixel.redComponent - expected.redComponent) + abs(pixel.greenComponent - expected.greenComponent) + abs(pixel.blueComponent - expected.blueComponent)
                        try require(delta < 0.04, key + "_" + name + "_theme_matches")
                    }
                }
            }
            if let rootIndex = CommandLine.arguments.firstIndex(of: "--new-models-root"), CommandLine.arguments.count > rootIndex + 1 {
                let root = URL(fileURLWithPath: CommandLine.arguments[rootIndex + 1])
                let library = LocalModelLibrary(defaults: defaults, defaultRoot: root, downloadsAllowed: CommandLine.arguments.contains("--download-new-models"))
                library.setDirectory(root)
                for definition in LocalModelDefinition.catalog {
                    if !library.isUsable(definition) {
                        print("DOWNLOAD: " + definition.name); fflush(stdout)
                        var last = -1
                        let subscription = library.$progress.sink { value in
                            let step = Int(value * 10)
                            if step != last { last = step; print("PROGRESS: \(definition.id) \(step * 10)%"); fflush(stdout) }
                        }
                        try await library.install(definition)
                        subscription.cancel()
                    }
                    try await library.verifyReady(definition)
                    try require(library.isUsable(definition), "download_hashes_verified_" + definition.id)
                }
                let originalStore = LocalModelStore(root: root)
                try require(try await originalStore.verifyInstalled(for: .translation), "shared_index_model_unchanged")
                let live = AppModel(defaults: defaults, modelStore: originalStore)
                let preferredRecognition: [(SubtitleLanguage, String?)] = [(.english, "qwen3-asr"), (.simplifiedChinese, "qwen3-asr"), (.japanese, "qwen3-asr")]
                for (source, preferredID) in preferredRecognition {
                    live.setSourceLanguage(source)
                    try require(live.profiles.first { $0.id == live.selectedASRProfileID }?.localModelID == preferredID
                                && (try live.subtitleModelDownloadBytes()) == 0,
                                "automatic_plan_reuses_installed_models_" + source.rawValue)
                }
                live.setSourceLanguage(.english)
                let originalID = live.profiles.first { $0.kind == .local && $0.purpose == .translation && $0.localModelID == nil && $0.localModelPath == nil }?.id
                let reusedID = try await live.useTranslationModel(at: URL(fileURLWithPath: originalStore.translationModelPath))
                try require(reusedID == originalID && live.localTranslationPath(live.profiles.first { $0.id == reusedID }!) == originalStore.translationModelPath,
                            "import_shared_index_reuses_original_without_copy")
                let sense = LocalModelDefinition.catalog.first { $0.id == "sensevoice" }!
                let fixtureRoot = output.appendingPathComponent("speech-fixtures")
                try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
                for source in [SubtitleLanguage.english, .simplifiedChinese, .traditionalChinese, .japanese] {
                    let fixtureCode = source.isChinese ? "zh" : source.rawValue
                    let wav = fixtureRoot.appendingPathComponent(fixtureCode + ".wav")
                    if !FileManager.default.fileExists(atPath: wav.path) {
                        let url = sense.files[0].url.deletingLastPathComponent().appendingPathComponent("test_wavs/" + fixtureCode + ".wav")
                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        try data.write(to: wav)
                    }
                    let samples = try AudioFileReader.read(wav)
                    for definition in LocalModelDefinition.catalog.filter({ $0.purpose == .speechRecognition }) {
                        live.setSourceLanguage(source); live.setTargetLanguage(source.isChinese ? .english : .simplifiedChinese)
                        live.chooseRecognition(live.profiles.first { $0.localModelID == definition.id }?.id, for: source)
                        let services = try await live.makeSubtitleServices()
                        try require(services.sourceLanguage == source && services.targetLanguage == live.targetLanguage, "subtitle_services_keep_direction_" + definition.id + "_" + source.rawValue)
                        let original = try await services.recognizer.recognize(samples: samples)
                        try require(!original.isEmpty, "real_asr_" + definition.id + "_" + source.rawValue)
                        let translated = try await services.translator.translate(original, from: source.name, to: live.targetLanguage.name)
                        try require(!translated.isEmpty && translated != original, "real_translation_after_asr_" + definition.id + "_" + source.rawValue)
                        results.append(["model": definition.id, "source": source.rawValue, "target": live.targetLanguage.rawValue, "original": original, "translated": translated])
                    }
                }
                if let fixtureIndex = CommandLine.arguments.firstIndex(of: "--model-fixture"), CommandLine.arguments.count > fixtureIndex + 1 {
                    let movie = output.appendingPathComponent("english-test.mp4")
                    let encoder = Process()
                    encoder.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LiveTools/ffmpeg")
                    encoder.arguments = ["-nostdin", "-y", "-loglevel", "error", "-i", CommandLine.arguments[fixtureIndex + 1],
                        "-i", fixtureRoot.appendingPathComponent("en.wav").path, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-shortest", movie.path]
                    try encoder.run(); encoder.waitUntilExit()
                    try require(encoder.terminationStatus == 0, "english_video_fixture_ready_without_playback")
                    let clip = ClipStore(root: output.appendingPathComponent("english-clip"))
                    let id = try await clip.importVideo(movie)
                    live.setSourceLanguage(.english); live.setTargetLanguage(.simplifiedChinese)
                    live.selectedASRProfileID = live.profiles.first { $0.localModelID == "whisper-base" }!.id
                    clip.start(ClipJob(projectID: id, kind: .transcribe, range: ClipRange(title: "英语", start: 0, end: min(60, clip.selected!.media.duration))), model: live)
                    for _ in 0..<1200 where clip.isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
                    let project = clip.projects[0]
                    try require(!clip.isBusy && clip.jobs[0].state == .completed && !project.captions.isEmpty
                        && project.captions.allSatisfy { $0.sourceLanguage == .english && $0.targetLanguage == .simplifiedChinese && !$0.translated.isEmpty },
                        "english_video_to_local_chinese_captions_keeps_metadata")
                    try require(clip.jobs[0].sourceLanguage == .english && clip.jobs[0].targetLanguage == .simplifiedChinese,
                        "clip_job_persists_language_for_retry")
                }
                let hy = LocalModelDefinition.catalog.first { $0.id == "hy-mt" }!
                let imported = library.folder(for: hy).appendingPathComponent(hy.files[0].name)
                live.profiles.removeAll { $0.localModelID == "hy-mt" }
                let importedID = try await live.useTranslationModel(at: imported)
                try require(try await live.useTranslationModel(at: imported) == importedID, "gguf_import_reuses_same_reference")
                let translator = try await live.makeProofreadTranslator(configured: true)
                let result = try await translator.translate("We won't go to school tomorrow.", from: "英语", to: "简体中文")
                try require(!result.isEmpty && result.contains("不"), "imported_hy_mt_generates_chinese_with_model_template")
                results.append(["model": "hy-mt-imported", "source": "en", "target": "zh-Hans", "original": "We won't go to school tomorrow.", "translated": result])
                let before = live.localModels.directory
                live.localModels.setDirectory(custom)
                try require(live.localTranslationPath(live.profiles.first { $0.id == importedID }!) == imported.path && before != custom,
                            "changing_download_folder_preserves_imported_model_reference")
            }
            try write(["passed": true, "checks": checks, "results": results], output)
        } catch {
            print("FAIL: " + error.localizedDescription); fflush(stdout)
            try? write(["passed": false, "checks": checks, "results": results, "error": error.localizedDescription], output)
        }
        for window in windows { window.close() }
        NSApp.terminate(nil); return true
    }
    private static func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        let view = window.contentView!; view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LiveMonitorError.invalidResponse }
        view.cacheDisplay(in: view.bounds, to: bitmap); return bitmap
    }
    private static func write(_ data: [String: Any], _ output: URL) throws {
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("model-library-checks.json"))
    }
}

private actor PromptCapture: TextTranslating {
    var guided = false
    func translate(_ text: String, from source: String, to target: String) async throws -> String { text }
    func translate(_ text: String, from source: String, to target: String, context: SubtitleTranslationContext) async throws -> String {
        let prompt = context.prompt(for: text, source: source, target: target)
        guided = prompt.contains("保留否定，不要补写。") && prompt.contains("英语") && prompt.contains("简体中文")
        return "我们不去。"
    }
}
