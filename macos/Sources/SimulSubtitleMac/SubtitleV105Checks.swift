import AppKit
import Foundation

/// Offline and simulated state only. No playback, capture, cloud requests or TCC.
@MainActor
enum SubtitleV105Checks {
    static func run() async throws -> [String] {
        var checks: [String] = []
        try require(SubtitleLineLayout.modelsAvailable, "bundled_budoux_models_available", &checks)
        let cases: [(SubtitleLineLayout.Language, String, [String])] = [
            (.japanese, "今日は天気です。", ["今日は", "天気です。"]),
            (.japanese, "今日は配信を見たいけど、明日は朝が早いので、少しだけにします。", ["今日は", "配信を", "見たいけど、", "明日は", "朝が", "早いので、", "少しだけに", "します。"]),
            (.japanese, "彼女は学校へ行きませんでした。", ["彼女は", "学校へ", "行きませんでした。"]),
            (.japanese, "雨が降っても配信を休むわけではありません。", ["雨が", "降っても", "配信を", "休むわけではありません。"]),
            (.japanese, "星街すいせいのライブをSafariで見ています。", ["星街すいせいの", "ライブを", "Safariで", "見ています。"]),
            (.japanese, "表情👩‍💻がかわいいですね。", ["表情👩‍💻が", "かわいいですね。"]),
            (.chinese, "今天是晴天。", ["今天", "是", "晴天。"]),
            (.chinese, "今天很想继续看直播，但是明天还要早起，所以只看一会儿。", ["今天", "很", "想", "继续", "看", "直播，", "但是", "明天", "还", "要", "早起，", "所以", "只", "看", "一", "会儿。"])
        ]
        for (index, item) in cases.enumerated() {
            try require(SubtitleLineLayout.chunks(item.1, language: item.0) == item.2,
                        "budoux_matches_pinned_python_case_\(index + 1)", &checks)
            for width: CGFloat in [96, 240, 480, 1000] {
                let font = NSFont.systemFont(ofSize: item.0 == .japanese ? 16 : 20)
                let formatted = SubtitleLineLayout.format(item.1, language: item.0, width: width, font: font)
                guard formatted.replacingOccurrences(of: "\n", with: "") == item.1 else { throw Failure("layout_lost_text") }
                let limit = max(24, min(width, font.pointSize * 24))
                for line in formatted.components(separatedBy: "\n") {
                    guard (line as NSString).size(withAttributes: [.font: font]).width <= limit + font.pointSize,
                          !line.hasPrefix("、"), !line.hasPrefix("。"), !line.hasSuffix("「") else { throw Failure("layout_bad_width_or_punctuation") }
                }
            }
        }
        checks.append("responsive_layout_preserves_all_characters_and_punctuation")
        let caption = Caption(start: 0, end: 2, original: cases[1].1, translated: cases[7].1)
        let before = SubtitleDocument.render([caption], format: .srt, mode: .bilingual)
        _ = SubtitleLineLayout.format(caption.original, language: .japanese, width: 96, font: .systemFont(ofSize: 16))
        try require(before == SubtitleDocument.render([caption], format: .srt, mode: .bilingual), "display_layout_does_not_change_export_or_source", &checks)

        let asrGate = CheckGate()
        let oldCaption = Caption(start: 0, end: 1, original: "古い字幕", translated: "旧字幕")
        let asrModel = makeModel(recognizer: GatedASR(gate: asrGate), translator: ImmediateMT())
        asrModel.captions = [oldCaption]
        asrModel.isCapturing = true
        asrModel.selectedAppBundleID = "com.apple.Safari"
        let waitingASR = Task { await asrModel.process([Float](repeating: 0.1, count: 16_000), start: 1) }
        try await waitForStart(asrGate)
        await asrModel.clearCaptions()
        await asrGate.release("新しい字幕です")
        await waitingASR.value
        try require(asrModel.captions.isEmpty && asrModel.isCapturing && asrModel.selectedAppBundleID == "com.apple.Safari",
                    "clear_invalidates_inflight_asr_and_keeps_source_simulated", &checks)

        let mtGate = CheckGate()
        let mtModel = makeModel(recognizer: ImmediateASR(), translator: GatedMT(gate: mtGate))
        let waitingMT = Task { await mtModel.process([Float](repeating: 0.1, count: 16_000), start: 0) }
        try await waitForStart(mtGate)
        try require(mtModel.captions.count == 1, "translation_draft_exists_before_clear", &checks)
        await mtModel.clearCaptions()
        await mtGate.release("新的字幕")
        await waitingMT.value
        try require(mtModel.captions.isEmpty && mtModel.status == "字幕已清空", "clear_invalidates_inflight_translation", &checks)
        await mtModel.process([Float](repeating: 0.1, count: 16_000), start: 2)
        try require(mtModel.captions.count == 1 && mtModel.captions[0].translated == "新的字幕" && !mtModel.captions[0].isDraft,
                    "new_caption_can_finalize_after_clear", &checks)

        let queue = CaptionRevisionQueue<AudioSegment>()
        _ = queue.offer(.init(id: UUID(), revision: 1, isFinal: true, samples: [0.1], timestamp: Date()))
        queue.discardPending()
        try require(queue.take() == nil, "clear_discards_queued_work", &checks)
        _ = queue.offer(.init(id: UUID(), revision: 1, isFinal: true, samples: [0.1], timestamp: Date()))
        try require(queue.take() != nil, "cleared_queue_accepts_new_work", &checks)
        queue.finish()
        return checks
    }

    private static func makeModel(recognizer: SpeechRecognizing, translator: TextTranslating) -> AppModel {
        AppModel(defaults: UserDefaults(suiteName: "SimuSub.ClearChecks.\(UUID().uuidString)")!,
                 modelStore: LocalModelStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("simusub-check-empty")),
                 recognizer: recognizer, translator: translator)
    }
    private static func waitForStart(_ gate: CheckGate) async throws {
        for _ in 0..<100 {
            if await gate.started { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw Failure("mock_inference_did_not_start")
    }
    private static func require(_ value: Bool, _ name: String, _ checks: inout [String]) throws {
        guard value else { throw Failure(name) }; checks.append(name)
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private actor CheckGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<String, Never>?
    private var released: String?
    func wait() async -> String {
        started = true
        if let released { return released }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ text: String) { released = text; continuation?.resume(returning: text); continuation = nil }
}
private struct GatedASR: SpeechRecognizing {
    let gate: CheckGate
    func recognize(samples: [Float]) async throws -> String { await gate.wait() }
}
private struct ImmediateASR: SpeechRecognizing {
    func recognize(samples: [Float]) async throws -> String { "新しい字幕です" }
}
private struct GatedMT: TextTranslating {
    let gate: CheckGate
    func translate(_ text: String, from source: String, to target: String) async throws -> String { await gate.wait() }
}
private struct ImmediateMT: TextTranslating {
    func translate(_ text: String, from source: String, to target: String) async throws -> String { "新的字幕" }
}
