import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit
import AppKit

struct CaptureApplication: Identifiable, Hashable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let name: String
    var processID: pid_t = 0
    var windowID: CGWindowID? = nil
}

// Audio buffer mutation is confined to `queue`; start/stop are serialized by AppModel.
final class AudioCaptureEngine: NSObject, AudioCapturing, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onSegment: ((CapturedAudioSegment) -> Void)?
    var processingOptions = SubtitleProcessingOptions()
    private var systemStream: SCStream?
    private let queue = DispatchQueue(label: "simul-subtitle.audio-buffer")
    private var frontend: SpeechAudioFrontend?
    private var stopping = false
    private var captureEpoch = Date()
    private var receivedSamples = 0

    @MainActor
    static func availableApplications() async throws -> [CaptureApplication] {
        let content = try await shareableContent()
        let applications = content.applications.filter {
            !$0.applicationName.isEmpty && !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && NSRunningApplication(processIdentifier: $0.processID)?.activationPolicy == .regular
        }
        return Dictionary(grouping: applications, by: \.bundleIdentifier).compactMap { _, group in
            guard let app = group.first else { return nil }
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == app.bundleIdentifier && $0.windowLayer == 0
                    && $0.frame.width >= 160 && $0.frame.height >= 90
            }.sorted {
                if $0.isOnScreen != $1.isOnScreen { return $0.isOnScreen }
                return $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height
            }
            guard let window = windows.first else { return nil }
            return CaptureApplication(bundleIdentifier: app.bundleIdentifier, name: app.applicationName,
                                      processID: app.processID, windowID: window.windowID)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(selectedBundleID: String, generation: UUID) async throws {
        let options = processingOptions
        let processor = try await Task.detached { try SpeechAudioFrontend(options: options) }.value
        queue.sync {
            stopping = false
            captureEpoch = Date()
            receivedSamples = 0
            frontend = processor
            processor.begin(at: captureEpoch)
            processor.onSegment = { [weak self] in self?.onSegment?(.init(audio: $0, generation: generation)) }
        }
        try await startSystemAudio(for: selectedBundleID)
    }

    /// Drop the old utterance without emitting its tail, retaining the selected
    /// app stream and sample clock. In-flight outputs keep their old generation.
    func discardBufferedAudio(generation: UUID) async throws {
        let options = processingOptions
        let processor = try await Task.detached { try SpeechAudioFrontend(options: options) }.value
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !stopping, frontend != nil {
                    processor.begin(at: captureEpoch.addingTimeInterval(Double(receivedSamples) / 16_000))
                    processor.onSegment = { [weak self] in self?.onSegment?(.init(audio: $0, generation: generation)) }
                    frontend = processor
                }
                continuation.resume()
            }
        }
    }

    func stop() async {
        if let systemStream { try? await systemStream.stopCapture() }
        systemStream = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stopping = true
                frontend?.finish()
                frontend = nil
                continuation.resume()
            }
        }
    }

    private func startSystemAudio(for bundleID: String) async throws {
        let content = try await Self.shareableContent()
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }
        guard content.applications.contains(where: { $0.bundleIdentifier == bundleID }) else { throw AudioCaptureError.applicationUnavailable }
        let excluded = content.applications.filter { $0.bundleIdentifier != bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // ScreenCaptureKit also delivers display frames for this filter. Discard them in the callback.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        systemStream = stream
        try await stream.startCapture()
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let error { continuation.resume(throwing: error) }
                else if let content { continuation.resume(returning: content) }
                else { continuation.resume(throwing: AudioCaptureError.noShareableContent) }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, let pcm = Self.floatSamples(sampleBuffer) else { return }
        append(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }

    var onError: ((Error) -> Void)?

    private func append(_ chunk: [Float]) {
        // ScreenCaptureKit invokes the audio callback on this queue already.
        guard !stopping else { return }
        frontend?.accept(chunk)
        receivedSamples += chunk.count
    }

    static func floatSamples(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        guard count > 0 else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        // Capacity alone leaves each AudioBuffer's mDataByteSize at zero. CoreMedia rejects that destination.
        pcm.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList) == noErr else { return nil }
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }
        if let floats = pcm.floatChannelData {
            return (0..<count).map { frame in
                (0..<channels).reduce(Float.zero) { $0 + floats[format.isInterleaved ? 0 : $1][format.isInterleaved ? frame * channels + $1 : frame] } / Float(channels)
            }
        }
        if let ints = pcm.int16ChannelData {
            return (0..<count).map { frame in
                (0..<channels).reduce(Float.zero) { $0 + Float(ints[format.isInterleaved ? 0 : $1][format.isInterleaved ? frame * channels + $1 : frame]) / Float(Int16.max) } / Float(channels)
            }
        }
        return nil
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case applicationNotSelected
    case applicationUnavailable
    case noDisplay
    case noShareableContent

    var errorDescription: String? {
        switch self {
        case .applicationNotSelected: "请先选择要采集的应用"
        case .applicationUnavailable: "所选应用当前未运行"
        case .noDisplay: "系统没有可捕获的显示器"
        case .noShareableContent: "无法读取可捕获的应用列表"
        }
    }
}
