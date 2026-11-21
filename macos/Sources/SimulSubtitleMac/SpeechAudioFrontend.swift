import CryptoKit
import Foundation
import SherpaOnnx
import SherpaOnnxC

struct SubtitleProcessingOptions: Equatable, Sendable {
    var suppressMusic = true
    var showDrafts = true
    var preserveOriginal = true
    var stableCadence = false
    var endpointSilence: Float = 0.72
    var liveEnglishToChinese = false
    var japanesePhraseBoundaries = false
    var japaneseClipContext = false
    var cloudJapaneseClip = false
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
    // Decoder-only context, outside the time range owned by this cue.
    var quietRecognitionTail: [Float] = []
    var detectedSpeechRange: Range<Int>? = nil
    var continuesForcedWindow: UUID? = nil
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
    private let lock = NSCondition()
    private var items: [Item] = []
    private var closed = false
    private let capacity: Int
    private let finalsFirst: Bool

    init(capacity: Int = 24, finalsFirst: Bool = false) {
        self.capacity = max(1, capacity)
        self.finalsFirst = finalsFirst
        var sink: AsyncStream<Void>.Continuation!
        wakeups = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { sink = $0 }
        continuation = sink
    }

    func offer(_ item: Item) -> Offer {
        lock.lock()
        defer { lock.unlock() }
        return offerLocked(item)
    }

    /// The audio callback has one serial producer; the translation producer is
    /// the serial ASR worker. Never call this waiting path on the main actor.
    func offerPreservingFinal(_ item: Item, onFull: () -> Void) -> Offer {
        lock.lock()
        defer { lock.unlock() }
        var signaled = false
        while true {
            let outcome = offerLocked(item)
            guard case .overflow = outcome, item.isFinal else { return outcome }
            if !signaled {
                signaled = true
                lock.unlock()
                onFull()
                lock.lock()
            } else { lock.wait() }
        }
    }

    private func offerLocked(_ item: Item) -> Offer {
        guard !closed else { return .obsolete }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            guard item.revision > items[index].revision,
                  !items[index].isFinal || item.isFinal else { return .obsolete }
            items[index] = item
        } else {
            if items.count >= capacity {
                guard item.isFinal else { return .obsolete }
                guard let draft = items.firstIndex(where: { !$0.isFinal }) else { return .overflow }
                items.remove(at: draft)
            }
            items.append(item)
        }
        continuation.yield(())
        return .accepted
    }

    var pendingCount: Int { lock.withLock { items.count } }
    func canCoalescePreview(for id: UUID) -> Bool {
        lock.withLock { !closed && items.allSatisfy { $0.id == id && !$0.isFinal } }
    }
    func take() -> Item? {
        lock.withLock {
            guard !items.isEmpty else { return nil }
            let index = finalsFirst ? items.firstIndex(where: \.isFinal) ?? 0 : 0
            let item = items.remove(at: index)
            lock.broadcast()
            return item
        }
    }
    func discardPending() { lock.withLock { items.removeAll(); lock.broadcast() } }
    func finish() {
        lock.withLock { closed = true; lock.broadcast() }
        continuation.yield(())
        continuation.finish()
    }
}

/// Select a physical sample boundary before feeding the following audio to Silero.
struct EnglishAudioEndpoint {
    static let frame = 512
    static let lookahead = 20 * frame       // 640 ms, only near the hard limit
    static let searchStart = 84_000         // 5.25 s at 16 kHz
    private var recentPeak: Float = 0
    private var quietFrames = 0
    private var deepQuietSubframes = 0

    enum Pause { case beforeFrame, afterFrame }

    mutating func pause(in frame: [Float], duration: Int) -> Pause? {
        // Look inside a Silero frame: a word onset in its last 8 ms must not
        // erase the preceding inter-sentence pause or be attached to the old cue.
        let powers = stride(from: 0, to: frame.count, by: 128).map { start in
            frame[start..<(start + 128)].reduce(Float.zero) { $0 + $1 * $1 } / 128
        }
        let power = powers.reduce(0, +) / 4
        recentPeak = max(power, recentPeak * 0.96)
        quietFrames = power <= max(0.000003, recentPeak * 0.025) ? quietFrames + 1 : 0
        var longest = 0
        for level in powers {
            deepQuietSubframes = level <= max(0.0000007, recentPeak * 0.0003) ? deepQuietSubframes + 1 : 0
            longest = max(longest, deepQuietSubframes)
        }
        if duration >= 44_800, longest >= 7 {
            return deepQuietSubframes == 0 ? .beforeFrame : .afterFrame
        }
        return duration >= 64_000 && quietFrames >= 3 ? .afterFrame : nil
    }

    // Consider 32 ms of acoustic context on either side of every candidate.
    // The split itself is frame aligned; no overlap is passed to the recognizer.
    static func quietestOffset(in samples: ArraySlice<Float>) -> Int {
        var bestOffset = frame
        var lowest = Float.infinity
        var previous: Float = 0
        // Leave at least 192 ms for Silero to detect the following word.
        for start in stride(from: 0, through: lookahead - 6 * frame, by: frame) {
            let index = samples.startIndex + start
            let power = samples[index..<(index + frame)].reduce(Float.zero) { $0 + $1 * $1 }
            if start > 0, previous + power < lowest {
                lowest = previous + power
                bestOffset = start
            }
            previous = power
        }
        return bestOffset
    }
}

/// Under accompaniment Silero can report one continuous stretch of singing.
/// Choose a dip between vocal peaks while the detector continues listening.
enum JapanesePhraseEndpoint {
    static let window = 7 * 16_000

    static func boundary(in phrase: ArraySlice<Float>) -> Int? {
        guard phrase.count >= window else { return nil }
        let frame = 512
        let first = phrase.startIndex + 5 * 16_000
        let end = phrase.startIndex + window - frame
        var boundary = first + frame
        var lowestPower = Float.infinity
        var previousPower = Float.infinity
        // Average both sides of the boundary so a single zero crossing doesn't
        // split a sustained vowel. Keep the remaining frames for the next cue.
        for start in stride(from: first, through: end, by: frame) {
            let power = phrase[start..<(start + frame)].reduce(Float.zero) { $0 + $1 * $1 }
            if previousPower + power < lowestPower {
                lowestPower = previousPower + power
                boundary = start
            }
            previousPower = power
        }
        return boundary - phrase.startIndex
    }
}

/// Only explicit ASR music annotations extend the next few English windows.
/// Expiry follows captured audio even if the user pauses or the screen locks.
struct EnglishVocalCadence {
    private var expiresAt = 0
    static let holdSeconds = 28.0
    static let musicSearchStart = 148_000  // 9.25 seconds plus bounded lookahead
    mutating func observe(at sample: Int) { expiresAt = sample + Int(Self.holdSeconds) * SpeechAudioFrontend.sampleRate }
    func active(at sample: Int) -> Bool { sample < expiresAt }
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
    private var vadActiveStart = 0
    private var revision = 0
    private var lastDraftSample = 0
    private var emittedDraftRange: Range<Int>?
    private var lastFinalEnd = 0
    private var forcedWindow: (id: UUID, end: Int)?
    private var englishEndpoint = EnglishAudioEndpoint()
    private var vocalCadence = EnglishVocalCadence()
    private var recentInputPeak: Float = 0
    private var normalLevelHold = 0
    private var quietSignalSamples = 0
    private var scheduledCut: Int?
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
            model: vadPath, threshold: options.cloudJapaneseClip ? 0.19 : 0.60, minSilenceDuration: options.liveEnglishToChinese ? 0.44 : options.endpointSilence,
            minSpeechDuration: options.cloudJapaneseClip ? 0.096 : 0.18, windowSize: 512, maxSpeechDuration: options.cloudJapaneseClip ? 6 : 20), numThreads: 1)
        guard let detector = SherpaOnnxCreateVoiceActivityDetector(&config, 32) else { throw FrontendError.initialization }
        vad = detector
    }

    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    func begin(at date: Date) { epoch = date }

    private var keepsRawAudio: Bool { options.preserveOriginal && (denoiser != nil || options.liveEnglishToChinese) }

    func accept(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        if keepsRawAudio { rawHistory.append(contentsOf: samples) }
        var detectionInput = samples
        if options.liveEnglishToChinese {
            // Quiet sources can lose whole clauses in GTCRN/Silero before ASR sees
            // them. Retain a decaying peak so word pauses in loud audio stay quiet.
            let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
            let release = exp(-Double(samples.count) / (2 * Double(Self.sampleRate)))
            recentInputPeak = max(peak, recentInputPeak * Float(release))
            // Never raise normal-level speech just because the latest syllable is
            // quiet. Require sustained low-level signal before conditioning, and
            // keep normal input untouched throughout ordinary pauses.
            if peak >= 0.055 {
                normalLevelHold = 12 * Self.sampleRate
                quietSignalSamples = 0
            } else if normalLevelHold > 0 {
                normalLevelHold = max(0, normalLevelHold - samples.count)
            } else if peak > 0.003 {
                quietSignalSamples = min(Self.sampleRate, quietSignalSamples + samples.count)
            }
            if normalLevelHold == 0, quietSignalSamples >= Self.sampleRate / 4,
               recentInputPeak > 0.001, recentInputPeak < 0.055 {
                let gain = min(12, 0.15 / recentInputPeak)
                detectionInput = samples.map { $0 * gain }
            }
        }
        consume(denoiser?.run(samples: detectionInput, sampleRate: Self.sampleRate).samples ?? detectionInput)
    }

    func finish() {
        if let denoiser { consume(denoiser.flush().samples) }
        let remainder = pending.count % 512
        let padding = remainder == 0 ? 0 : 512 - remainder
        consume([Float](repeating: 0, count: padding), finishing: true)
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        drainCompleted()
    }

    static func draftInterval(for duration: Int) -> Int {
        // Offline ASR re-decodes the entire growing sentence; bound redundant work.
        min(64_000, max(24_000, duration / 3))
    }

    func noteEnglishMusic() {
        guard options.liveEnglishToChinese else { return }
        if !vocalCadence.active(at: processed) {
            scheduledCut = nil
            englishEndpoint = EnglishAudioEndpoint()
        }
        vocalCadence.observe(at: processed)
    }

    private func consume(_ samples: [Float], finishing: Bool = false) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= 512 {
            let vocalWindow = vocalCadence.active(at: processed)
            let searchStart = vocalWindow ? EnglishVocalCadence.musicSearchStart : EnglishAudioEndpoint.searchStart
            if options.liveEnglishToChinese, activeID != nil, scheduledCut == nil,
               processed - activeStart >= searchStart {
                let available = pending.count - offset
                if available >= EnglishAudioEndpoint.lookahead {
                    scheduledCut = processed + EnglishAudioEndpoint.quietestOffset(in: pending[offset...])
                } else if !finishing {
                    break
                }
            }
            let frame = Array(pending[offset..<offset + 512])
            offset += 512
            let pause = options.liveEnglishToChinese && !vocalWindow && activeID != nil
                ? englishEndpoint.pause(in: frame, duration: processed + 512 - activeStart) : nil
            if pause == .beforeFrame {
                SherpaOnnxVoiceActivityDetectorFlush(vad)
                drainCompleted()
            }
            history.append(contentsOf: frame)
            processed += 512
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, frame, 512)
            drainCompleted(natural: true)
            if SherpaOnnxVoiceActivityDetectorDetected(vad) == 1 {
                if activeID == nil {
                    activeID = UUID()
                    activeStart = max(lastFinalEnd, max(historyStart, processed - 8_000))
                    vadActiveStart = activeStart
                    revision = 0
                    emittedDraftRange = nil
                    lastDraftSample = activeStart
                }
                let duration = processed - activeStart
                if (options.liveEnglishToChinese && (pause == .afterFrame || scheduledCut == processed))
                    || processed - vadActiveStart >= 24 * Self.sampleRate {
                    let forced = processed - vadActiveStart >= 24 * Self.sampleRate
                    SherpaOnnxVoiceActivityDetectorFlush(vad)
                    drainCompleted(forcedEnd: forced)
                } else if options.japanesePhraseBoundaries, duration >= JapanesePhraseEndpoint.window {
                    let start = activeStart - historyStart
                    if let count = JapanesePhraseEndpoint.boundary(in: history[start...]) {
                        emit(Array(history[start..<(start + count)]), start: activeStart, final: true)
                        // Keep the VAD running: resetting it here would require
                        // redetecting the next syllable over the accompaniment.
                        activeStart += count
                        activeID = UUID()
                        revision = 0
                        emittedDraftRange = nil
                        lastDraftSample = activeStart
                    }
                } else if options.showDrafts && processed - lastDraftSample >= (options.stableCadence ? min(32_000, max(16_000, duration / 4)) : Self.draftInterval(for: duration)) {
                    let start = max(0, activeStart - historyStart)
                    emit(Array(history.dropFirst(start)), start: activeStart, final: false)
                    lastDraftSample = processed
                }
            }
            // Keep pre-roll for the VAD start, which can precede draft activation.
            let retainFrom = activeID == nil ? processed - 32_000 : activeStart - 32_000
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

    private func drainCompleted(natural: Bool = false, forcedEnd: Bool = false) {
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            if let speech = SherpaOnnxVoiceActivityDetectorFront(vad) {
                let count = Int(speech.pointee.n)
                if count >= (options.cloudJapaneseClip ? 1_536 : 2_880), let data = speech.pointee.samples {
                    let vadSamples = Array(UnsafeBufferPointer(start: data, count: count))
                    let vadStart = Int(speech.pointee.start)
                    let vadEnd = vadStart + count
                    let covered = Self.finalRange(vad: vadStart..<vadEnd, draft: emittedDraftRange)
                    let start = options.liveEnglishToChinese || options.japanesePhraseBoundaries
                        ? max(lastFinalEnd, covered.lowerBound) : covered.lowerBound
                    var range = min(start, covered.upperBound)..<covered.upperBound
                    // Continuous speech already has both phonetic context and
                    // long-utterance gap recovery. Expand isolated short turns only.
                    if options.cloudJapaneseClip {
                        // Detection runs on raw PCM here. Keep a little real audio on
                        // both sides of weak syllables, without reusing an owned frame.
                        range = Self.contextualRange(range, previousEnd: lastFinalEnd,
                            available: historyStart..<(historyStart + history.count), processed: processed)
                    } else if options.japaneseClipContext, covered.count < 6 * Self.sampleRate {
                        range = Self.contextualRange(range, previousEnd: lastFinalEnd, available: rawHistoryStart..<(rawHistoryStart + rawHistory.count), processed: processed)
                    }
                    // A VAD preroll can reach into the preceding final's draft tail.
                    // Copy only this cue's samples, preserving physical ownership.
                    var complete = [Float](repeating: 0, count: range.count)
                    let speechStart = max(range.lowerBound, vadStart)
                    let speechEnd = min(range.upperBound, vadEnd)
                    if speechStart < speechEnd {
                        complete.replaceSubrange((speechStart - range.lowerBound)..<(speechEnd - range.lowerBound),
                                                 with: vadSamples[(speechStart - vadStart)..<(speechEnd - vadStart)])
                    }
                    let lower = max(range.lowerBound, historyStart)
                    let upper = min(range.upperBound, historyStart + history.count)
                    if upper > lower {
                        complete.replaceSubrange((lower - range.lowerBound)..<(upper - range.lowerBound),
                            with: history[(lower - historyStart)..<(upper - historyStart)])
                    }
                    var quietTail: [Float] = []
                    if natural, options.liveEnglishToChinese, normalLevelHold == 0,
                       quietSignalSamples >= Self.sampleRate / 4, recentInputPeak < 0.055 {
                        quietTail = Self.quietTail(in: rawHistory, endingAt: range.upperBound - rawHistoryStart,
                                                   processed: processed - rawHistoryStart,
                                                   cueLength: range.count)
                    }
                    let core = covered.clamped(to: range)
                    let detected = range == core ? nil : (core.lowerBound - range.lowerBound)..<(core.upperBound - range.lowerBound)
                    emit(complete, start: range.lowerBound, final: true, quietTail: quietTail, detected: options.japaneseClipContext ? detected : nil, forcedEnd: forcedEnd && abs(range.upperBound - processed) <= 512)
                }
                SherpaOnnxDestroySpeechSegment(speech)
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
            englishEndpoint = EnglishAudioEndpoint()
            scheduledCut = nil
            activeID = nil
            emittedDraftRange = nil
            revision = 0
        }
    }

    // A natural endpoint is confirmed after observing silence. The original
    // waveform around that decision often still contains quiet initial or final morae.
    static func contextualRange(_ speech: Range<Int>, previousEnd: Int, available: Range<Int>, processed: Int) -> Range<Int> {
        let first = max(previousEnd, max(available.lowerBound, speech.lowerBound - 4_480))
        let last = min(processed, min(available.upperBound, speech.upperBound + 5_120))
        return min(first, last)..<last
    }

    static func finalRange(vad: Range<Int>, draft: Range<Int>?) -> Range<Int> {
        guard let draft else { return vad }
        return min(vad.lowerBound, draft.lowerBound)..<max(vad.upperBound, draft.upperBound)
    }

    static func originalSamples(fallback: [Float], start: Int, raw: [Float], rawStart: Int) -> [Float] {
        var result = fallback
        let lower = max(start, rawStart)
        let upper = min(start + fallback.count, rawStart + raw.count)
        if upper > lower {
            result.replaceSubrange((lower - start)..<(upper - start), with: raw[(lower - rawStart)..<(upper - rawStart)])
        }
        return result
    }

    /// Silero reports its natural endpoint after observing 440 ms of low activity.
    /// Whisper can discard part of a quiet word near this boundary. Reuse 320 ms
    /// of already observed room sound only when it stays weak against this cue.
    static func quietTail(in raw: [Float], endingAt end: Int, processed: Int, cueLength: Int) -> [Float] {
        let length = 5_120, history = 8_000
        guard cueLength >= history, end >= history, end + length <= min(processed, raw.count) else { return [] }
        func peakFramePower(_ range: Range<Int>) -> Float {
            var peak: Float = 0
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 512) {
                let frame = raw[i..<min(i + 512, range.upperBound)]
                peak = max(peak, frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count))
            }
            return peak
        }
        let tail = end..<(end + length)
        // Each 32 ms frame must be below -60 dBFS and 20% of recent speech RMS.
        let speechPower = peakFramePower((end-history)..<end)
        guard speechPower > 0, peakFramePower(tail) <= min(0.000001, 0.04 * speechPower) else { return [] }
        return Array(raw[tail])
    }

    private func emit(_ samples: [Float], start: Int, final: Bool, quietTail: [Float] = [], detected: Range<Int>? = nil, forcedEnd: Bool = false) {
        guard !samples.isEmpty else { return }
        if activeID == nil { activeID = UUID() }
        revision += 1
        var recognitionSamples = samples
        if keepsRawAudio {
            recognitionSamples = Self.originalSamples(fallback: samples, start: start, raw: rawHistory, rawStart: rawHistoryStart)
        }
        let predecessor = forcedWindow.flatMap { abs(start - $0.end) <= 512 ? $0.id : nil }
        if !final { emittedDraftRange = start..<(start + recognitionSamples.count) }
        else {
            lastFinalEnd = start + recognitionSamples.count
            forcedWindow = forcedEnd ? (activeID!, lastFinalEnd) : nil
        }
        onSegment?(AudioSegment(id: activeID!, revision: revision, isFinal: final,
            samples: recognitionSamples, timestamp: epoch.addingTimeInterval(Double(start) / Double(Self.sampleRate)),
            quietRecognitionTail: quietTail, detectedSpeechRange: detected, continuesForcedWindow: predecessor))
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
