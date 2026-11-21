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
        let frontend = try SpeechAudioFrontend(options: .init(suppressMusic: true, showDrafts: false,
            japanesePhraseBoundaries: services.sourceLanguage == .japanese && !(services.recognizer is ReazonSpeechRecognizer)))
        frontend.begin(at: Date(timeIntervalSince1970: range.start))
        frontend.onSegment = { buffer.append($0) }
        var cursor = range.start, previous: [SubtitleTranslationContext.Line] = []
        func consume() async throws {
            for segment in buffer.take() {
                try Task.checkCancellation()
                let start = max(range.start, segment.timestamp.timeIntervalSince1970)
                let end = min(range.end, segment.timestamp.timeIntervalSince1970 + Double(segment.samples.count) / 16000)
                guard end > start, segment.samples.contains(where: { abs($0) > 0.003 }) else { continue }
                func savedCue(_ begin: Double, _ finish: Double) -> Caption? {
                    existing.first { abs($0.start - begin) < 0.15 && abs($0.end - finish) < 0.3
                        && $0.sourceLanguage == services.sourceLanguage && $0.targetLanguage == services.targetLanguage }
                }
                var cues: [Caption] = []
                if let saved = savedCue(start, end) { cues = [saved]; await onCue(saved) }
                else {
                    let hypothesis = try await services.recognizer.recognizeDetailed(samples: segment.samples)
                    try Task.checkCancellation()
                    let phrases: [TimedCaptionPhrase]
                    if services.sourceLanguage == .japanese {
                        let initial = JapaneseCaptionPhrase.split(hypothesis, duration: end - start, forTranslation: services.targetLanguage.isChinese)
                        if services.recognizer is JapaneseWindowRecognizing {
                            phrases = try await ClipJapaneseRecovery.fill(initial, samples: segment.samples,
                                forTranslation: services.targetLanguage.isChinese, recognize: services.recognizer.recognizeDetailed(samples:))
                        } else { phrases = initial }
                    } else if services.sourceLanguage.isChinese {
                        phrases = ChineseCaptionPhrases.split(hypothesis, duration: end - start, language: services.sourceLanguage)
                    } else {
                        let text = services.sourceLanguage == .english ? EnglishVocalTranscript.words(in: hypothesis.text)
                            : hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        phrases = text.isEmpty ? [] : [.init(text: text, start: 0, end: end - start)]
                    }
                    for phrase in phrases {
                        let begin = start + phrase.start, finish = start + phrase.end
                        if let saved = savedCue(begin, finish) { cues.append(saved); await onCue(saved); continue }
                        let cue = Caption(start: begin, end: finish, original: phrase.text, translated: "",
                                          sourceLanguage: services.sourceLanguage, targetLanguage: services.targetLanguage)
                        cues.append(cue)
                        await onCue(cue)
                    }
                }
                for (index, original) in cues.enumerated() {
                    var cue = original
                    if SubtitleDocument.completedTranslation(cue) == nil {
                        let following = cues.dropFirst(index + 1).prefix(1).map(\.original)
                        cue.translated = try await services.translator.translate(cue.original, from: services.sourceLanguage.name, to: services.targetLanguage.name, context: .init(previous: previous, isFinal: true, following: following))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        try Task.checkCancellation()
                        guard !cue.translated.isEmpty else { throw ClipError.message("翻译返回空内容，原文字幕已保留，请重试。") }
                        await onCue(cue)
                    }
                    previous.append(.init(original: cue.original, translated: cue.translated))
                    if previous.count > 2 { previous.removeFirst() }
                }
                await progress(min(0.99, (end - range.start) / range.duration), "已处理 " + ClipTime.label(end - range.start) + " / " + ClipTime.label(range.duration))
            }
        }
        while cursor < range.end - 0.001 {
            try Task.checkCancellation()
            let span = min(30, range.end - cursor), wav = temp.appendingPathComponent(UUID().uuidString + ".wav")
            await progress((cursor - range.start) / range.duration, "正在读取音轨 " + ClipTime.label(cursor))
            try await ClipMediaEngine.extractAudio(media: media, start: cursor, duration: span, output: wav)
            var samples = try AudioFileReader.read(wav, allowEmpty: true)
            // The selected video can outlast its audio track. Advance the VAD
            // clock through the silent tail, including an empty final WAV chunk.
            let expected = Int((span * 16_000).rounded())
            if samples.count < expected { samples.append(contentsOf: repeatElement(0, count: expected - samples.count)) }
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
        try media.validateFile(); await progress(1, "字幕已保存，可编辑后导出。")
    }
}
