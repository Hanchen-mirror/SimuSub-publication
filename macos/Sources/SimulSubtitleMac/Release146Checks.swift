import AppKit
import SwiftUI

/// Language-route migration and real-model regression using isolated settings.
@MainActor
enum Release146Checks {
    private static var started = false
    static func runIfRequested(appearance: HomeAppearance, subtitles: SubtitlePanelController) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--release-146-check"), args.count > i + 3 else { return false }
        guard !started else { return true }; started = true
        let output = URL(fileURLWithPath: args[i + 1]), root = URL(fileURLWithPath: args[i + 2])
        let suite = "SimuSub.SplitLanguage146." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checks: [String] = [], rows: [[String: Any]] = []
        var active: AppModel?
        func require(_ ok: Bool, _ name: String) throws {
            guard ok else { throw ClipError.message(name) }; checks.append(name)
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defaults.set("zh-Hant", forKey: "interface.language.v141")
            let model = AppModel(defaults: defaults, modelStore: LocalModelStore(root: root), modelDownloadsAllowed: false)
            active = model
            try require(model.targetLanguage == .traditionalChinese, "fresh_target_follows_interface")
            try require(model.selectedAppBundleID == AudioCaptureEngine.systemAudioID, "default_system_audio")
            let indexID = model.selectedTranslationProfileID
            try require(model.profiles.first { $0.id == indexID }?.model == "Index-Translate-2B", "baseline_translation_not_unvalidated_candidate")
            for (language, expected) in [(SubtitleLanguage.japanese, Optional<String>.none), (.english, "whisper-base"), (.simplifiedChinese, "sensevoice")] {
                model.setSourceLanguage(language)
                let profile = model.profiles.first { $0.id == model.selectedASRProfileID }
                try require(profile != nil && profile?.localModelID == expected, "selected_asr_" + language.rawValue)
                try require(model.selectedTranslationProfileID == indexID, "language_change_keeps_translation_" + language.rawValue)
            }
            model.setSourceLanguage(.english); model.setTargetLanguage(.traditionalChinese)
            let restored = AppModel(defaults: defaults, modelStore: model.modelStore, modelDownloadsAllowed: false)
            try require(restored.sourceLanguage == .english && restored.targetLanguage == .traditionalChinese, "language_choices_persist")
            restored.swapLanguages()
            try require(restored.sourceLanguage == .traditionalChinese && restored.targetLanguage == .english, "swap_updates_direction")
            let gemmaID = model.profiles.first { $0.localModelID == "gemma4-e4b" && $0.purpose == .translation }!.id
            defaults.set(gemmaID.uuidString, forKey: "selectedTranslationProfileID.v2")
            defaults.set(true, forKey: "subtitle.gemmaUnified.v145")
            let migrated = AppModel(defaults: defaults, modelStore: model.modelStore, modelDownloadsAllowed: false)
            try require(migrated.selectedTranslationProfileID == indexID, "unified_candidate_migrates_to_baseline_once")
            migrated.selectedTranslationProfileID = gemmaID
            migrated.setSourceLanguage(.japanese)
            let chosen = AppModel(defaults: defaults, modelStore: model.modelStore, modelDownloadsAllowed: false)
            try require(chosen.selectedTranslationProfileID == gemmaID, "later_explicit_translation_choice_is_preserved")
            model.setSourceLanguage(.japanese); model.setTargetLanguage(.simplifiedChinese)
            try require(try model.subtitleModelDownloadBytes() == 0, "reuse_installed_models_no_download")
            let corpus = try JSONDecoder().decode(MultilingualBenchmark.Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 3])))
            var clock = 0.0
            for item in corpus.audio.prefix(6) {
                let source = SubtitleLanguage.resolve(item.source)!
                model.setSourceLanguage(source); model.setTargetLanguage(source.isChinese ? .english : .simplifiedChinese)
                _ = try await model.makeSubtitleServices()
                try require(!model.usesSharedGemmaForLiveSubtitles, "split_engine_" + item.id)
                let pcm = try AudioFileReader.read(URL(fileURLWithPath: item.path))
                let begin = ProcessInfo.processInfo.systemUptime
                await model.process(pcm, start: clock)
                clock += Double(pcm.count) / 16000 + 1
                guard let caption = model.captions.last else { throw ClipError.message("missing_" + item.id) }
                try require(!caption.isDraft && SubtitleDocument.completedTranslation(caption) != nil, "stable_" + item.id)
                try require(caption.sourceLanguage == source, "explicit_source_" + item.id)
                rows.append(["id": item.id, "source": caption.original, "translation": caption.translated, "seconds": ProcessInfo.processInfo.systemUptime - begin])
            }
            model.subtitleDisplayMode = .original; model.selectedTranslationProfileID = nil
            _ = try await model.makeSubtitleServices()
            let pcm = try AudioFileReader.read(URL(fileURLWithPath: corpus.audio[5].path))
            await model.process(pcm, start: clock)
            try require(model.captions.last?.isOriginalOnly == true, "original_mode_without_translation_profile")
            model.selectedTranslationProfileID = indexID; model.toggleOriginalOnly()
            try require(model.subtitleDisplayMode == .bilingual, "original_icon_restores_bilingual_mode")
            let empty = AppModel(defaults: UserDefaults(suiteName: suite + ".empty")!, modelStore: LocalModelStore(root: output.appendingPathComponent("empty-models")), modelDownloadsAllowed: false)
            defer { UserDefaults.standard.removePersistentDomain(forName: suite + ".empty") }
            let fullBytes = try empty.subtitleModelDownloadBytes()
            empty.subtitleDisplayMode = .original
            try require(try empty.subtitleModelDownloadBytes() < fullBytes, "original_mode_does_not_require_translation_download")
            try require(!FileManager.default.fileExists(atPath: empty.modelStore.root.path), "missing_model_check_does_not_download")
            model.setSourceLanguage(.japanese); model.setTargetLanguage(.simplifiedChinese)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SubtitleConfiguration(onServices: {}).environmentObject(model).environmentObject(appearance).environmentObject(subtitles).appTheme().environmentObject(appearance))
            window.orderFront(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("split-language.png"))
            }
            window.close()
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "captions": rows], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "captions": rows, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        }
        await active?.shutdownLocalEngines()
        NSApp.terminate(nil); return true
    }
}
