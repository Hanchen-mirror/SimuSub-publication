import Foundation

private final class ClipSegmentBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [AudioSegment] = []
    func append(_ segment: AudioSegment) { if segment.isFinal { lock.withLock { segments.append(segment) } } }
    func take() -> [AudioSegment] { lock.withLock { defer { segments.removeAll() }; return segments } }
}
enum ClipSpeechPipeline {
    static func transcribe(media: ClipMedia, range: ClipRange, services: ClipServices, existing: [Caption],
                           progress: @escaping @Sendable (Double, String) async -> Void,
                           onCue: @escaping @Sendable (Caption) async -> Void,
                           onEnergy: @escaping @Sendable ([ClipEnergy]) async -> Void) async throws {
        guard media.hasAudio, range.start.isFinite, range.end.isFinite, range.start >= 0, range.end <= media.duration + 0.05, range.end > range.start else {
            throw ClipError.message("所选视频没有可识别的音轨或时间范围无效。")
        }
        try media.validateFile()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-speech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let buffer = ClipSegmentBuffer()
        let frontend = try SpeechAudioFrontend(options: .init(suppressMusic: true, showDrafts: false))
        frontend.begin(at: Date(timeIntervalSince1970: range.start))
        frontend.onSegment = { buffer.append($0) }
        var cursor = range.start, previous: [SubtitleTranslationContext.Line] = []
        func consume() async throws {
            for segment in buffer.take() {
                try Task.checkCancellation()
                let start = max(range.start, segment.timestamp.timeIntervalSince1970)
                let end = min(range.end, segment.timestamp.timeIntervalSince1970 + Double(segment.samples.count) / 16000)
                guard end > start, segment.samples.contains(where: { abs($0) > 0.003 }) else { continue }
                let saved = existing.first { abs($0.start - start) < 0.15 && abs($0.end - end) < 0.3 }
                var cue: Caption
                if let saved { cue = saved }
                else {
                    let original = try await services.recognizer.recognize(samples: segment.samples).trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard !original.isEmpty else { continue }
                    cue = Caption(start: start, end: end, original: original, translated: "")
                    await onCue(cue)
                }
                if SubtitleDocument.completedTranslation(cue) == nil {
                    cue.translated = try await services.translator.translate(cue.original, from: "日语", to: "中文", context: .init(previous: previous, isFinal: true))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard !cue.translated.isEmpty else { throw ClipError.message("翻译返回空内容，日语字幕已保留，请重试。") }
                    await onCue(cue)
                }
                previous.append(.init(original: cue.original, translated: cue.translated))
                if previous.count > 2 { previous.removeFirst() }
                await progress(min(0.99, (end - range.start) / range.duration), "已处理 " + ClipTime.label(end - range.start) + " / " + ClipTime.label(range.duration))
            }
        }
        while cursor < range.end - 0.001 {
            try Task.checkCancellation()
            let span = min(120, range.end - cursor), wav = temp.appendingPathComponent(UUID().uuidString + ".wav")
            await progress((cursor - range.start) / range.duration, "正在读取音轨 " + ClipTime.label(cursor))
            try await ClipMediaEngine.extractAudio(media: media, start: cursor, duration: span, output: wav)
            let samples = try AudioFileReader.read(wav)
            try? FileManager.default.removeItem(at: wav)
            var energy: [ClipEnergy] = []
            for start in stride(from: 0, to: samples.count, by: 16000) {
                let end = min(samples.count, start + 16000)
                let square = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
                energy.append(ClipEnergy(start: cursor + Double(start) / 16000, rms: sqrt(square / Double(end - start))))
            }
            await onEnergy(energy)
            frontend.accept(samples)
            try await consume()
            cursor += span
        }
        frontend.finish(); try await consume()
        try media.validateFile(); await progress(1, "日中字幕已保存，可编辑后导出。")
    }
}
