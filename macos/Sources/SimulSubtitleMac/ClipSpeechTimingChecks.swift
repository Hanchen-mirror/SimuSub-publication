import Foundation

private actor ClipWindowProbeRecognizer: SpeechRecognizing {
    let word: String
    let thirdWord: String
    let thirdShift: Double
    private(set) var calls = 0
    init(_ word: String, thirdWord: String? = nil, thirdShift: Double = 0) {
        self.word = word
        self.thirdWord = thirdWord ?? word
        self.thirdShift = thirdShift
    }
    func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        calls += 1
        let text = calls == 3 ? thirdWord : word
        let time = 1.0 + (calls == 3 ? thirdShift : 0)
        return .init(text: text, tokens: text.enumerated().map {
            .init(text: String($0.element), time: time + 0.12 * Double($0.offset))
        })
    }
}

private actor ClipMeasuredVerifier: SpeechRecognizing {
    let recognizer: any SpeechRecognizing
    private(set) var elapsed: Double = 0
    private(set) var calls = 0
    init(_ recognizer: any SpeechRecognizing) { self.recognizer = recognizer }
    func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
    func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
        let start = ProcessInfo.processInfo.systemUptime
        let speech = try await recognizer.recognizeDetailed(samples: samples)
        elapsed += ProcessInfo.processInfo.systemUptime - start
        calls += 1
        return speech
    }
}
private actor ClipMeasuredCaptions {
    var read: Double?
    var first: Double?
    private(set) var cues: [Caption] = []
    func mark(_ message: String) {
        if read == nil && message.hasPrefix("正在读取音轨") { read = ProcessInfo.processInfo.systemUptime }
    }
    func receive(_ cue: Caption) {
        if first == nil { first = ProcessInfo.processInfo.systemUptime }
        if let i = cues.firstIndex(where: { $0.id == cue.id }) { cues[i] = cue } else { cues.append(cue) }
    }
}

enum ClipSpeechTimingChecks {
    static func timedTranscription(media: ClipMedia, services: ClipServices, directory: URL) async throws -> [Caption] {
        var measured = services
        let verifier = services.japaneseClipVerifier.map(ClipMeasuredVerifier.init)
        measured.japaneseClipVerifier = verifier
        let collector = ClipMeasuredCaptions()
        try await ClipSpeechPipeline.transcribe(media: media, range: .init(title: "", start: 0, end: media.duration),
            services: measured, existing: [], progress: { _, message in await collector.mark(message) },
            onCue: { await collector.receive($0) }, onEnergy: { _ in })
        if let read = await collector.read, let first = await collector.first {
            let metrics: [String: Double] = ["audioReadToFirstOriginal": first - read,
                "audioReadToPipelineCompletion": ProcessInfo.processInfo.systemUptime - read,
                "supplementaryRecognizerSeconds": await verifier?.elapsed ?? 0,
                "supplementaryRecognizerCalls": Double(await verifier?.calls ?? 0)]
            try JSONEncoder().encode(metrics).write(to: directory.appendingPathComponent("pipeline-timing.json"))
        }
        return await collector.cues
    }

    static func run(directory: URL) async throws -> [String] {
        var checks = try ClipJapaneseReactionChecks.run()
        func require(_ value: Bool, _ check: String) throws {
            guard value else { throw ClipError.message("CHECK FAILED: " + check) }
            checks.append(check)
        }
        checks += try ClipJapaneseNumberRecoveryChecks.run()
        let expanded = SpeechAudioFrontend.contextualRange(8_000..<16_000, previousEnd: 0, available: 0..<32_000, processed: 32_000)
        let adjacent = SpeechAudioFrontend.contextualRange(17_000..<20_000, previousEnd: expanded.upperBound, available: 0..<20_912, processed: 22_000)
        try require(expanded == 3_520..<21_120 && adjacent.isEmpty,
                    "japanese_clip_context_never_duplicates_an_owned_sample")
        try require(SpeechAudioFrontend.contextualRange(300..<8_000, previousEnd: 0, available: 0..<8_700, processed: 9_000) == 0..<8_700,
                    "japanese_clip_context_stays_inside_source_audio")
        var expandedNumber = Caption(start: 8, end: 9, original: "三百四十五", translated: "")
        let coreNumber = Caption(start: 8.12, end: 8.90, original: "34", translated: "34")
        try require(ClipJapaneseNumberRecovery.confirmsOriginalNumber("三十四", insteadOf: expandedNumber, verified: [coreNumber])
                    && !ClipJapaneseNumberRecovery.confirmsOriginalNumber("三十三", insteadOf: expandedNumber, verified: [coreNumber])
                    && !ClipJapaneseNumberRecovery.confirmsOriginalNumber("三十四円", insteadOf: expandedNumber, verified: [coreNumber])
                    && !ClipJapaneseNumberRecovery.confirmsOriginalNumber("三十四", insteadOf: expandedNumber, verified: []),
                    "japanese_changed_number_requires_exact_original_and_independent_timed_agreement")
        expandedNumber.translated = "人工校对"
        try require(!ClipJapaneseNumberRecovery.confirmsOriginalNumber("三十四", insteadOf: expandedNumber, verified: [coreNumber]),
                    "japanese_numeric_arbitration_preserves_saved_translation")
        let reply = RecognizedSpeech(text: "あれ三十五", tokens: [.init(text: "あれ", time: 0.12), .init(text: "三十五", time: 0.5)])
        try require(ClipJapaneseRecovery.numericReaction(number: "三十五", alternate: reply, offset: 0.25)?.tokens.last?.time == 0.75
                    && ClipJapaneseRecovery.numericReaction(number: "十五", alternate: reply, offset: 0.25) == nil
                    && ClipJapaneseRecovery.numericReaction(number: "35円", alternate: reply, offset: 0.25) == nil,
                    "japanese_short_numeric_reply_preserves_exact_number_and_acoustic_times")
        let digit = RecognizedSpeech(text: "七", tokens: [.init(text: "七", time: 3.2)])
        let one = JapaneseCaptionPhrase.split(digit, duration: 9)
        try require(one.count == 1 && one[0].start == 3.2 && one[0].end < 4.2,
                    "japanese_single_timed_digit_keeps_its_acoustic_onset_and_end")
        let padded = RecognizedSpeech(text: "また数字か", tokens: [
            .init(text: "また", time: 2.1), .init(text: "数字", time: 2.35), .init(text: "か", time: 3.05)])
        let bounded = JapaneseCaptionPhrase.split(padded, duration: 3)
        try require(bounded == [.init(text: padded.text, start: 2.1, end: 3)],
                    "japanese_decoder_padding_preserves_earlier_token_times")
        let raw = RecognizedSpeech(text: "あと二か", tokens: [
            .init(text: "あと", time: 0.05), .init(text: "二", time: 0.3), .init(text: "か", time: 0.45)])
        let same = RecognizedSpeech(text: raw.text, tokens: raw.tokens.map { .init(text: $0.text, time: $0.time + 0.3) })
        func agreement(_ other: RecognizedSpeech) -> [TimedCaptionPhrase] {
            ClipJapaneseGapDetector.agreement(raw, start: 0.3, duration: 1,
                second: other, otherStart: 0, otherDuration: 1.5, owned: 0..<1, limit: 1.5)
        }
        let late = RecognizedSpeech(text: raw.text, tokens: raw.tokens.map { .init(text: $0.text, time: $0.time + 0.8) })
        try require(agreement(same).map(\.text) == [raw.text] && agreement(late).isEmpty,
                    "japanese_gap_requires_independently_timed_words")
        for literal in ["3.5", "-12%", "1、2", "8:30"] {
            let notation = RecognizedSpeech(text: literal, tokens: literal.enumerated().map { .init(text: String($0.element), time: 0.1 * Double($0.offset)) })
            let later = RecognizedSpeech(text: literal, tokens: notation.tokens.map { .init(text: $0.text, time: $0.time + 0.3) })
            let agreed = ClipJapaneseGapDetector.agreement(notation, start: 0.3, duration: 1, second: later,
                otherStart: 0, otherDuration: 1.5, owned: 0..<1, limit: 1.5)
            try require(agreed.map(\.text).joined() == literal, "japanese_verified_numeric_symbols_preserved_" + literal)
        }
        let amount = Caption(start: 3, end: 4, original: "二十四万五千八百二十一", translated: "")
        let price = Caption(start: 3, end: 4, original: "二千四百五十八円", translated: "")
        let codes = [Caption(start: 2, end: 2.8, original: "2458", translated: "2458"),
                     Caption(start: 3.1, end: 3.9, original: "2458", translated: "2458")]
        try require(ClipJapaneseGapDetector.combine(primary: [amount], verified: codes) == codes
                    && ClipJapaneseGapDetector.combine(primary: [price], verified: codes) == [codes[0], price]
                    && ClipJapaneseGapDetector.combine(primary: [amount], verified: [codes[1]]) == [amount],
                    "japanese_repeated_code_requires_second_group_and_preserves_currency")

        let partial = Caption(start: 49, end: 50.25, original: "おぼえてない", translated: "")
        let complete = Caption(start: 48.75, end: 50.52, original: "重さ覚えてない", translated: "")
        let unrelated = Caption(start: 48.75, end: 50.52, original: "重さ調べたい", translated: "")
        try require(ClipJapaneseGapDetector.combine(primary: [partial], verified: [complete]) == [complete]
                    && ClipJapaneseGapDetector.combine(primary: [partial], verified: [unrelated]) == [partial],
                    "japanese_corroborated_phrase_extends_matching_kana_reading_only")

        for (word, third, shift, calls, expected) in [
            ("んで", "んで", 0.0, 3, ["んで"]), ("あれ", "雨", 0, 3, []),
            ("え", "え", 0.17, 3, []), ("雨", "雨", 0, 2, []),
            ("また数字か", "また数字か", 0, 2, ["また数字か"])] {
            let clock = ClipWindowProbeRecognizer(word, thirdWord: third, thirdShift: shift)
            let detector = ClipJapaneseGapDetector(recognizer: clock, start: 0, target: .simplifiedChinese)
            try await detector.accept([Float](repeating: 0.02, count: 16 * 16_000), finished: false)
            let result = try await detector.take([], completedStart: 8, finished: false)
            try require(await clock.calls == calls && result.map(\.original) == expected,
                        "japanese_third_window_candidate_and_timing_" + word)
        }
        for (replay, hasConflict, expected, calls) in [
            ("やった", true, "やった", 2), ("やった", false, "やった", 0), ("やっぱり", true, "やっぱり", 1)] {
            let first = ClipWindowProbeRecognizer("やった"), second = ClipWindowProbeRecognizer(replay)
            let detector = ClipJapaneseGapDetector(recognizer: first, start: 0, target: .simplifiedChinese, independent: second)
            try await detector.accept([Float](repeating: 0.02, count: 16 * 16_000), finished: false)
            let primary = Caption(start: 0.75, end: 1.54, original: "やっぱり", translated: "")
            let result = try await detector.take(hasConflict ? [primary] : [], completedStart: 8, finished: false)
            try require(await second.calls == calls && result.map(\.original) == [expected],
                        "japanese_short_conflict_replay_count_" + String(calls))
        }
        let clock = ClipWindowProbeRecognizer("あ")
        let detector = ClipJapaneseGapDetector(recognizer: clock, start: 0, target: .simplifiedChinese)
        let silence = [Float](repeating: 0, count: 30 * 16_000)
        try await detector.accept(silence, finished: false)
        let first = Caption(start: 19, end: 20.5, original: "一つ", translated: "")
        let crossing = Caption(start: 21.5, end: 24.8, original: "次の行", translated: "")
        let early = try await detector.take([first, crossing], completedStart: 21.5, finished: false)
        try await detector.accept(silence, finished: false)
        let last = Caption(start: 30.1, end: 31, original: "続き", translated: "")
        let later = try await detector.take([last], completedStart: 30.1, finished: false)
        try require(early == [first] && later == [crossing, last],
                    "japanese_release_closed_primary_segments_preserves_across_chunk_watermark")
        let temp = directory.appendingPathComponent("audio-clock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let source = temp.appendingPathComponent("delayed.mkv")
        let result = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "color=s=64x64:r=20:d=5",
            "-itsoffset", "1.5", "-f", "lavfi", "-i", "sine=frequency=530:sample_rate=16000:duration=3",
            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "mpeg4", "-c:a", "pcm_s16le", source.path])
        guard result.status == 0 else { throw ClipError.message(result.error) }
        let media = try await ClipMediaEngine.inspect(source)
        for start in [0.0, 0.75, 1.75] {
            let wav = temp.appendingPathComponent("seek-\(start).wav")
            try await ClipMediaEngine.extractAudio(media: media, start: start, duration: 3, output: wav)
            let samples = try AudioFileReader.read(wav)
            let onset = samples.firstIndex { abs($0) > 0.02 }.map { Double($0) / 16_000 } ?? -1
            try require(abs(onset - max(0, 1.5 - start)) < 0.002, "clip_audio_track_offset_survives_seek_\(start)")
        }
        return checks
    }
}
