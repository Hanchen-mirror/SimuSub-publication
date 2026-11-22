import AppKit
import SwiftUI
import AVFoundation

private actor ReviewFixture: TextTranslating {
    func translate(_ text: String, from: String, to: String) async throws -> String { "核对后的中文译文" }
}
private actor UnusedRecognizer: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { throw ClipError.message("不应重复调用识别器") }
}
@MainActor
enum ClipV120Checks {
    static func run(fixture: URL, directory: URL, model: AppModel, monitor: LiveMonitorStore) async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ name: String) throws { guard value else { throw ClipError.message("CHECK FAILED: " + name) }; checks.append(name); print("CHECK: " + name); fflush(stdout) }
        func wait(_ store: ClipStore) async throws {
            for _ in 0..<2400 { if !store.isBusy { return }; try await Task.sleep(nanoseconds: 100_000_000) }
            store.cancel(); throw ClipError.message("v120 job timeout")
        }
        let root = directory.appendingPathComponent("v120")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ClipStore(root: root.appendingPathComponent("store")), id = try await store.importVideo(fixture)
        let original = Caption(start: 1, end: 3, original: "今日はここから始めましょう。", translated: "今天我们从这里开始。")
        let a = ClipRange(title: "选段 1", start: 1, end: 5)
        var b = a; b.id = UUID(); b.title = "选段 2"
        store.update(id) { $0.captions = [original]; $0.ranges = [a, b]; $0.analysisCoverage = [1...3, 3...5] }
        try require(store.projects[0].unrecognizedRanges(in: a).isEmpty, "v120_adjacent_analysis_coverage_reuses_source_recognition")
        let partial = store.projects[0].unrecognizedRanges(in: ClipRange(title: "extended", start: 0, end: 7))
        try require(partial.map(\.start) == [0, 5] && partial.map(\.end) == [1, 7], "v120_only_unrecognized_portions_are_processed")
        var edited = original; edited.translated = "选段一的独立修改"
        try require(store.saveSegmentCaption(id, rangeID: a.id, cue: edited), "v120_caption_edit_saved_to_current_segment")
        store.setStyle(id, rangeID: a.id, style: .pink)
        let first = store.projects[0].ranges[0], second = store.projects[0].ranges[1]
        try require(store.projects[0].captions == [original] && store.projects[0].captions(for: first)[0].translated == edited.translated && store.projects[0].captions(for: second)[0].translated == original.translated, "v120_segment_subtitle_edits_do_not_mutate_source_or_other_segments")
        try require(first.style.chinese.color == "#F2CDD8" && second.style.chinese.color == "#FFFFFF", "v120_style_scoped_to_segment")
        store.saveRange(id, range: a)
        try require(store.projects[0].ranges[0].style == .pink && store.projects[0].ranges[0].captionEdits == [edited], "v120_save_time_range_preserves_independent_caption_and_style_metadata")
        let reloaded = ClipStore(root: store.root)
        try require(reloaded.projects[0].ranges == store.projects[0].ranges, "v120_segment_edits_styles_and_imports_survive_restart")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
        ["subtitleStyle", "captionEdits", "importedCaptions", "deletedCaptionIDs", "proofreadCandidates"].forEach { legacy.removeValue(forKey: $0) }
        let migrated = try JSONDecoder().decode(ClipRange.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(migrated.style == .classic && migrated.start == a.start, "v120_legacy_range_migration_keeps_timing_and_default_style")
        let castStore = ClipStore(root: root.appendingPathComponent("cast"))
        let castID = try await castStore.importVideo(fixture)
        let roleA = ClipCaptionRole(name: "甲", chinese: .init(), japanese: .init())
        let roleB = ClipCaptionRole(name: "乙", chinese: .init(color: "#FFC275"), japanese: .init())
        let scene = ClipRange(title: "对话", start: 0, end: 8)
        var dialogue = (0..<7).map { n in Caption(start: Double(n), end: Double(n+1), original: "Hello", translated: "你好") }
        dialogue[1].assignClipRole(roleA.id)
        dialogue[3].assignClipRole(roleB.id)
        dialogue[5].assignClipRole(nil)
        castStore.update(castID) {
            $0.captionRoles = [roleA, roleB]
            $0.ranges = [scene]
            $0.captions = dialogue
        }
        let restoredCast = ClipStore(root: castStore.root)
        let savedProject = restoredCast.projects[0]
        try require(savedProject.captionRoles == [roleA, roleB] && savedProject.styledCaptions(for: scene).map(\.clipRoleID) ==
                    [nil, roleA.id, roleA.id, roleB.id, roleB.id, nil, nil], "speaker_changes_and_explicit_default_survive_reopen")
        var trimmed = scene
        trimmed.start = 2.1
        try require(savedProject.styledCaptions(for: trimmed).first?.clipRoleID == roleA.id, "trim_keeps_speaker_from_earlier_cue")
        restoredCast.deleteSegmentCaption(castID, rangeID: scene.id, cueID: dialogue[1].id)
        let afterDelete = restoredCast.projects[0]
        let continued = afterDelete.styledCaptions(for: afterDelete.ranges[0])
        try require(continued.first { $0.id == dialogue[2].id }?.clipRoleID == roleA.id, "removing_first_line_preserves_next_lines_speaker")
        var invalid = ClipSubtitleStyle.pink; invalid.chinese.size = .nan
        try require(!invalid.valid, "v120_invalid_or_nonfinite_style_rejected")
        let srt = "1\n00:00:00,000 --> 00:00:02,000\n你好\nこんにちは\n"
        let imported = try ClipSubtitleImport.parse(srt, extension: "srt", layout: .chineseFirst, offset: 1, duration: 10)
        try require(imported.count == 1 && imported[0].start == 1 && imported[0].end == 3 && imported[0].translated == "你好" && imported[0].original == "こんにちは", "v120_srt_import_language_order_and_relative_clock")
        let vtt = try ClipSubtitleImport.parse("WEBVTT\n\n00:01.000 --> 00:03.000 align:center\n<b>日语</b>\n中文\n", extension: "vtt", layout: .japaneseFirst, offset: 0, duration: 10)
        try require(vtt[0].original == "日语" && vtt[0].translated == "中文", "v120_vtt_import_settings_and_text_markup")
        let ass = try ClipSubtitleImport.parse("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\b1}こんにちは\\N你好,朋友", extension: "ass", layout: .japaneseFirst, offset: 0, duration: 10)
        try require(ass[0].translated == "你好,朋友" && ass[0].original == "こんにちは", "v120_ass_import_ignores_style_commands_preserves_commas")
        let separateTracks = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.50,0:00:04.00,ZH,,0,0,0,,密码是 2458。
        Dialogue: 0,0:00:04.00,0:00:05.00,JA,,0,0,0,,行こう！
        Dialogue: 0,0:00:02.50,0:00:04.00,JA,,0,0,0,,2458！
        Dialogue: 0,0:00:04.00,0:00:05.00,ZH,,0,0,0,,走吧！
        """
        let paired = try ClipSubtitleImport.parse(separateTracks, extension: "ass", layout: .automatic, offset: -1, duration: 10)
        try require(paired.count == 2 && ClipSubtitleStyle.classic.complete(paired)
                    && paired[0].start == 1.5 && paired[0].end == 3
                    && paired[0].original == "2458！" && paired[0].translated == "密码是 2458。"
                    && paired[1].original == "行こう！" && paired[1].translated == "走吧！",
                    "ass_separate_language_tracks_merge_for_bilingual_burn")
        let library = ClipStyleLibrary(root: root)
        let secondEditor = ClipStyleLibrary(root: root)
        try library.save(name: "粉色中文", style: .pink)
        try require(ClipStyleLibrary(root: root).presets[0].style == .pink, "v120_custom_style_presets_persist")
        try secondEditor.save(name: "暖金", style: .gold)
        library.reload()
        try require(library.presets.prefix(2).map(\.style) == [.gold, .pink], "role_and_clip_editors_share_saved_presets")
        let pink = ClipSubtitleRenderer.overlay(original, size: CGSize(width: 1920, height: 1080), style: .pink)!
        let white = ClipSubtitleRenderer.overlay(original, size: CGSize(width: 1920, height: 1080), style: .classic)!
        try NSBitmapImageRep(cgImage: pink).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("pink-subtitle-overlay.png"))
        try require(pink.dataProvider?.data != white.dataProvider?.data, "v120_coretext_renderer_uses_independent_language_colors")
        let bytes = CFDataGetBytePtr(pink.dataProvider!.data!)!
        var pinkPixels = 0, whitePixels = 0
        for y in 0..<pink.height { for x in 0..<pink.width {
            let i = y * pink.bytesPerRow + x * 4
            if bytes[i + 3] > 180 && bytes[i] > 200 && bytes[i + 2] > 150 {
                if bytes[i + 1] > 210 { whitePixels += 1 } else if bytes[i + 1] < 190 { pinkPixels += 1 }
            }
        } }
        try require(pinkPixels > 100 && whitePixels > 50, "v120_renderer_keeps_pink_chinese_and_white_japanese_fills_inside_outlines")
        store.start(ClipJob(projectID: id, kind: .transcribe, range: a), model: nil, services: ClipServices(recognizer: UnusedRecognizer(), translator: ReviewFixture()))
        try await wait(store)
        try require(store.jobs[0].state == .completed && store.projects[0].captions == [original], "v120_repeated_asr_request_uses_existing_coverage")
        store.start(ClipJob(projectID: id, kind: .proofread, range: first), model: nil, services: ClipServices(recognizer: UnusedRecognizer(), translator: ReviewFixture()))
        try await wait(store)
        try require(store.jobs[0].state == .completed && store.projects[0].ranges[0].proofreadCandidates?.first?.translated == "核对后的中文译文" && store.projects[0].captions(for: store.projects[0].ranges[0])[0].translated == edited.translated, "v120_model_review_proposes_changes_without_silent_overwrite")
        let outputs = root.appendingPathComponent("exports"); try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
        store.start(ClipJob(projectID: id, kind: .export, ranges: store.projects[0].ranges, burnSubtitles: true, exportKind: .mp4, outputFolder: outputs.path), model: nil)
        try await wait(store)
        try require(store.jobs[0].state == .completed && store.projects[0].exports.count == 2, "v120_identical_time_ranges_with_different_edits_export_as_two_files")
        let movies = store.projects[0].exports
        for path in movies {
            let info = try await ClipMediaEngine.inspect(URL(fileURLWithPath: path))
            try require(abs(info.duration - 4) < 0.25 && info.hasAudio, "v120_styled_mp4_has_correct_duration_and_audio_" + URL(fileURLWithPath: path).lastPathComponent)
        }
        let pinkMovie = movies.first { URL(fileURLWithPath: $0).lastPathComponent.contains(LiveRecordingEngine.safeName(a.title)) }!
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: pinkMovie)))
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("pink-styled-mp4-frame.png"))
        store.start(ClipJob(projectID: id, kind: .export, ranges: [a], burnSubtitles: false, exportKind: .mp3, outputFolder: outputs.path), model: nil)
        try await wait(store)
        try require(store.jobs[0].state == .completed && store.projects[0].exports.first?.hasSuffix(".mp3") == true, "v120_real_mp3_encoding_and_independent_ffprobe_validation")
        store.start(ClipJob(projectID: id, kind: .preview, range: a), model: nil); try await wait(store)
        guard let preview = store.projects[0].previewPath else { throw ClipError.message("preview absent") }
        store.setStyle(id, rangeID: a.id, style: .gold)
        try require(store.projects[0].previewPath == nil && !FileManager.default.fileExists(atPath: preview), "v120_style_change_invalidates_generated_preview")
        store.setStyle(id, rangeID: a.id, style: .pink, all: true)
        try require(store.projects[0].ranges.allSatisfy { $0.style == .pink }, "v120_apply_style_to_all_segments")
        store.deleteSegmentCaption(id, rangeID: b.id, cueID: original.id)
        try require(store.projects[0].captions(for: store.projects[0].ranges[1]).isEmpty && !store.projects[0].captions(for: store.projects[0].ranges[0]).isEmpty, "v120_delete_caption_is_scoped_to_one_segment")
        store.update(id) { $0.ranges[1].importedCaptions = imported; $0.ranges[1].deletedCaptionIDs = nil }
        for dark in [true, false] {
            try await snapshot(ClipWorkspace(onBack: {}).environmentObject(store).environmentObject(model).environmentObject(monitor).preferredColorScheme(dark ? .dark : .light), size: CGSize(width: 1280, height: 820), output: root.appendingPathComponent(dark ? "workbench-dark.png" : "workbench-light.png"), dark: dark)
        }
        let defaults = UserDefaults(suiteName: "SimuSub.V120Home." + UUID().uuidString)!
        defaults.set(true, forKey: "home.dark.v099")
        let appearance = HomeAppearance(defaults: defaults, backgroundFile: root.appendingPathComponent("background.png"))
        try await snapshot(StyleCheckHarness(root: root, cue: original).environmentObject(appearance).defaultAppStorage(defaults).preferredColorScheme(.dark), size: CGSize(width: 520, height: 800), output: root.appendingPathComponent("style-drawer.png"))
        try require(true, "v120_native_three_column_editor_and_style_drawer_rendered")
        store.removeProject(id)
        try require(FileManager.default.fileExists(atPath: fixture.path) && movies.allSatisfy { FileManager.default.fileExists(atPath: $0) } && store.projects.isEmpty, "v120_removing_project_preserves_source_and_exported_files")
        return checks
    }
    static func snapshot<V: View>(_ root: V, size: CGSize, output: URL, dark: Bool = true) async throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: root); window.orderFront(nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ClipError.message("无法捕获原生界面。") }
        view.layoutSubtreeIfNeeded(); view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: output)
        window.contentView = nil; window.close()
    }
}
private struct StyleCheckHarness: View {
    let root: URL
    let cue: Caption
    @State private var style = ClipSubtitleStyle.pink
    var body: some View { ClipStyleDrawer(style: $style, cue: cue, root: root, onClose: {}) { _ in }.background(ClipTheme.background) }
}
