import CryptoKit
import Foundation
import SherpaOnnx
import SherpaOnnxC

struct SubtitleProcessingOptions: Equatable, Sendable {
    var suppressMusic = true
    var showDrafts = true
    var preserveOriginal = true
}

protocol CaptionRevision: Identifiable, Sendable where ID == UUID {
    var revision: Int { get }
    var isFinal: Bool { get }
}

struct AudioSegment: CaptionRevision {
    let id: UUID
    let revision: Int
    let isFinal: Bool
    let samples: [Float]
    let timestamp: Date
}

struct CapturedAudioSegment: CaptionRevision {
    let audio: AudioSegment
    let generation: UUID
    var id: UUID { audio.id }
    var revision: Int { audio.revision }
    var isFinal: Bool { audio.isFinal }
}

/// A wake-up stream plus a bounded, revision-aware work list. A newer draft
/// replaces only the same utterance; final utterances are never silently evicted.
final class CaptionRevisionQueue<Item: CaptionRevision>: @unchecked Sendable {
    enum Offer { case accepted, obsolete, overflow }
    let wakeups: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var items: [Item] = []
    private var closed = false
    private let capacity: Int

    init(capacity: Int = 24) {
        self.capacity = capacity
        var sink: AsyncStream<Void>.Continuation!
        wakeups = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { sink = $0 }
        continuation = sink
    }

    func offer(_ item: Item) -> Offer {
        let result: Offer = lock.withLock {
            guard !closed else { return .obsolete }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                guard item.revision > items[index].revision,
                      !items[index].isFinal || item.isFinal else { return .obsolete }
                items[index] = item
            } else {
                guard items.count < capacity else { return .overflow }
                items.append(item)
            }
            return .accepted
        }
        if case .accepted = result { continuation.yield(()) }
        return result
    }

    func take() -> Item? { lock.withLock { items.isEmpty ? nil : items.removeFirst() } }
    func discardPending() { lock.withLock { items.removeAll() } }
    func finish() {
        lock.withLock { closed = true }
        continuation.yield(())
        continuation.finish()
    }
}

/// Stateful 16 kHz enhancement and VAD. Construction can happen off-queue;
/// after transfer, all mutations are exclusively confined to its owning queue.
/// GTCRN suppresses background interference; it is not a singing/speech separator.
final class SpeechAudioFrontend: @unchecked Sendable {
    static let sampleRate = 16_000
    private let denoiser: SherpaOnnxOnlineSpeechDenoiserWrapper?
    private let vad: OpaquePointer
    private let options: SubtitleProcessingOptions
    private var rawHistory: [Float] = []
    private var rawHistoryStart = 0
    private var pending: [Float] = []
    private var history: [Float] = []
    private var historyStart = 0
    private var processed = 0
    private var activeID: UUID?
    private var activeStart = 0
    private var revision = 0
    private var lastDraftSample = 0
    private var epoch = Date()
    var onSegment: ((AudioSegment) -> Void)?

    init(options: SubtitleProcessingOptions = .init(), modelDirectory: URL? = nil) throws {
        self.options = options
        let root = modelDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("AudioModels")
        guard let root else { throw FrontendError.missingModels }
        func checked(_ name: String, hash: String) throws -> String {
            let url = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw FrontendError.invalidModel(name)
            }
            return url.path
        }
        let vadPath = try checked("silero_vad.onnx", hash: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
        if options.suppressMusic {
            let path = try checked("gtcrn_simple.onnx", hash: "e77603ac0c23dac3227dd2d7135b3a585cbee2679048aecfa886657d3ae1b534")
            var config = sherpaOnnxOnlineSpeechDenoiserConfig(model: sherpaOnnxOfflineSpeechDenoiserModelConfig(
                gtcrn: sherpaOnnxOfflineSpeechDenoiserGtcrnModelConfig(model: path), numThreads: 1))
            let engine = SherpaOnnxOnlineSpeechDenoiserWrapper(config: &config)
            guard engine.impl != nil, engine.sampleRate == Self.sampleRate else { throw FrontendError.initialization }
            denoiser = engine
        } else { denoiser = nil }
        var config = sherpaOnnxVadModelConfig(sileroVad: sherpaOnnxSileroVadModelConfig(
            model: vadPath, threshold: 0.60, minSilenceDuration: 0.72,
            minSpeechDuration: 0.18, windowSize: 512, maxSpeechDuration: 20), numThreads: 1)
        guard let detector = SherpaOnnxCreateVoiceActivityDetector(&config, 32) else { throw FrontendError.initialization }
        vad = detector
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    func begin(at date: Date) { epoch = date }

    func accept(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if options.preserveOriginal && denoiser != nil { rawHistory.append(contentsOf: samples) }
        consume(denoiser?.run(samples: samples, sampleRate: Self.sampleRate).samples ?? samples)
    }

    func finish() {
        if let denoiser { consume(denoiser.flush().samples) }
        if !pending.isEmpty {
            let padding = 512 - pending.count
            consume([Float](repeating: 0, count: padding))
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        drainCompleted()
    }

    static func draftInterval(for duration: Int) -> Int {
        // Offline ASR re-decodes the entire growing sentence; bound redundant work.
        min(64_000, max(24_000, duration / 3))
    }

    private func consume(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= 512 {
            let frame = Array(pending[offset..<offset + 512])
            offset += 512
            history.append(contentsOf: frame)
            processed += 512
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, frame, 512)
            drainCompleted()
            if SherpaOnnxVoiceActivityDetectorDetected(vad) == 1 {
                if activeID == nil {
                    activeID = UUID()
                    activeStart = max(historyStart, processed - 8_000)
                    revision = 0
                    lastDraftSample = activeStart
                }
                let duration = processed - activeStart
                if duration >= 24 * Self.sampleRate {
                    // Safety limit only; ordinary sentence boundaries come from VAD.
                    SherpaOnnxVoiceActivityDetectorFlush(vad)
                    drainCompleted()
                } else if options.showDrafts && processed - lastDraftSample >= Self.draftInterval(for: duration) {
                    let start = max(0, activeStart - historyStart)
                    emit(Array(history.dropFirst(start)), start: activeStart, final: false)
                    lastDraftSample = processed
                }
            }
            let retainFrom = activeID == nil ? processed - 8_000 : activeStart
            if retainFrom > historyStart {
                let count = min(history.count, retainFrom - historyStart)
                history.removeFirst(count)
                historyStart += count
                let rawCount = min(rawHistory.count, max(0, retainFrom - rawHistoryStart))
                if rawCount > 0 { rawHistory.removeFirst(rawCount); rawHistoryStart += rawCount }
            }
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    private func drainCompleted() {
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            if let speech = SherpaOnnxVoiceActivityDetectorFront(vad) {
                let count = Int(speech.pointee.n)
                if count >= 2_880, let data = speech.pointee.samples {
                    emit(Array(UnsafeBufferPointer(start: data, count: count)), start: Int(speech.pointee.start), final: true)
                }
                SherpaOnnxDestroySpeechSegment(speech)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
            activeID = nil
            revision = 0
        }
    }

    private func emit(_ samples: [Float], start: Int, final: Bool) {
        guard !samples.isEmpty else { return }
        if activeID == nil { activeID = UUID() }
        revision += 1
        var recognitionSamples = samples
        if options.preserveOriginal && denoiser != nil {
            let lower = max(0, start - rawHistoryStart)
            let upper = min(rawHistory.count, lower + samples.count)
            if upper > lower { recognitionSamples = Array(rawHistory[lower..<upper]) }
        }
        onSegment?(AudioSegment(id: activeID!, revision: revision, isFinal: final,
            samples: recognitionSamples, timestamp: epoch.addingTimeInterval(Double(start) / Double(Self.sampleRate))))
    }

    enum FrontendError: LocalizedError {
        case missingModels, invalidModel(String), initialization
        var errorDescription: String? {
            switch self {
            case .missingModels: "人声处理组件缺失，请完整解压最新版 SimuSub。"
            case .invalidModel(let name): "人声处理组件校验失败（\(name)），请完整解压最新版 SimuSub。"
            case .initialization: "无法启动本地人声检测与增强，请重新打开应用。"
            }
        }
    }
}
