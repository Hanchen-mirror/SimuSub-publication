import Foundation
import Darwin

/// Offline, network-disabled experiments using the exact native inference engines.
/// Text references may be authored or public: provenance must remain in the corpus.
enum MultilingualBenchmark {
    struct Plan: Decodable {
        var corpus: String
        var mode: String
        var asr: String = "sensevoice"
        var mt: String = "index"
        var automatic: Bool = false
        var prompt: String? = nil
        var provider: String? = nil
        var threads: Int? = nil
        var endpointSilence: Float? = nil
        var duration: Double? = nil
        var source: String? = nil
        var target: String? = nil
        var repeats: Int? = nil
        var direct: Bool? = nil
        var audioInstructions: String? = nil
        var gemmaModelPath: String? = nil
        var gemmaModelSHA256: String? = nil
        var gemmaProjectionPath: String? = nil
        var gemmaProjectionSHA256: String? = nil
        var sparseGemmaDrafts: Bool? = nil
        var backendSampling: Bool? = nil
    }
    struct Corpus: Decodable { var text: [TextCase]; var audio: [AudioCase] }
    struct TextCase: Decodable {
        var id: String; var source: String; var target: String; var text: String
        var reference: String; var previous: [String]?; var previousTranslation: String?
    }
    struct AudioCase: Decodable {
        var id: String; var source: String; var text: String?; var path: String; var provenance: String
    }
    struct Work: CaptionRevision {
        var id: UUID; var revision: Int; var isFinal: Bool
        var text: String; var language: String; var start: Double; var end: Double; var asrSeconds: Double
    }
    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var rows: [[String: Any]] = []
        var overflow = 0
        var peakASRQueue = 0
        var peakMTQueue = 0
        var drainSeconds = 0.0
        var health: [[String: Any]] = []
        func append(_ row: [String: Any]) { lock.withLock { rows.append(row) } }
        func failed() { lock.withLock { overflow += 1 } }
    }
    static func run(root: URL, manifest: URL, report: URL) async throws {
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: manifest))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: plan.corpus)))
        if plan.mode == "projector-conversion" {
            guard let source = plan.gemmaProjectionPath, let sha = plan.gemmaModelSHA256, let derived = plan.gemmaProjectionSHA256 else { throw ServiceError.modelFilesMissing }
            let path = try GemmaAudioProjector.prepare(source: URL(fileURLWithPath: source), sourceSHA256: sha, derivedSHA256: derived)
            try JSONSerialization.data(withJSONObject: ["path": path.path, "sha256": try LocalModelStore.sha256(of: path), "passed": true], options: [.prettyPrinted]).write(to: report)
            return
        }
        if plan.mode == "segments" {
            // Diagnose the actual frontend boundaries without running an ASR.
            let folder = report.deletingPathExtension().appendingPathExtension("audio")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var input: [Float] = [], bounds: [(AudioCase, Double, Double)] = []
            for item in corpus.audio {
                let pcm = try AudioFileReader.read(URL(fileURLWithPath: item.path))
                let start = Double(input.count) / 16000
                input += pcm
                bounds.append((item, start, Double(input.count) / 16000))
                input += [Float](repeating: 0, count: 16000)
            }
            let frontend = try SpeechAudioFrontend(options: .init(suppressMusic: true, showDrafts: true,
                preserveOriginal: true, stableCadence: true, endpointSilence: plan.endpointSilence ?? 0.48))
            var segments: [AudioSegment] = []
            frontend.onSegment = { if $0.isFinal { segments.append($0) } }
            frontend.begin(at: Date(timeIntervalSince1970: 0))
            for offset in stride(from: 0, to: input.count, by: 1600) {
                frontend.accept(Array(input[offset..<min(input.count, offset+1600)]))
            }
            frontend.finish()
            var rows: [[String: Any]] = []
            for (i, segment) in segments.enumerated() {
                let start = segment.timestamp.timeIntervalSince1970
                let end = start + Double(segment.samples.count) / 16000
                guard let item = bounds.first(where: { (start+end)/2 >= $0.1 && (start+end)/2 < $0.2+1 }) else { continue }
                let url = folder.appendingPathComponent("segment-\(i).wav")
                try floatingWAV(segment.samples).write(to: url)
                rows.append(["id": item.0.id+"-segment-\(i)", "source": item.0.source, "path": url.path,
                    "provenance": "Production frontend output of " + item.0.provenance,
                    "start": start, "end": end, "inputStart": item.1, "inputEnd": item.2])
            }
            try JSONSerialization.data(withJSONObject: ["text": [], "audio": rows], options: [.prettyPrinted, .sortedKeys]).write(to: report)
            return
        }
        let store = LocalModelStore(root: root)
        guard try await store.verifyInstalled(for: .translation) else { throw ServiceError.modelFilesMissing }
        let candidateID = plan.mt.hasPrefix("gemma4") ? "gemma4-e2b" : "hy-mt"
        let mtPath = plan.mt == "index" ? store.translationModelPath : root.appendingPathComponent(plan.mt.hasPrefix("gemma4") ? "gemma4-e2b/gemma-4-E2B_q4_0-it.gguf" : "hy-mt/HY-MT1.5-1.8B-Q4_K_M.gguf").path
        if plan.mt != "index", let definition = LocalModelDefinition.catalog.first(where: { $0.id == candidateID }) {
            for file in definition.files {
                guard try LocalModelStore.sha256(of: root.appendingPathComponent(candidateID + "/" + file.name)) == file.sha256 else { throw ModelStoreError.checksumFailed(file.name) }
            }
        }
        if let path = plan.gemmaModelPath {
            guard let sha = plan.gemmaModelSHA256, try LocalModelStore.sha256(of: URL(fileURLWithPath: path)) == sha else { throw ServiceError.modelFilesMissing }
        }
        let local = try LocalLlamaTranslator(modelPath: plan.gemmaModelPath ?? mtPath, useModelTemplate: plan.mt != "index", compactPrompt: plan.prompt == "hunyuan", gemma4Prompt: plan.mt.hasPrefix("gemma4"), backendSampling: plan.backendSampling ?? false)
        let translator: LanguageAwareTranslator
        if plan.mt == "hybrid" {
            translator = LanguageAwareTranslator(base: LocalSubtitleTranslator(index: try LocalLlamaTranslator(modelPath: store.translationModelPath), hunyuan: local))
        } else { translator = LanguageAwareTranslator(base: local) }
        let results = Results()
        let started = ProcessInfo.processInfo.systemUptime
        func write() throws {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            var memory = task_vm_info_data_t()
            var memoryCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let memoryStatus = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(memoryCount)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &memoryCount)
                }
            }
            let obj: [String: Any] = ["peakPhysicalFootprintBytes": memoryStatus == KERN_SUCCESS ? memory.ledger_phys_footprint_peak : 0,
                "peakASRPending": results.peakASRQueue, "peakMTPending": results.peakMTQueue, "drainSeconds": results.drainSeconds, "health": results.health,"mode": plan.mode, "asr": plan.asr, "mt": plan.mt, "automatic": plan.automatic,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - started, "peakRSSBytes": usage.ru_maxrss,
                "overflow": results.overflow, "rows": results.rows,
                "scope": "Native engines; synthetic and public fixtures, not a human-reviewed livestream benchmark. Stream mode injects PCM before production frontend, not ScreenCaptureKit."]
            try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted,.sortedKeys]).write(to: report, options: .atomic)
        }
        if plan.mode == "text" {
            for iteration in 0..<(plan.repeats ?? 1) {
                for item in corpus.text {
                    let before = ProcessInfo.processInfo.systemUptime
                    do {
                        var context = SubtitleTranslationContext(previous: (item.previous ?? []).map { .init(original: $0, translated: "", sourceLanguage: item.source) })
                        context.instructions = ServiceProfile.defaultTranslationPrompt
                        if let displayed = item.previousTranslation {
                            context.adjacentEnglishSource = item.previous?.last
                            context.adjacentEnglishTranslation = displayed
                        }
                        let output = try await translator.translate(item.text, from: item.source, to: item.target, context: context)
                        results.append(["id":item.id,"iteration":iteration,"source":item.text,"reference":item.reference,"output":output,"seconds":ProcessInfo.processInfo.systemUptime-before])
                    } catch { results.append(["id":item.id,"iteration":iteration,"error":error.localizedDescription]) }
                    try write()
                }
            }
            return
        }
        func recognizer(language: SubtitleLanguage?) throws -> any SpeechRecognizing {
            if plan.asr == "gemma4" {
                let projection = URL(fileURLWithPath: plan.gemmaProjectionPath ?? root.appendingPathComponent("gemma4-e2b/gemma-4-E2B-it-mmproj-f16.gguf").path)
                let expected = plan.gemmaProjectionSHA256 ?? "2f029eeab06ea2d1ceecdf83b0b6ee8a1e94d3b8b8b1e22d634a54fb11db7298"
                guard plan.mt.hasPrefix("gemma4"), try LocalModelStore.sha256(of: projection) == expected else { throw ServiceError.modelFilesMissing }
                return GemmaSpeechRecognizer(engine: local, projectionPath: projection.path, instructions: plan.audioInstructions)
            }
            if plan.asr.hasPrefix("automatic") {
                let folders = Dictionary(uniqueKeysWithValues: ["sensevoice", "whisper-base", "qwen3-asr"].map { ($0, root.appendingPathComponent($0)) })
                let base = try AutomaticSpeechRecognizer(store: store, folders: folders,
                    mixedLanguageHints: plan.asr == "automatic" || plan.asr.contains("hint"),
                    recoverInteriorOmissions: plan.asr == "automatic" || plan.asr.contains("recover"))
                return plan.asr.contains("trim") ? EdgeNormalizedRecognizer(base: base) : base
            }
            if plan.asr == "reazon" || plan.asr == "v144-router" { return try ReazonSpeechRecognizer(store: store) }
            guard let definition = LocalModelDefinition.catalog.first(where: { $0.id == plan.asr }) else { throw ServiceError.modelFilesMissing }
            return try MultilingualSpeechRecognizer(model: definition, folder: root.appendingPathComponent(plan.asr), language: language, threads: plan.threads ?? 4, task: plan.direct == true ? "translate" : "transcribe", provider: plan.provider ?? "cpu")
        }
        if plan.mode == "direct" {
            // Verify the same model/projector pair as the ASR path before evaluation.
            _ = try recognizer(language: nil)
            let projection = plan.gemmaProjectionPath ?? root.appendingPathComponent("gemma4-e2b/gemma-4-E2B-it-mmproj-f16.gguf").path
            for item in corpus.audio {
                let pcm = try AudioFileReader.read(URL(fileURLWithPath: item.path))
                for target in ["zh-Hans", "en", "ja"] where target != item.source {
                    let name = target == "en" ? "English" : target == "ja" ? "Japanese" : "Simplified Chinese"
                    let instruction = "Transcribe the following speech segment in its original language, then translate it into \(name). When formatting the answer, first output the transcription in its original language, then one newline, then output the string '\(name): ', then the translation in \(name)."
                    let before = ProcessInfo.processInfo.systemUptime
                    do {
                        let output = try await local.transcribeAudio(samples: pcm, projectionPath: projection, instructions: instruction)
                        results.append(["id": item.id + "-" + target, "source": item.text ?? "", "target": target, "output": output, "seconds": ProcessInfo.processInfo.systemUptime-before])
                    } catch { results.append(["id": item.id + "-" + target, "error": error.localizedDescription]) }
                    try write()
                }
            }
            return
        }
        let fixed = SubtitleLanguage.resolve(plan.source ?? "ja")!
        let engine = try recognizer(language: plan.automatic ? nil : fixed)
        if plan.mode == "audio" || plan.mode == "paired" {
            var configured: [String: any SpeechRecognizing] = [:]
            for item in corpus.audio {
                var activeEngine = engine
                if plan.asr == "v144-router" {
                    if let saved = configured[item.source] { activeEngine = saved }
                    else {
                        let language = SubtitleLanguage.resolve(item.source)!
                        if language == .japanese { activeEngine = try ReazonSpeechRecognizer(store: store) }
                        else {
                            let id = language == .english ? "whisper-base" : "sensevoice"
                            let definition = LocalModelDefinition.catalog.first { $0.id == id }!
                            activeEngine = try MultilingualSpeechRecognizer(model: definition, folder: root.appendingPathComponent(id), language: language)
                        }
                        configured[item.source] = activeEngine
                    }
                }
                let samples = try AudioFileReader.read(URL(fileURLWithPath:item.path))
                let before = ProcessInfo.processInfo.systemUptime
                let output = try await activeEngine.recognizeDetailed(samples:samples)
                let elapsed = ProcessInfo.processInfo.systemUptime-before
                var row: [String:Any] = ["id":item.id,"output":output.text,"language":output.language?.rawValue ?? "unknown","seconds":elapsed,"audioSeconds":Double(samples.count)/16000,"provenance":item.provenance]
                if let reference = item.text { row["reference"] = reference; row["CER"] = SpeechBenchmark.cer(reference,output.text) }
                if plan.mode == "paired" {
                    for target in ["zh-Hans", "en", "ja"] where target != item.source {
                        let mtStart = ProcessInfo.processInfo.systemUptime
                        let source = plan.automatic ? LiveLanguageRouting.translationSource(text: output.text, detected: output.language) : item.source
                        var context = SubtitleTranslationContext()
                        context.instructions = ServiceProfile.defaultTranslationPrompt
                        var paired = row
                        do {
                            paired["translated"] = try await translator.translate(output.text, from: source, to: target, context: context)
                            paired["target"] = target
                            paired["totalInferenceSeconds"] = elapsed + ProcessInfo.processInfo.systemUptime - mtStart
                        } catch { paired["error"] = error.localizedDescription }
                        results.append(paired); try write()
                    }
                } else { results.append(row); try write() }
            }
            return
        }
        // Pace PCM by a monotonic clock. Both workers and both bounded queues are
        // the same classes used in AppModel; this isolates inference from capture permissions.
        let clips = try corpus.audio.map { try AudioFileReader.read(URL(fileURLWithPath:$0.path)) + [Float](repeating:0,count:16000) }
        let input = clips.flatMap { $0 }
        let speech = CaptionRevisionQueue<AudioSegment>()
        let translation = CaptionRevisionQueue<Work>()
        let frontend = try SpeechAudioFrontend(options:.init(suppressMusic:true,showDrafts:true,preserveOriginal:true,stableCadence:true, endpointSilence: plan.endpointSilence ?? 0.72))
        let epoch = Date(timeIntervalSince1970:0)
        frontend.begin(at:epoch)
        frontend.onSegment = { if case .overflow = speech.offer($0) { results.failed() } }
        let clock = ProcessInfo.processInfo.systemUptime
        let target = plan.target ?? "zh-Hans"
        let mtWorker = Task {
            var previous: [SubtitleTranslationContext.Line] = []
            for await _ in translation.wakeups {
                while let item = translation.take() {
                    let before = ProcessInfo.processInfo.systemUptime
                    do {
                        var context = SubtitleTranslationContext(previous:Array(previous.suffix(2)))
                        context.instructions = ServiceProfile.defaultTranslationPrompt
                        let output = plan.direct == true ? item.text : try await translator.translate(item.text,from:item.language,to:target,context:context)
                        results.append(["id":item.id.uuidString,"source":item.text,"output":output,"sourceLanguage":item.language,"start":item.start,"end":item.end,
                            "stableAt":ProcessInfo.processInfo.systemUptime-clock,"latencyFromSegmentEnd":ProcessInfo.processInfo.systemUptime-clock-item.end,
                            "asrSeconds":item.asrSeconds,"mtSeconds":ProcessInfo.processInfo.systemUptime-before])
                        previous.append(.init(original:item.text,translated:output,sourceLanguage:item.language));previous=Array(previous.suffix(2))
                    } catch { results.append(["id":item.id.uuidString,"error":error.localizedDescription]) }
                }
            }
        }
        let asrWorker = Task {
            var gemmaDraftPolicy = GemmaDraftPolicy()
            for await _ in speech.wakeups {
                while let item = speech.take() {
                    if plan.asr == "gemma4", plan.sparseGemmaDrafts == true,
                       !gemmaDraftPolicy.shouldRecognize(id: item.id, sampleCount: item.samples.count, isFinal: item.isFinal, originalOnly: false) { continue }
                    do {
                        let before = ProcessInfo.processInfo.systemUptime
                        let recognized = try await (item.isFinal ? engine.recognizeDetailed(samples:item.samples) : engine.recognizeDraft(samples:item.samples))
                        if item.isFinal && !recognized.text.isEmpty {
                            let source = plan.automatic ? LiveLanguageRouting.translationSource(text: recognized.text, detected: recognized.language) : fixed.name
                            let work = Work(id:item.id,revision:item.revision,isFinal:true,text:recognized.text,language:source,
                                start:item.timestamp.timeIntervalSince1970,end:item.timestamp.timeIntervalSince1970+Double(item.samples.count)/16000,asrSeconds:ProcessInfo.processInfo.systemUptime-before)
                            if case .overflow = translation.offer(work) { results.failed() }
                        }
                    } catch { results.append(["id":item.id.uuidString,"error":error.localizedDescription]) }
                }
            }
            translation.finish()
        }
        let duration = plan.duration ?? 60
        var offset=0
        while Double(offset)/16000 < duration {
            let count=min(1600,Int(duration*16000)-offset)
            let tick=Double(offset+count)/16000
            let delay=clock+tick-ProcessInfo.processInfo.systemUptime
            if delay>0 { try await Task.sleep(nanoseconds:UInt64(delay*1e9)) }
            frontend.accept((0..<count).map { input[(offset+$0)%input.count] });offset+=count
            results.peakASRQueue = max(results.peakASRQueue, speech.pendingCount)
            results.peakMTQueue = max(results.peakMTQueue, translation.pendingCount)
            if offset % (16000*60) == 0 {
                results.health.append(["audioSeconds": offset/16000, "asrPending": speech.pendingCount, "mtPending": translation.pendingCount,
                    "finalized": results.lock.withLock { results.rows.count }])
                print("STREAM \(offset/16000)s finalized=\(results.lock.withLock { results.rows.count })");fflush(stdout)
            }
        }
        frontend.finish();speech.finish()
        await asrWorker.value;await mtWorker.value
        results.drainSeconds = max(0, ProcessInfo.processInfo.systemUptime-clock-duration)
        try write()
    }

    private static func floatingWAV(_ samples: [Float]) -> Data {
        // Preserve the exact frontend samples; re-quantizing to PCM16 would
        // introduce another variable into this boundary comparison.
        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36+samples.count*4)); ascii("WAVEfmt "); u32(16)
        u16(3); u16(1); u32(16000); u32(64000); u16(4); u16(32)
        ascii("data"); u32(UInt32(samples.count*4))
        for sample in samples { u32(sample.bitPattern) }
        return data
    }

    /// Experimental input normalization, deliberately outside the shipped route
    /// until frontend-segment regression shows a benefit.
    private struct EdgeNormalizedRecognizer: SpeechRecognizing {
        let base: any SpeechRecognizing
        func recognize(samples: [Float]) async throws -> String { try await recognizeDetailed(samples: samples).text }
        func recognizeDetailed(samples: [Float]) async throws -> RecognizedSpeech {
            guard let first = samples.firstIndex(where: { abs($0) > 0.003 }),
                  let last = samples.lastIndex(where: { abs($0) > 0.003 }) else { return RecognizedSpeech(text: "") }
            let lower = max(0, first-1600), upper = min(samples.count, last+1601)
            let lead = max(0, 3200-(first-lower)), tail = max(0, 3200-(upper-last-1))
            let normalized = [Float](repeating: 0, count: lead) + samples[lower..<upper] + [Float](repeating: 0, count: tail)
            var result = try await base.recognizeDetailed(samples: normalized)
            result.tokens = result.tokens.map { .init(text: $0.text, time: $0.time+Double(lower-lead)/16000) }
            return result
        }
    }
}
