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
        // The cloud decoder only hears what this gate emits. Enhancement can
        // erase quiet morae under game audio before the server receives them.
        let cloudJapanese = services.sourceLanguage == .japanese && services.recognizer is OpenAICompatibleSpeechRecognizer
        let frontend = try SpeechAudioFrontend(options: .init(suppressMusic: !cloudJapanese, showDrafts: false,
            endpointSilence: cloudJapanese ? 0.55 : 0.72,
            japanesePhraseBoundaries: services.sourceLanguage == .japanese && !(services.recognizer is ReazonSpeechRecognizer),
            japaneseClipContext: services.sourceLanguage == .japanese && services.recognizer is ReazonSpeechRecognizer,
            cloudJapaneseClip: cloudJapanese))
        let epoch = Date(timeIntervalSince1970: range.start)
        let gapDetector = services.japaneseClipVerifier.map {
            ClipJapaneseGapDetector(recognizer: $0, start: range.start, target: services.targetLanguage, independent: services.recognizer)
        }
        frontend.begin(at: epoch)
        frontend.onSegment = { buffer.append($0) }
        var cursor = range.start, previous: [SubtitleTranslationContext.Line] = []
        func savedCue(_ begin: Double, _ finish: Double) -> Caption? {
            existing.first { abs($0.start - begin) < 0.15 && abs($0.end - finish) < 0.3
                && $0.sourceLanguage == services.sourceLanguage && $0.targetLanguage == services.targetLanguage }
        }
        func decode(_ segment: AudioSegment, numberAlternates: inout [UUID: String]) async throws -> [Caption] {
            let start = max(range.start, segment.timestamp.timeIntervalSince1970)
            let end = min(range.end, segment.timestamp.timeIntervalSince1970 + Double(segment.samples.count) / 16000)
            guard end > start, segment.samples.contains(where: { abs($0) > 0.003 }) else { return [] }
            if let saved = savedCue(start, end) { return [saved] }
            var coreNumber: String?
            var hypothesis = try await services.recognizer.recognizeDetailed(samples: segment.samples)
            // A transducer can reduce a short reply to the number alone when
            // room sound is added. Reuse the original endpoint for this case.
            if let core = segment.detectedSpeechRange, !core.isEmpty,
               ClipJapaneseRecovery.isBareNumber(hypothesis.text) {
                let alternate = try await services.recognizer.recognizeDetailed(samples: Array(segment.samples[core]))
                if ClipJapaneseRecovery.isBareNumber(alternate.text), alternate.text != hypothesis.text { coreNumber = alternate.text }
                if let retained = ClipJapaneseRecovery.numericReaction(number: hypothesis.text, alternate: alternate,
                    offset: Double(core.lowerBound) / 16_000) { hypothesis = retained }
            }
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
            let cues = phrases.map { phrase in
                let begin = start + phrase.start, finish = start + phrase.end
                return savedCue(begin, finish) ?? Caption(start: begin, end: finish, original: phrase.text, translated: "",
                    sourceLanguage: services.sourceLanguage, targetLanguage: services.targetLanguage)
            }
            if let coreNumber, cues.count == 1, let cue = cues.first, cue.translated.isEmpty { numberAlternates[cue.id] = coreNumber }
            return cues
        }
        func publish(_ result: [Caption]) async throws {
            let cues = result.map { savedCue($0.start, $0.end) ?? $0 }
            for cue in cues { await onCue(cue) }
            for (index, original) in cues.enumerated() {
                try Task.checkCancellation()
                var cue = original
                if SubtitleDocument.completedTranslation(cue) == nil {
                    let following = cues.dropFirst(index + 1).prefix(1).filter { gapDetector == nil || $0.start - cue.end < 2 }.map(\.original)
                    cue.translated = try await services.translator.translate(cue.original, from: services.sourceLanguage.name, to: services.targetLanguage.name,
                        context: .init(previous: previous, isFinal: true, following: following)).trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard !cue.translated.isEmpty else { throw ClipError.message("翻译返回空内容，原文字幕已保留，请重试。") }
                    await onCue(cue)
                }
                previous.append(.init(original: cue.original, translated: cue.translated))
                if previous.count > 2 { previous.removeFirst() }
            }
            if let end = cues.last?.end {
                await progress(min(0.99, (end - range.start) / range.duration), "已处理 " + ClipTime.label(end - range.start) + " / " + ClipTime.label(range.duration))
            }
        }
        func consume(_ samples: [Float], finished: Bool = false) async throws {
            // The two decoders use independent model sessions. The short
            // verification calls that revisit Reazon share its existing decode lock.
            async let auxiliary: Void? = gapDetector?.accept(samples, finished: finished)
            var primary: [Caption] = []
            var numberAlternates: [UUID: String] = [:]
            let segments = buffer.take()
            for segment in segments {
                try Task.checkCancellation()
                let cues = try await decode(segment, numberAlternates: &numberAlternates)
                if gapDetector != nil { primary += cues } else { try await publish(cues) }
            }
            try await auxiliary
            if let gapDetector {
                try await publish(gapDetector.take(primary, completedStart: segments.last?.timestamp.timeIntervalSince1970, finished: finished, numberAlternates: numberAlternates))
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
            if samples.count > expected { samples.removeLast(samples.count - expected) }
            try? FileManager.default.removeItem(at: wav)
            var energy: [ClipEnergy] = []
            for start in stride(from: 0, to: samples.count, by: 16000) {
                let end = min(samples.count, start + 16000)
                let square = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
                energy.append(ClipEnergy(start: cursor + Double(start) / 16000, rms: sqrt(square / Double(end - start))))
            }
            await onEnergy(energy)
            frontend.accept(samples)
            try await consume(samples)
            cursor += span
        }
        frontend.finish()
        try await consume([], finished: true)
        try media.validateFile(); await progress(1, "字幕已保存，可编辑后导出。")
    }
}
