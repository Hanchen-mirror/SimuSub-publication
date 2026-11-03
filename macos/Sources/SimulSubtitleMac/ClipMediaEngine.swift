import AppKit
import AVFoundation
import CoreImage
import CoreText

/// Every decoder input is a local user-chosen file. External playlist protocols
/// are disabled, and every output is new, never the source path.
enum ClipMediaEngine {
    private struct Probe: Decodable {
        struct Stream: Decodable { var codec_type: String?; var width: Int?; var height: Int? }
        struct Format: Decodable { var duration: String? }
        var streams: [Stream]; var format: Format?
    }
    static func inspect(_ url: URL) async throws -> ClipMedia {
        guard url.isFileURL else { throw ClipError.message("请选择本机视频文件。") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ClipFailure.tool("no such file", operation: "读取视频") }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ClipFailure.tool("permission denied", operation: "读取视频") }
        let output = try await LiveTools.run("ffprobe", arguments: ["-v", "error", "-protocol_whitelist", "file,crypto", "-show_streams", "-show_format", "-of", "json", url.path], timeout: 30)
        guard output.status == 0 else { throw ClipFailure.tool(output.error, operation: "读取视频") }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: output.data),
              let video = probe.streams.first(where: { $0.codec_type == "video" }),
              let width = video.width, let height = video.height, width >= 16, height >= 16,
              width <= 8192, height <= 8192, let duration = Double(probe.format?.duration ?? ""),
              duration.isFinite, duration > 0, duration <= 48 * 3600 else {
            throw ClipError.message("无法读取这个视频，支持最长 48 小时、8K 以内的常见 MP4 / MKV / MOV / WebM 文件。")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ClipMedia(path: url.path, duration: duration, width: width, height: height,
                         hasAudio: probe.streams.contains { $0.codec_type == "audio" },
                         bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                         modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
    static func poster(media: ClipMedia, output: URL) async throws {
        let r = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-hide_banner", "-v", "error", "-n", "-protocol_whitelist", "file,crypto", "-ss", String(min(0.5, media.duration / 4)), "-i", media.path,
            "-map", "0:v:0", "-an", "-frames:v", "1", "-vf", "scale=640:-2", "-c:v", "png", output.path], timeout: 30)
        guard r.status == 0 else { throw ClipError.message("暂时无法生成封面。") }
    }
    static func extractAudio(media: ClipMedia, start: Double, duration: Double, output: URL) async throws {
        try media.validateFile()
        let r = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-hide_banner", "-v", "error", "-n", "-protocol_whitelist", "file,crypto",
            "-ss", String(start), "-i", media.path, "-t", String(duration), "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path], timeout: 120)
        guard r.status == 0 else { throw ClipFailure.tool(r.error, operation: "读取音轨") }
    }
    static func cut(media: ClipMedia, range: ClipRange, output: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws {
        try media.validateFile(); try range.validate(duration: media.duration)
        try LiveRecordingEngine.checkSpace(output.deletingLastPathComponent(), minimum: max(250_000_000, Int64(range.duration * 1_000_000)))
        let args = ["-nostdin", "-hide_banner", "-v", "error", "-n", "-protocol_whitelist", "file,crypto", "-ss", String(range.start), "-i", media.path,
            "-t", String(range.duration), "-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
            "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", String(min(24_000_000, max(2_000_000, media.width * media.height * 3))), "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", "-map_metadata", "-1", "-map_chapters", "-1", output.path]
        await progress(0.05)
        let result = try await LiveTools.run("ffmpeg", arguments: args, timeout: max(180, range.duration * 5))
        try Task.checkCancellation()
        guard result.status == 0, LiveRecordingEngine.fileSize(output.path) > 0 else {
            throw ClipFailure.tool(result.error, operation: "视频转码")
        }
        await progress(1)
    }
    static func burn(input: URL, output: URL, captions: [Caption], style: ClipSubtitleStyle = .classic, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClipError.message("没有可导出的视频轨道。") }
        let size = try await track.load(.naturalSize)
        let cache = ClipOverlayCache(captions: captions, size: size, style: style)
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let time = request.compositionTime.seconds
            let image = request.sourceImage
            if let overlay = cache.image(at: time) {
                let origin = ClipSubtitleRenderer.origin(size: image.extent.size, overlay: overlay.extent.size, style: style)
                let shifted = overlay.transformed(by: CGAffineTransform(translationX: origin.x + image.extent.minX, y: origin.y + image.extent.minY))
                request.finish(with: shifted.composited(over: image).cropped(to: image.extent), context: nil)
            } else { request.finish(with: image, context: nil) }
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { throw ClipError.message("无法启动字幕视频导出。") }
        exporter.outputURL = output; exporter.outputFileType = .mp4; exporter.videoComposition = composition; exporter.shouldOptimizeForNetworkUse = true
        let cancellation = ClipExportCancellation(exporter)
        try await withTaskCancellationHandler {
            let progressTask = Task {
                while !Task.isCancelled {
                    await progress(Double(exporter.progress))
                    do { try await Task.sleep(nanoseconds: 300_000_000) } catch { break }
                }
            }
            defer { progressTask.cancel() }
            await exporter.export()
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw ClipError.message(ClipFailure.message(exporter.error ?? ClipError.message("编码器未完成字幕合成，请重试。［CLIP-BURN］"), operation: "字幕烧录")) }
            await progress(1)
        } onCancel: { cancellation.cancel() }
    }
}
private final class ClipExportCancellation: @unchecked Sendable {
    let exporter: AVAssetExportSession
    init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    func cancel() { exporter.cancelExport() }
}
/// Bounded per-caption cache shared across AVFoundation composition requests.
private final class ClipOverlayCache: @unchecked Sendable {
    let captions: [Caption]; let size: CGSize; let style: ClipSubtitleStyle
    private let lock = NSLock()
    private var images: [UUID: CIImage] = [:]
    init(captions: [Caption], size: CGSize, style: ClipSubtitleStyle) { self.captions = captions; self.size = size; self.style = style }
    func image(at time: Double) -> CIImage? {
        guard let cue = captions.first(where: { $0.start <= time && time < $0.end }) else { return nil }
        return lock.withLock {
            if let cached = images[cue.id] { return cached }
            guard let rendered = ClipSubtitleRenderer.overlay(cue, size: size, style: style) else { return nil }
            if images.count >= 8 { images.removeAll() }
            let image = CIImage(cgImage: rendered); images[cue.id] = image; return image
        }
    }
}
