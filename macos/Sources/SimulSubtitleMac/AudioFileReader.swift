import AVFoundation
import Foundation

enum AudioFileReader {
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= AVAudioFramePosition(file.processingFormat.sampleRate * 600) else {
            throw AudioFileError.duration
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else { throw AudioFileError.format }
        try file.read(into: source)
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * 16_000 / source.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { throw AudioFileError.format }
        var consumed = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let error { throw error }
        guard result != .error, let samples = output.floatChannelData?[0], output.frameLength > 0 else { throw AudioFileError.format }
        return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
    }
}

enum AudioFileError: LocalizedError {
    case duration, format
    var errorDescription: String? {
        switch self {
        case .duration: "请选择非空且不超过 10 分钟的音频文件"
        case .format: "无法读取该音频格式，请使用 WAV、M4A 或 AIFF"
        }
    }
}
