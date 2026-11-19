import AppKit
import SwiftUI

/// Language-route migration and real-model regression using isolated settings.
@MainActor
enum Release148Checks {
    private static var started = false
    static func runIfRequested(appearance: HomeAppearance, subtitles: SubtitlePanelController, monitor: LiveMonitorStore, clips: ClipStore) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--release-148-check"), args.count > i + 2 else { return false }
        let routesOnly = args.contains("--routes-only")
        guard routesOnly || args.count > i + 3 else { return false }
        guard !started else { return true }; started = true
        let output = URL(fileURLWithPath: args[i + 1]), root = URL(fileURLWithPath: args[i + 2])
        let suite = "SimuSub.Design148." + UUID().uuidString
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
            let gemma = chosen.profiles.first { $0.id == gemmaID }!
            try require(chosen.selectedTranslationProfileID == (chosen.localProfileInstalled(gemma) ? gemmaID : indexID), "explicit_available_translation_persists_unavailable_falls_back")
            for language in AppModel.recognitionLanguages {
                let automaticID = model.recognitionProfile(for: language)?.id
                let choices = model.recognitionChoices(for: language)
                try require(choices.contains { $0.id == automaticID }, "automatic_official_asr_available_" + language.rawValue)
                try require(choices.allSatisfy { $0.kind == .local && model.localProfileInstalled($0) && model.supportsRecognition($0, language: language) }, "available_supported_asr_choices_" + language.rawValue)
                if let alternative = choices.first(where: { $0.id != automaticID }) {
                    model.chooseRecognition(alternative.id, for: language)
                    try require(model.recognitionProfile(for: language)?.id == alternative.id, "explicit_multilingual_asr_route_" + language.rawValue)
                    model.chooseRecognition(nil, for: language)
                    try require(model.recognitionProfile(for: language)?.id == automaticID, "automatic_asr_route_restored_" + language.rawValue)
                }
            }
            try require(model.translationChoices.contains { $0.id == indexID } && model.translationChoices.allSatisfy { $0.kind == .local && model.localProfileInstalled($0) }, "installed_translation_choices_visible")

            // A tiny routing-only fixture is never loaded by an inference engine.
            // This exercises reference import without copying the shared model.
            let fixture = output.appendingPathComponent("routing-only.gguf")
            try Data("GGUF-routing-only-fixture".utf8).write(to: fixture)
            defer { try? FileManager.default.removeItem(at: fixture) }
            let importedID = try await model.useTranslationModel(at: fixture)
            try require(model.translationChoices.contains { $0.id == importedID } && model.selectedTranslationProfileID == importedID, "imported_translation_visible_and_selected")
            let repeatedID = try await model.useTranslationModel(at: fixture)
            try require(importedID == repeatedID, "import_reference_deduplicates")
            let importRestored = AppModel(defaults: defaults, modelStore: model.modelStore, modelDownloadsAllowed: false)
            try require(importRestored.selectedTranslationProfileID == importedID, "import_selection_survives_relaunch")
            try require(model.removal(for: model.profiles.first { $0.id == indexID }!) == nil, "shared_index_has_no_disk_removal_action")
            model.removeLocalModel(model.profiles.first { $0.id == importedID }!)
            try require(model.selectedTranslationProfileID == indexID && !model.translationChoices.contains { $0.id == importedID }, "remove_import_restores_local_translation_route")
            try require(FileManager.default.fileExists(atPath: fixture.path), "remove_import_preserves_original_file")

            // Exercise real macOS Trash using tiny fixtures, outside the shared model store.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let managed = ManagedModelFiles(folder: scratch, filenames: ["encoder.onnx", "decoder.onnx", "tokens.txt"])
            for name in managed.filenames + managed.filenames.map({ $0 + ".sha256" }) + ["user-notes.txt"] {
                try Data(name.utf8).write(to: scratch.appendingPathComponent(name))
            }
            let trash = try managed.moveToTrash()
            defer { for url in trash { try? FileManager.default.removeItem(at: url) } }
            try require(trash.count == 6 && !managed.hasFiles && trash.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                        "managed_multipart_model_and_markers_are_recoverable_in_trash")
            try require(try FileManager.default.contentsOfDirectory(atPath: scratch.path) == ["user-notes.txt"],
                        "uninstall_preserves_unrelated_files")
            try Data("fixture".utf8).write(to: scratch.appendingPathComponent("encoder.onnx"))
            try FileManager.default.createDirectory(at: scratch.appendingPathComponent("tokens.txt"), withIntermediateDirectories: false)
            var rejectedDirectory = false
            do { try managed.moveToTrash() } catch { rejectedDirectory = true }
            try require(rejectedDirectory && FileManager.default.fileExists(atPath: scratch.appendingPathComponent("encoder.onnx").path),
                        "uninstall_refuses_unexpected_directory_before_moving_files")

            // Mark a unique test profile configured in memory only; no keychain or
            // network operation is needed to validate selection and deletion.
            let remoteID = model.addProfile(.speechRecognition)
            model.savedCredentialIDs.insert(remoteID)
            model.setSourceLanguage(.japanese)
            let localASR = model.recognitionProfile(for: .japanese)?.id
            model.chooseRecognition(remoteID, for: .japanese)
            try require(model.selectedASRProfileID == remoteID, "explicit_remote_asr_route")
            model.removeProfile(remoteID)
            model.savedCredentialIDs.remove(remoteID)
            try require(model.selectedASRProfileID == localASR && !model.hasRecognitionOverride(for: .japanese), "delete_remote_asr_restores_automatic_route")
            let remoteMT = model.addProfile(.translation)
            model.savedCredentialIDs.insert(remoteMT)
            model.selectedTranslationProfileID = remoteMT
            model.removeProfile(remoteMT)
            model.savedCredentialIDs.remove(remoteMT)
            try require(model.selectedTranslationProfileID == indexID, "delete_remote_translation_restores_local_route")
            let sourcePrefs = HomeAppearance(defaults: defaults)
            let chrome = "com.google.Chrome", player = "test.FrankPlayer"
            let running = [chrome, "test.A", "test.B", "test.C", "test.D", player, chrome]
            sourcePrefs.sourceOrder = [chrome, "test.A", "test.B", "test.C", "test.D"]
            func visible(_ prefs: HomeAppearance, _ apps: [String], hidden: Set<String> = [], selected: String? = nil) -> [String] {
                SubtitleSourceDock.visibleSources(running: apps, order: prefs.sourceOrder, pinned: prefs.pinnedSubtitleSources,
                                                  hidden: hidden, selected: selected)
            }
            let overflow = visible(sourcePrefs, running, selected: player)
            try require(overflow == [chrome, "test.A", "test.B", "test.C", player], "sixth_selected_source_stays_visible")
            let migratedPrefs = HomeAppearance(defaults: defaults)
            try require(migratedPrefs.pinnedSubtitleSources == sourcePrefs.sourceOrder, "legacy_custom_source_order_retained")
            sourcePrefs.pinSubtitleSource(player)
            sourcePrefs.pinSubtitleSource(player)
            let reopened = HomeAppearance(defaults: defaults)
            try require(reopened.pinnedSubtitleSources == [player] && visible(reopened, running, hidden: [chrome]) == [player, "test.A", "test.B", "test.C", "test.D"], "added_source_persists_and_hidden_source_stays_hidden")
            try require(visible(reopened, [player, chrome, chrome], selected: chrome) == [player, chrome, AudioCaptureEngine.systemAudioID], "relaunch_preserves_order_and_deduplicates_processes")
            for id in running.prefix(6) { sourcePrefs.pinSubtitleSource(id) }
            let six = Array(running.prefix(6).reversed())
            let sixRestored = HomeAppearance(defaults: defaults)
            try require(visible(sixRestored, running) == six, "six_explicit_pins_remain_visible_after_relaunch")
            try require(visible(sixRestored, running, selected: AudioCaptureEngine.systemAudioID) == six + [AudioCaptureEngine.systemAudioID], "external_selection_never_evicts_a_pin")
            sourcePrefs.unpinSubtitleSource(player)
            try require(!HomeAppearance(defaults: defaults).pinnedSubtitleSources.contains(player), "removed_source_is_unpinned")
            if routesOnly {
                try JSONSerialization.data(withJSONObject: ["passed": true, "scope": "routes-only", "checks": checks], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
                await model.shutdownLocalEngines()
                NSApp.terminate(nil)
                return true
            }
            let prefs = HomeAppearance(defaults: defaults)
            prefs.interfaceFontSize = 17; prefs.sourceOrder = ["com.colliderli.iina", AudioCaptureEngine.systemAudioID]
            let restoredPrefs = HomeAppearance(defaults: defaults)
            try require(restoredPrefs.interfaceFontSize == 17 && restoredPrefs.sourceOrder == prefs.sourceOrder, "font_and_source_order_persist")
            let oldSettings = Data(#"{"intervalSeconds":30,"maximumRecordings":2,"container":"mkv","outputFolder":"/tmp"}"#.utf8)
            var settings = try JSONDecoder().decode(LiveMonitorSettings.self, from: oldSettings)
            try require(settings.quality == .original && settings.intervalSeconds == 30, "legacy_recording_settings_preserved")
            settings.quality = .p720_60
            try require(try JSONDecoder().decode(LiveMonitorSettings.self, from: JSONEncoder().encode(settings)).quality == .p720_60, "recording_quality_persists")
            let manifest = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=2560x1440,FRAME-RATE=60
            1440.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=60
            1080-60.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,FRAME-RATE=30
            1080-30.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,FRAME-RATE=60
            720-60.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480,FRAME-RATE=30
            480.m3u8
            """
            let base = URL(string: "https://example.com/live/master.m3u8")!
            for (quality, expected) in [(RecordingQuality.original,"1440.m3u8"),(.p1080,"1080-30.m3u8"),(.p1080_60,"1080-60.m3u8"),(.p720_60,"720-60.m3u8"),(.p720,"480.m3u8"),(.p360,"480.m3u8")] {
                try require(try LivePlatformService.bestHLSVariant(manifest, base: base, quality: quality).lastPathComponent == expected, "actual_hls_quality_" + quality.rawValue)
            }
            try require(RecordingQuality.p1080.extractorFormat.contains("[height<=1080][fps<=?30]"), "extractor_receives_resolution_and_fps")
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
            appearance.theme = .purple; appearance.mode = .dark; appearance.interfaceFontSize = 13
            func render<V: View>(_ root: V, name: String, width: CGFloat = 1160, height: CGFloat = 780) async throws {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: ZoomedWorkspace { root }
                    .environmentObject(model).environmentObject(model.permissions).environmentObject(appearance)
                    .environmentObject(subtitles).environmentObject(monitor).environmentObject(clips).appTheme().environmentObject(appearance))
                window.orderFront(nil)
                try await Task.sleep(nanoseconds: 300_000_000)
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
                    try require(abs(view.bounds.width - width) < 1, "native_layout_" + name)
                } else { throw ClipError.message("snapshot_failed_" + name) }
                window.close()
            }
            // Capture hidden and visible navigation at each breakpoint for visual regression.
            for width: CGFloat in [1200, 900, 360] {
                let mode = WorkspaceNavigation(width: width)
                for expanded in [false, true] {
                    let view = ZStack(alignment: .topLeading) {
                        ThemeColor.background
                        if expanded {
                            WorkspaceSidebar(selected: .subtitle, mode: mode) { _ in }
                                .frame(width: mode.width, height: mode == .top ? nil : 480)
                        }
                    }
                    let renderer = ImageRenderer(content: view.frame(width: width, height: 480)
                        .appTheme().environmentObject(appearance))
                    renderer.scale = 2
                    let name = "sidebar-" + mode.rawValue + (expanded ? "-expanded" : "-collapsed")
                    guard let bitmap = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
                    else { throw ClipError.message("snapshot_failed_" + name) }
                    try png.write(to: output.appendingPathComponent(name + ".png"))
                    try require(bitmap.width == Int(width * 2), "native_layout_" + name)
                }
            }
            try await render(SubtitleConfiguration(onServices: {}), name: "subtitles")
            try await render(AdvancedServiceSettings(), name: "models")
            try await render(RecordingWorkspace(onSettings: {}, onClips: { _ in }), name: "recording")
            for category in ["外观", "录制", "平台", "权限"] {
                try await render(SettingsWindow(initialCategory: category), name: "settings-" + category)
            }
            try await render(ClipWorkspace(onBack: {}), name: "clips-import")
            if let fixtureIndex = args.firstIndex(of: "--design-fixture"), args.count > fixtureIndex + 1 {
                _ = try await clips.importVideo(URL(fileURLWithPath: args[fixtureIndex + 1]))
                try await render(ClipWorkspace(onBack: {}), name: "clips-editor")
                clips.selectedID = nil
            }
            appearance.interfaceFontSize = 20
            try await render(SubtitleConfiguration(onServices: {}), name: "subtitles-large-font", width: 800, height: 680)
            try await render(SettingsWindow(initialCategory: "外观"), name: "settings-narrow", width: 640, height: 520)
            appearance.interfaceFontSize = 13
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "captions": rows], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject: ["passed": false, "checks": checks, "captions": rows, "error": error.localizedDescription], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
        }
        await active?.shutdownLocalEngines()
        NSApp.terminate(nil); return true
    }
}
