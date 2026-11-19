import AppKit
import SwiftUI

/// Exercises the real AppModel.process entry, isolated preferences, shared read-only models.
@MainActor
enum Release145Checks {
    private static var started = false
    static func runIfRequested(appearance: HomeAppearance, subtitles: SubtitlePanelController) async -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--release-145-check"), args.count > i+3 else { return false }
        guard !started else { return true }; started=true
        let output=URL(fileURLWithPath:args[i+1]), root=URL(fileURLWithPath:args[i+2])
        let corpusURL=URL(fileURLWithPath:args[i+3])
        let suite="SimuSub.Release145."+UUID().uuidString
        // Use the actual suite name for deterministic cleanup below.
        let owned=UserDefaults(suiteName:suite)!
        defer { owned.removePersistentDomain(forName:suite) }
        var checks:[String]=[], rows:[[String:Any]]=[]
        func require(_ ok:Bool,_ name:String) throws { guard ok else { throw ClipError.message(name) };checks.append(name) }
        var exercisedModel: AppModel?
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            owned.set("zh-Hant",forKey:"interface.language.v141")
            let model=AppModel(defaults:owned,modelStore:LocalModelStore(root:root),modelDownloadsAllowed:false)
            exercisedModel = model
            try require(model.selectedAppBundleID == AudioCaptureEngine.systemAudioID,"default_system_audio")
            try require(model.targetLanguage == .traditionalChinese,"target_follows_interface")
            try require(model.profiles.first { $0.id == model.selectedASRProfileID }?.localModelID == "gemma4-e4b","automatic_multilingual_asr")
            try require(model.profiles.first { $0.id == model.selectedTranslationProfileID }?.localModelID == "gemma4-e4b","automatic_translation_upgrade")
            try require(try model.subtitleModelDownloadBytes() == 0,"shared_models_no_download")
            _ = try await model.makeSubtitleServices()
            try require(model.usesSharedGemmaForLiveSubtitles, "one_gemma_instance_for_asr_and_mt_no_index")
            let corpus=try JSONDecoder().decode(MultilingualBenchmark.Corpus.self,from:Data(contentsOf:corpusURL))
            await model.process(Array(try AudioFileReader.read(URL(fileURLWithPath:corpus.audio[0].path)).prefix(32_000)),start:0,isFinal:false)
            try require(model.captions.isEmpty,"gemma_short_draft_does_not_block_translation")
            var clock=0.0
            for item in corpus.audio {
                let pcm=try AudioFileReader.read(URL(fileURLWithPath:item.path))
                let begin=ProcessInfo.processInfo.systemUptime
                await model.process(pcm,start:clock)
                clock += Double(pcm.count)/16000+1
                guard let caption=model.captions.last else { throw ClipError.message("missing_caption_"+item.id) }
                try require(!caption.isDraft && SubtitleDocument.completedTranslation(caption) != nil,"stable_"+item.id)
                rows.append(["id":item.id,"source":caption.original,"translation":caption.translated,"detected":caption.sourceLanguage.rawValue,"target":caption.targetLanguage.rawValue,"seconds":ProcessInfo.processInfo.systemUptime-begin])
            }
            let probe=FailIfCalledTranslator()
            let route=LanguageAwareTranslator(base:probe)
            try require(try await route.translate("I didn't delete it.",from:"en",to:"en") == "I didn't delete it.","same_language_bypass")
            try require(try await route.translate("后台文件没有删除。",from:"zh",to:"zh-Hant") == "後台文件沒有刪除。","chinese_script_conversion")
            try require(LiveLanguageRouting.translationSource(text:"美咲さん、don't delete the backup",detected:.japanese) == "多语言","mixed_language_not_bypassed")
            try require(AutomaticSpeechRecognizer.droppedInteriorWords("Please ask Misaki to keep all twelve files", "Please ask to keep all twelve files"), "interior_name_deletion_redecoded")
            try require(!AutomaticSpeechRecognizer.droppedInteriorWords("Please ask Misakisan to keep all twelve files", "Please ask Misaki san to keep all twelve files"), "name_spelling_change_not_treated_as_deletion")
            try require(AutomaticSpeechRecognizer.shortenedAnchoredSpeech("田中さんキープオールトゥエルブファイルと言いました", "と言いました"), "anchored_japanese_prefix_deletion_redecoded")
            let raw = "今天不翻译，Alex 也不改名。"
            let onlyOriginal = AppModel(defaults: owned, modelStore: LocalModelStore(root: root),
                recognizer: LiteralRecognizer(text: raw), translator: FailIfCalledTranslator(), modelDownloadsAllowed: false)
            onlyOriginal.subtitleDisplayMode = .original
            await onlyOriginal.process([Float](repeating: 0.1, count: 16000), start: 0)
            try require(onlyOriginal.captions.last?.original == raw && onlyOriginal.captions.last?.isOriginalOnly == true, "original_only_never_calls_translation_or_rewrites")
            try require(SubtitleDocument.render(onlyOriginal.captions, format: .txt, mode: .original) == raw+"\n", "original_only_export_has_one_unmodified_copy")
            onlyOriginal.toggleOriginalOnly()
            try require(onlyOriginal.subtitleDisplayMode == .bilingual, "original_button_restores_previous_display_mode")
            let savedTranslation = model.selectedTranslationProfileID
            model.subtitleDisplayMode = .original
            model.selectedTranslationProfileID = nil
            _ = try await model.makeSubtitleServices()
            try require(true, "original_only_prepares_without_translation_profile")
            let originalDraftID = UUID()
            let originalPCM = try AudioFileReader.read(URL(fileURLWithPath:corpus.audio[0].path))
            await model.process(originalPCM,start:clock,id:originalDraftID,isFinal:false)
            try require(model.captions.last?.id == originalDraftID && model.captions.last?.isDraft == true,"original_only_keeps_native_draft_preview")
            await model.process(originalPCM,start:clock,id:originalDraftID,revision:2,isFinal:true)
            clock += 10
            try require(model.captions.last?.isOriginalOnly == true, "native_original_only_finalizes_without_translation")
            model.selectedTranslationProfileID = savedTranslation
            model.toggleOriginalOnly()
            await model.process(try AudioFileReader.read(URL(fileURLWithPath: corpus.audio[1].path)), start: clock)
            try require(model.captions.last?.isOriginalOnly == false && SubtitleDocument.completedTranslation(model.captions.last!) != nil, "translation_resumes_after_original_only_start")
            let mixedHistory = SubtitleTranslationContext(previous: [
                .init(original: "请提醒 Emma 不要重启", translated: "", sourceLanguage: "多语言"),
                .init(original: "田中さん、Keep all files", translated: "", sourceLanguage: "多语言")])
            try require(mixedHistory.contiguousContext(for: "en").previous.isEmpty, "language_switch_does_not_replay_mixed_history")
            let sameHistory = SubtitleTranslationContext(previous: [.init(original: "She has the key.", translated: "", sourceLanguage: "en")])
            try require(sameHistory.contiguousContext(for: "英语").previous.count == 1, "same_language_context_preserved")
            // Language changes affect new captions; already finalized history retains its target.
            AppLocalization.shared.language = .english
            try require(model.targetLanguage == .english,"interface_change_updates_target")
            let emptyRoot=output.appendingPathComponent("empty-models")
            let missing=AppModel(defaults:owned,modelStore:LocalModelStore(root:emptyRoot),modelDownloadsAllowed:false)
            try require(try missing.subtitleModelDownloadBytes() > 0,"missing_models_offer_preparation")
            let bilingualBytes = try missing.subtitleModelDownloadBytes()
            missing.subtitleDisplayMode = .original
            try require(try missing.subtitleModelDownloadBytes() == bilingualBytes, "original_only_reuses_same_gemma_base_no_extra_translation_download")
            try require(!FileManager.default.fileExists(atPath:emptyRoot.path),"missing_model_check_has_no_downloads")
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            let view=SubtitleConfiguration(onServices:{}).environmentObject(model).environmentObject(appearance).environmentObject(subtitles).appTheme().environmentObject(appearance)
            window.contentView=NSHostingView(rootView:view);window.orderFront(nil)
            try await Task.sleep(nanoseconds:300_000_000)
            if let view=window.contentView,let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("live-subtitles.png"))
            }
            window.close()
            try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"captions":rows],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        } catch {
            try? JSONSerialization.data(withJSONObject:["passed":false,"checks":checks,"captions":rows,"error":error.localizedDescription],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        }
        await exercisedModel?.shutdownLocalEngines()
        NSApp.terminate(nil);return true
    }
    private struct FailIfCalledTranslator: TextTranslating {
        func translate(_ text:String,from:String,to:String) async throws -> String { throw ClipError.message("same_language_called_model") }
    }
    private struct LiteralRecognizer: SpeechRecognizing {
        let text: String
        func recognize(samples: [Float]) async throws -> String { text }
    }
}
