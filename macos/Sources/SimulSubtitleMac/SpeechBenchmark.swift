import Foundation

/// Reproducible local measurements. Reference-free live clips never receive a CER score.
enum SpeechBenchmark {
    struct Manifest: Decodable {
        let label: String
        let threads: Int
        let decoding: String
        let enhance: Bool
        let drafts: Bool
        let preserveOriginal: Bool?
        let translate: Bool?
        let hotwords: [String]?
        let hotwordScore: Float?
        let stablePrefixes: Bool?
        let translationTerms: [VTuberTerm]?
        let cases: [Case]
        struct Case: Decodable { let name: String; let path: String; let reference: String? }
    }
    static func run(root: URL, manifest: URL, report: URL) async throws {
        let plan = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
        let loaded = Date()
        let engine = try ReazonSpeechRecognizer(store: LocalModelStore(root: root), threads: plan.threads, decoding: plan.decoding, hotwords: plan.hotwords ?? [], hotwordScore: plan.hotwordScore ?? 1.0)
        let loadTime = Date().timeIntervalSince(loaded)
        let translator = plan.translate == true ? try LocalLlamaTranslator(modelPath: LocalModelStore(root: root).translationModelPath) : nil
        var rows: [[String: Any]] = []
        for item in plan.cases {
            let samples = try AudioFileReader.read(URL(fileURLWithPath: item.path))
            let started = Date()
            let frontend = try SpeechAudioFrontend(options: .init(suppressMusic: plan.enhance, showDrafts: plan.drafts, preserveOriginal: plan.preserveOriginal ?? true, stableCadence: plan.stablePrefixes ?? false))
            var segments: [AudioSegment] = []
            var emittedAt: [Double] = [], inputClock = 0.0
            frontend.onSegment = { segments.append($0); emittedAt.append(inputClock) }
            frontend.begin(at: Date(timeIntervalSince1970: 0))
            for offset in stride(from: 0, to: samples.count, by: 1600) {
                inputClock = Double(min(samples.count, offset + 1600)) / 16000
                frontend.accept(Array(samples[offset..<min(samples.count, offset + 1600)]))
            }
            frontend.finish()
            let frontendTime = Date().timeIntervalSince(started)
            var texts: [[String: Any]] = [], finalText = "", asrTime = 0.0, finalTime = 0.0
            var previous: [SubtitleTranslationContext.Line] = []
            var confirmations: [UUID: StablePrefixConfirmation] = [:]
            var early: [UUID: (text: String, at: Double, chinese: String)] = [:]
            var prefixEvents: [[String: Any]] = []
            for (segmentIndex, segment) in segments.enumerated() {
                let start = Date()
                let text = try await engine.recognize(samples: segment.samples)
                let elapsed = Date().timeIntervalSince(start)
                asrTime += elapsed
                if segment.isFinal { finalText += text; finalTime += elapsed }
                var chinese = "", mtTime = 0.0
                if plan.stablePrefixes == true, !segment.isFinal {
                    var confirmation = confirmations[segment.id] ?? StablePrefixConfirmation()
                    if let prefix = confirmation.observe(text, samples: segment.samples.count) {
                        var prefixChinese = ""
                        if let translator, !translator.requiresFullUtterance {
                            let mtStart = Date()
                            prefixChinese = try await GlossaryTranslator(base: translator, terms: plan.translationTerms ?? VTuberGlossary.defaults).translate(prefix, from: "ja", to: "zh", context: .init(previous: Array(previous.suffix(2))))
                            mtTime = Date().timeIntervalSince(mtStart)
                        }
                        early[segment.id] = (prefix, emittedAt[segmentIndex], prefixChinese)
                    }
                    confirmations[segment.id] = confirmation
                }
                if segment.isFinal, let prefix = early[segment.id] {
                    prefixEvents.append(["source": prefix.text, "final": text, "agreesWithFinal": text.hasPrefix(prefix.text),
                        "chineseTranslatedEarly": !prefix.chinese.isEmpty, "earlyAt": prefix.at, "finalAt": emittedAt[segmentIndex], "leadSeconds": emittedAt[segmentIndex] - prefix.at])
                }
                if segment.isFinal, let translator, !text.isEmpty {
                    let mtStart = Date()
                    let saved = early[segment.id].flatMap { text.hasPrefix($0.text) && !$0.chinese.isEmpty ? $0 : nil }
                    let source = saved.map { String(text.dropFirst($0.text.count)) } ?? text
                    var context = SubtitleTranslationContext(previous: Array(previous.suffix(2)))
                    if let saved { context.previous.append(.init(original: saved.text, translated: saved.chinese)) }
                    let tail = source.isEmpty ? "" : try await GlossaryTranslator(base: translator, terms: plan.translationTerms ?? VTuberGlossary.defaults).translate(source, from: "ja", to: "zh", context: context)
                    chinese = [saved?.chinese ?? "", tail].filter { !$0.isEmpty }.joined(separator: "\n")
                    mtTime = Date().timeIntervalSince(mtStart)
                    previous.append(.init(original: text, translated: chinese))
                }
                texts.append(["chinese": chinese, "translationSeconds": mtTime, "start": segment.timestamp.timeIntervalSince1970, "duration": Double(segment.samples.count)/16000,
                              "emittedAt": emittedAt[segmentIndex], "final": segment.isFinal, "text": text, "seconds": elapsed])
            }
            var row: [String: Any] = ["name": item.name, "audioSeconds": Double(samples.count)/16000,
                "frontendSeconds": frontendTime, "asrSeconds": asrTime, "finalASRSeconds": finalTime,
                "finalText": finalText, "segments": texts, "prefixEvents": prefixEvents, "drafts": segments.filter { !$0.isFinal }.count,
                "finals": segments.filter(\.isFinal).count]
            if let reference = item.reference { row["reference"] = reference; row["CER"] = cer(reference, finalText) }
            rows.append(row)
            print("BENCH: \(item.name) ASR=\(asrTime) text=\(finalText)"); fflush(stdout)
            let result: [String: Any] = ["label": plan.label, "threads": plan.threads, "decoding": plan.decoding,
                "enhance": plan.enhance, "acceptedHotwords": engine.hotwordPlan.accepted, "rejectedHotwords": engine.hotwordPlan.rejected, "hotwordScore": plan.hotwordScore ?? 1.0, "modelLoadSeconds": loadTime, "cases": rows,
                "accuracyNote": "CER only for supplied references; live reference-free transcripts are qualitative evidence, not measured accuracy."]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        }
    }
    static func cer(_ reference: String, _ hypothesis: String) -> Double {
        func normalized(_ text: String) -> [Character] {
            Array(String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
            }))
        }
        let a = normalized(reference), b = normalized(hypothesis)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i+1] + Array(repeating: 0, count: b.count)
            for (j,y) in b.enumerated() { next[j+1] = min(next[j]+1, row[j+1]+1, row[j]+(x == y ? 0 : 1)) }
            row = next
        }
        return Double(row.last!) / Double(max(1,a.count))
    }
}
