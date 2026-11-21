import Foundation
import AVFoundation
import Darwin

enum ClipMP3 {
    static func export(media: ClipMedia, range: ClipRange, output: URL) async throws {
        try media.validateFile(); try range.validateForExport(duration: media.duration)
        guard media.hasAudio else { throw ClipError.message("这个视频没有音轨，无法导出 MP3。") }
        try LiveRecordingEngine.checkSpace(output.deletingLastPathComponent(), minimum: 250_000_000)
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("simusub-mp3-" + UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let r = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-n", "-protocol_whitelist", "file,crypto", "-ss", String(range.start), "-i", media.path,
            "-t", String(range.duration), "-vn", "-map", "0:a:0", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", wav.path], timeout: max(120, range.duration * 2))
        guard r.status == 0 else { throw ClipFailure.tool(r.error, operation: "读取 MP3 音轨") }
        try Task.checkCancellation()
        try encode(wav: wav, output: output, duration: range.duration)
        let probe = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-show_entries", "format=duration:stream=codec_name", "-of", "json", output.path])
        struct Probe: Decodable { struct Stream: Decodable { var codec_name: String }; struct Format: Decodable { var duration: String }; var streams: [Stream]; var format: Format }
        guard probe.status == 0, let result = try? JSONDecoder().decode(Probe.self, from: probe.data),
              result.streams.first?.codec_name == "mp3", let duration = Double(result.format.duration), abs(duration - range.duration) < 0.3 else {
            throw ClipError.message("MP3 时长或编码校验未通过，请重试。")
        }
    }
    private static func encode(wav: URL, output: URL, duration: Double) throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libmp3lame.0.dylib")
        guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw ClipError.message("MP3 编码组件缺失，请完整解压应用。") }
        defer { dlclose(library) }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw ClipError.message("MP3 编码组件不完整：" + name) }
            return unsafeBitCast(pointer, to: type)
        }
        typealias Init = @convention(c) () -> OpaquePointer?
        typealias Set = @convention(c) (OpaquePointer?, Int32) -> Int32
        typealias Finish = @convention(c) (OpaquePointer?) -> Int32
        typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
        typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
        let initialize = try symbol("lame_init", Init.self), close = try symbol("lame_close", Finish.self)
        guard let encoder = initialize() else { throw ClipError.message("无法启动 MP3 编码器。") }
        defer { _ = close(encoder) }
        for (key, value): (String, Int32) in [("lame_set_in_samplerate", 44100), ("lame_set_num_channels", 2), ("lame_set_brate", 192), ("lame_set_quality", 2)] {
            guard try symbol(key, Set.self)(encoder, value) == 0 else { throw ClipError.message("MP3 参数初始化失败。") }
        }
        // Streaming output omits a seek-dependent Xing header. The final file is
        // independently probed for actual codec and duration before publishing.
        _ = try symbol("lame_set_bWriteVbrTag", Set.self)(encoder, 0)
        guard try symbol("lame_init_params", Finish.self)(encoder) == 0 else { throw ClipError.message("MP3 参数初始化失败。") }
        let encode = try symbol("lame_encode_buffer_ieee_float", Encode.self), flush = try symbol("lame_encode_flush", Flush.self)
        let audio = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192) else { throw ClipError.message("无法分配音频缓冲。") }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ClipError.message("无法创建 MP3 文件。") }
        let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
        var bytes = [UInt8](repeating: 0, count: 20000)
        let targetFrames = Int64((duration * 44100).rounded())
        var writtenFrames: Int64 = 0
        while writtenFrames < targetFrames {
            try Task.checkCancellation()
            let wanted = AVAudioFrameCount(min(8192, targetFrames - writtenFrames))
            pcm.frameLength = 0
            if audio.framePosition < audio.length { try audio.read(into: pcm, frameCount: wanted) }
            guard let channels = pcm.floatChannelData else { throw ClipError.message("无法读取音频采样。") }
            // Video may outlast its audio stream. Preserve the selected clock
            // by filling the remainder with silence rather than shortening MP3.
            for channel in 0..<2 {
                let from = Int(pcm.frameLength)
                if from < Int(wanted) { channels[channel].advanced(by: from).update(repeating: 0, count: Int(wanted) - from) }
            }
            let count = encode(encoder, channels[0], channels[1], Int32(wanted), &bytes, Int32(bytes.count))
            writtenFrames += Int64(wanted)
            guard count >= 0 else { throw ClipError.message("MP3 编码失败。") }
            try file.write(contentsOf: Data(bytes.prefix(Int(count))))
        }
        let count = flush(encoder, &bytes, Int32(bytes.count))
        guard count >= 0 else { throw ClipError.message("MP3 文件收尾失败。") }
        try file.write(contentsOf: Data(bytes.prefix(Int(count)))); try file.synchronize()
    }
}
