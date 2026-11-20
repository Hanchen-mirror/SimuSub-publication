import AVFoundation
import CryptoKit
import Foundation

enum ClipPlaybackSource {
    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimuSub/ClipPlayback", isDirectory: true)
    }

    // The project always points at its source. Only the player receives this URL.
    static func resolve(_ media: ClipMedia, cache: URL = cache, rebuild: Bool = false) async throws -> URL {
        try media.validateFile()
        if !rebuild, await playable(media.url, media: media) { return media.url }
        try Task.checkCancellation()
        let files = FileManager.default
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        let destination = cachedURL(for: media, in: cache)
        if !rebuild, files.fileExists(atPath: destination.path), await playable(destination, media: media) { return destination }

        let probe = try await ClipMediaEngine.probe(media.url)
        let video = probe.streams.first { $0.codec_type == "video" }?.codec_name
        let audio = probe.streams.first { $0.codec_type == "audio" }?.codec_name
        let temporary = cache.appendingPathComponent("." + UUID().uuidString + ".mp4")
        defer { try? files.removeItem(at: temporary) }
        let input = ["-nostdin", "-hide_banner", "-v", "error", "-y", "-protocol_whitelist", "file,crypto", "-i", media.path,
                     "-map", "0:v:0", "-map", "0:a:0?", "-map_chapters", "-1", "-map_metadata", "-1"]
        let output = ["-movflags", "+faststart", temporary.path]
        let timeout = max(120, media.duration * 5)
        var copied = false
        if video == "h264" || video == "hevc" {
            var codecs = ["-c:v", "copy"]
            if video == "hevc" { codecs += ["-tag:v", "hvc1"] }
            codecs += audio == "aac" ? ["-c:a", "copy"] : ["-c:a", "aac", "-ac", "2", "-b:a", "160k"]
            let result = try await LiveTools.run("ffmpeg", arguments: input + codecs + output, timeout: timeout)
            if result.status == 0 { copied = await playable(temporary, media: media) }
        }
        try Task.checkCancellation()
        if !copied {
            let codecs = ["-vf", "scale=w='min(1280,iw)':h='min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2",
                          "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "2500k", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-b:a", "160k", "-ac", "2"]
            let result = try await LiveTools.run("ffmpeg", arguments: input + codecs + output, timeout: timeout)
            guard result.status == 0 else { throw ClipFailure.tool(result.error, operation: "准备视频播放") }
            guard await playable(temporary, media: media) else { throw ClipFailure.tool("invalid data", operation: "准备视频播放") }
        }
        try Task.checkCancellation()
        try media.validateFile()
        // Both names use the same cache volume; concurrent editors see only complete MP4 files.
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return destination
    }

    static func cachedURL(for media: ClipMedia, in directory: URL = cache) -> URL {
        let key = Data("v1\n\(media.path)\n\(media.bytes)\n\(media.modified.bitPattern)".utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".mp4")
    }

    private static func playable(_ url: URL, media: ClipMedia) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable),
                  let video = try await asset.loadTracks(withMediaType: .video).first, try await video.load(.isPlayable),
                  abs(try await asset.load(.duration).seconds - media.duration) < max(1, media.duration * 0.0001) else { return false }
            if media.hasAudio {
                guard let audio = try await asset.loadTracks(withMediaType: .audio).first, try await audio.load(.isPlayable) else { return false }
            }
            // Containers with unsupported video sometimes expose a playable audio track.
            _ = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
            return true
        } catch { return false }
    }
}
