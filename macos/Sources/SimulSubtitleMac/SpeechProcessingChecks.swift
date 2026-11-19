import Foundation

/// Explicit offline diagnostics. Never plays audio, captures applications, or changes TCC.
enum SpeechProcessingChecks {
    static func run(root: URL, audio: URL, report: URL, instrumentalAudio: URL? = nil) async throws {
        var results: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "", "audioPlayed": false,
            "liveCaptureUsed": false, "cloudUsed": false, "permissionsReset": false]
        try checkRevisionsAndExports()
        results["revisionQueueAndExports"] = true
        let source = try AudioFileReader.read(audio)
        guard source.count > 16_000 else { throw CheckError.failed("Speech fixture is too short") }
        let silence = [Float](repeating: 0, count: 16_000 * 4)
        let music = instrumental(count: 16_000 * 12)
        let quietSegments = try segments(silence, enhance: true)
        let musicSegments = try segments(music, enhance: true)
        guard quietSegments.isEmpty, musicSegments.isEmpty else { throw CheckError.failed("Silence or synthetic instrumental triggered speech") }
        results["silenceSpeechSegments"] = quietSegments.count
        results["syntheticInstrumentalSpeechSegments"] = musicSegments.count

        let baseline = try segments(source + silence, enhance: false)
        let enhanced = try segments(source + silence, enhance: true)
        let bed = instrumental(count: source.count)
        let mixture = zip(source, bed).map { max(-1, min(1, $0 + $1 * 0.5)) } + silence
        let started = Date()
        let mixed = try segments(mixture, enhance: true)
        results["enhancementAndVADRealtimeFactor"] = Date().timeIntervalSince(started) / (Double(mixture.count) / 16_000)
        let stopped = try segments(source, enhance: true)
        guard stopped.contains(where: \.isFinal) else { throw CheckError.failed("Stopping did not flush final speech") }
        results["stopFlushesFinalSpeech"] = true
        let finalOnly = try segments(source + silence, enhance: true, showDrafts: false)
        guard !finalOnly.isEmpty, finalOnly.allSatisfy(\.isFinal) else { throw CheckError.failed("Final-only option emitted a draft") }
        results["finalOnlyOption"] = true
        let firstVoice = source.firstIndex(where: { abs($0) > 0.03 }) ?? 0
        let lastVoice = source.lastIndex(where: { abs($0) > 0.03 }) ?? source.count - 1
        let phrase = Array(source[firstVoice...lastVoice])
        let longSpeech = Array(repeating: phrase, count: 14).flatMap { $0 } + silence
        let longFinals = try segments(longSpeech, enhance: true, showDrafts: false)
        guard longFinals.count >= 2,
              longFinals.allSatisfy({ $0.isFinal && $0.samples.count <= 16_000 * 25 }),
              zip(longFinals, longFinals.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw CheckError.failed("Long speech did not preserve bounded, ordered finals")
        }
        results["longSpeechInputSeconds"] = Double(longSpeech.count) / 16_000
        results["longSpeechFinalCount"] = longFinals.count
        results["longSpeechMaximumFinalSeconds"] = Double(longFinals.map { $0.samples.count }.max() ?? 0) / 16_000
        let japaneseFinals = try segments(longSpeech, enhance: true, showDrafts: false, japaneseBoundaries: true)
        guard japaneseFinals.count >= 2,
              japaneseFinals.allSatisfy({ $0.samples.count <= JapanesePhraseEndpoint.window + 512 }),
              zip(japaneseFinals, japaneseFinals.dropFirst()).allSatisfy({ left, right in
                  let leftEnd = Int((left.timestamp.timeIntervalSince1970 * 16_000).rounded()) + left.samples.count
                  return leftEnd <= Int((right.timestamp.timeIntervalSince1970 * 16_000).rounded())
              }),
              japaneseFinals.contains(where: { $0.samples.count >= 5 * 16_000 }),
              japaneseFinals.allSatisfy({ segment in
                  let start = Int((segment.timestamp.timeIntervalSince1970 * 16_000).rounded())
                  let end = start + segment.samples.count
                  return start >= 0 && end <= longSpeech.count && segment.samples.elementsEqual(longSpeech[start..<end])
              }) else { throw CheckError.failed("Japanese phrases lost timing or source samples at a cut") }
        results["japaneseMaximumFinalSeconds"] = Double(japaneseFinals.map { $0.samples.count }.max() ?? 0) / 16_000
        var realMixed: [AudioSegment] = []
        if let instrumentalAudio {
            let piano = try AudioFileReader.read(instrumentalAudio)
            let pianoOnly = try segments(piano, enhance: true)
            guard pianoOnly.isEmpty else { throw CheckError.failed("Piano instrumental triggered speech") }
            results["pianoDurationSeconds"] = Double(piano.count) / 16_000
            results["pianoSpeechSegments"] = pianoOnly.count
            // Normalize RMS to compare speech against music at +6 dB SNR.
            func rms(_ samples: [Float]) -> Double { sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count))) }
            let gain = rms(source) / max(0.0001, rms(piano)) * 0.5
            let withPiano = source.enumerated().map { index, value in max(-1, min(1, value + piano[index % piano.count] * Float(gain))) } + silence
            realMixed = try segments(withPiano, enhance: true)
            guard realMixed.contains(where: \.isFinal) else { throw CheckError.failed("Speech with piano was lost") }
            results["pianoFixtureSource"] = "Short Piano Song Loop / frosty ham / CC0 / https://opengameart.org/content/short-piano-song-loop"
        }
        func summary(_ values: [AudioSegment]) -> [[String: Any]] {
            values.map { ["id": $0.id.uuidString, "revision": $0.revision, "final": $0.isFinal,
                          "seconds": Double($0.samples.count) / 16_000] }
        }
        results["speechWithoutEnhancement"] = summary(baseline)
        results["speechWithEnhancement"] = summary(enhanced)
        results["speechWithSyntheticMusic"] = summary(mixed)
        results["speechWithPiano"] = summary(realMixed)
        for events in [baseline, enhanced, mixed] {
            guard events.contains(where: \.isFinal) else { throw CheckError.failed("No final speech segment") }
            for draft in events where !draft.isFinal {
                guard events.contains(where: { $0.id == draft.id && $0.isFinal && $0.revision > draft.revision }) else {
                    throw CheckError.failed("Draft did not finalize with the same ID")
                }
            }
        }
        guard enhanced.contains(where: { !$0.isFinal }),
              enhanced.contains(where: { $0.isFinal && $0.samples.count > 32_000 }) else {
            throw CheckError.failed("Fixture did not demonstrate a draft and a natural final longer than two seconds")
        }
        let store = LocalModelStore(root: root)
        let recognizer = try ReazonSpeechRecognizer(store: store)
        let translator = try LocalLlamaTranslator(modelPath: store.translationModelPath)
        var translated: [[String: Any]] = []
        var previous: [SubtitleTranslationContext.Line] = []
        var actualDraft: String?
        if let draft = enhanced.first(where: { !$0.isFinal }) {
            let start = Date()
            let original = try await recognizer.recognize(samples: draft.samples)
            let chinese = try await translator.translate(original, from: "Japanese", to: "中文", context: .init(isFinal: false))
            actualDraft = chinese
            results["firstDraft"] = ["original": original, "translated": chinese,
                "audioSeconds": Double(draft.samples.count) / 16_000, "processingSeconds": Date().timeIntervalSince(start)]
        }
        var cleanOriginal: String?
        for (label, events) in [("clean", enhanced), ("synthetic-music", mixed), ("piano-music", realMixed)] {
            for segment in events where segment.isFinal {
                let asrStart = Date()
                let original = try await recognizer.recognize(samples: segment.samples)
                guard !original.isEmpty else { throw CheckError.failed("Empty speech recognition") }
                let asrTime = Date().timeIntervalSince(asrStart)
                if let cleanOriginal, original != cleanOriginal { throw CheckError.failed("Music altered fixture recognition") }
                cleanOriginal = original
                let start = Date()
                let chinese = try await translator.translate(original, from: "Japanese", to: "中文",
                    context: .init(previous: previous, isFinal: true))
                guard !chinese.isEmpty else { throw CheckError.failed("Empty final translation") }
                if original.contains("字幕をテスト"), !chinese.contains("字幕") {
                    throw CheckError.failed("Final translation did not recover 字幕 from incomplete draft")
                }
                translated.append(["input": label, "original": original, "translated": chinese,
                                   "translationSeconds": Date().timeIntervalSince(start), "recognitionSeconds": asrTime])
                previous = [.init(original: original, translated: chinese)]
            }
        }
        results["localFinalTranslations"] = translated
        results["draftReplacedByFreshFullSourceTranslation"] = actualDraft != nil
        let negative = try await translator.translate("今日はゲームをしません。", from: "Japanese", to: "中文", context: .init())
        guard negative.contains("不") || negative.contains("没") else { throw CheckError.failed("Negation was lost") }
        results["negationTranslation"] = negative
        let reaction = try await translator.translate("へえ", from: "Japanese", to: "中文", context: .init(previous: [.init(original: "阿部寛はもともとモデルだった", translated: "原来阿部宽本来就是模特啊，真没想到。")]))
        guard reaction.count < 16, !reaction.contains("阿部"), !reaction.contains("模特") else { throw CheckError.failed("Short reaction copied prior translation") }
        results["shortReactionWithContext"] = reaction
        results["limitations"] = "One short Japanese fixture, synthetic instrumental and optional piano recording only; not proof for singing or all live-stream music."
        results["passed"] = true
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print("Speech processing checks passed; report: \(report.path)")
    }

    private static func segments(_ samples: [Float], enhance: Bool, showDrafts: Bool = true, japaneseBoundaries: Bool = false) throws -> [AudioSegment] {
        let engine = try SpeechAudioFrontend(options: .init(suppressMusic: enhance, showDrafts: showDrafts,
            japanesePhraseBoundaries: japaneseBoundaries))
        var segments: [AudioSegment] = []
        engine.onSegment = { segments.append($0) }
        engine.begin(at: Date(timeIntervalSince1970: 0))
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            engine.accept(Array(samples[offset..<min(offset + 1600, samples.count)]))
        }
        engine.finish()
        return segments
    }

    private static func instrumental(count: Int) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / 16_000
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let chord = sin(2 * .pi * 220 * t) + 0.6 * sin(2 * .pi * 277.18 * t) + 0.4 * sin(2 * .pi * 329.63 * t)
            let bass = sin(2 * .pi * 65.4 * t) * exp(-beat * 12)
            return Float(0.07 * chord * (0.65 + 0.35 * sin(2 * .pi * 0.25 * t)) + 0.10 * bass)
        }
    }

    private static func checkRevisionsAndExports() throws {
        struct Revision: CaptionRevision { let id: UUID; let revision: Int; let isFinal: Bool }
        let queue = CaptionRevisionQueue<Revision>(capacity: 2)
        let id = UUID(), other = UUID()
        _ = queue.offer(.init(id: id, revision: 1, isFinal: false))
        _ = queue.offer(.init(id: id, revision: 2, isFinal: true))
        guard case .obsolete = queue.offer(.init(id: id, revision: 3, isFinal: false)) else { throw CheckError.failed("Final replaced by draft") }
        _ = queue.offer(.init(id: other, revision: 1, isFinal: true))
        guard case .overflow = queue.offer(.init(id: UUID(), revision: 1, isFinal: true)),
              queue.take()?.revision == 2, queue.take()?.id == other else { throw CheckError.failed("Queue lost final utterances") }
        queue.finish()
        let draft = Caption(start: 0, end: 2, original: "草稿原文", translated: "草稿译文", isDraft: true)
        let final = Caption(start: 2, end: 5, original: "最終原文", translated: "正式译文")
        for format in SubtitleExportFormat.allCases {
            let document = SubtitleDocument.render([draft, final], format: format, mode: .bilingual)
            guard !document.contains("草稿"), document.contains("正式译文"), document.contains("最終原文") else { throw CheckError.failed("Export included draft") }
        }
        let context = SubtitleTranslationContext(previous: [.init(original: "前文", translated: "上下文")])
        guard context.prompt(for: "現在").contains("上下文"), context.prompt(for: "現在").contains("現在") else { throw CheckError.failed("Missing correction context") }
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"start\":0,\"end\":1,\"original\":\"旧\",\"translated\":\"兼容\"}".utf8)
        guard !(try JSONDecoder().decode(Caption.self, from: old)).isDraft else { throw CheckError.failed("Old caption compatibility") }
    }

    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
