import AppKit
import AVFoundation

@MainActor
enum ClipMaskRenderChecks {
    static func run(directory: URL, fixture: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ name: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + name) }
            checks.append(name)
        }
        func near(_ value: NSColor?, _ hex: String, alpha: CGFloat = 1, tolerance: CGFloat = 0.01) -> Bool {
            guard let actual = value?.usingColorSpace(.sRGB) else { return false }
            let expected = NSColor.clipHex(hex)
            return abs(actual.redComponent - expected.redComponent) <= tolerance &&
                abs(actual.greenComponent - expected.greenComponent) <= tolerance &&
                abs(actual.blueComponent - expected.blueComponent) <= tolerance &&
                abs(actual.alphaComponent - alpha) <= tolerance
        }
        let legacy = Data(##"{"x":0.5,"y":0.5,"width":0.5,"height":0.5,"opacity":1,"color":"#BEDDF4","enabled":true}"##.utf8)
        var mask = try JSONDecoder().decode(ClipSubtitleMask.self, from: legacy)
        try require(mask.valid && mask.borderWidth == nil && mask.borderColor == nil, "legacy_mask_loads_without_border")
        mask.borderWidth = 12
        mask.borderColor = "#25B756"
        mask.opacity = 0.5
        var style = ClipSubtitleStyle.classic
        style.mask = mask
        let saved = try JSONDecoder().decode(ClipSubtitleStyle.self, from: JSONEncoder().encode(style))
        try require(saved.mask == mask, "mask_border_and_fill_persist_independently")
        let coordinator = ClipStyledPlayer.Coordinator()
        let image = ClipStyledPlayer.PositionView()
        coordinator.image = image
        let player = AVPlayer()
        for width in [640, 1280] {
            let size = CGSize(width: width, height: width * 9 / 16)
            func preview(_ mask: ClipSubtitleMask) throws -> NSBitmapImageRep {
                var draft = saved
                draft.mask = mask
                coordinator.configure(ClipStyledPlayer(player: player, captions: [], style: draft, mediaSize: size))
                guard let cg = image.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ClipError.message("Missing mask preview") }
                return NSBitmapImageRep(cgImage: cg)
            }
            let rect = ClipSubtitleRenderer.maskRect(size: size, mask: mask)
            let x = Int(rect.minX), midY = Int(size.height / 2), border = width / 160
            let observed = try preview(mask)
            try require(near(observed.colorAt(x: x + border - 1, y: midY), "#25B756") &&
                        near(observed.colorAt(x: x + border, y: midY), "#BEDDF4", alpha: 0.5), "mask_inside_border_scales_with_video_\(width)")
            try require(observed.colorAt(x: x, y: Int(rect.minY))!.alphaComponent < 0.1 &&
                        observed.colorAt(x: x - 1, y: midY)!.alphaComponent == 0, "mask_border_respects_rounded_outer_bounds_\(width)")
            var changed = mask
            changed.opacity = 0
            let emptyFill = try preview(changed)
            try require(near(emptyFill.colorAt(x: x + 1, y: midY), "#25B756") &&
                        emptyFill.colorAt(x: x + border + 1, y: midY)!.alphaComponent == 0, "transparent_fill_keeps_opaque_mask_border_\(width)")
            changed.borderColor = nil
            let black = try preview(changed)
            try require(near(black.colorAt(x: x + 1, y: midY), "#000000"), "mask_border_defaults_to_black_\(width)")
            changed.enabled = false
            let hidden = try preview(changed)
            try require(hidden.colorAt(x: x + 1, y: midY)!.alphaComponent == 0, "disabled_mask_hides_border_\(width)")
            changed = mask
            changed.borderWidth = 0
            let fillOnly = try preview(changed)
            try require(near(fillOnly.colorAt(x: x + 1, y: midY), "#BEDDF4", alpha: 0.5), "zero_mask_border_reveals_fill_\(width)")
        }
        coordinator.stop()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("border-" + UUID().uuidString + ".mp4")
        var opaque = style
        opaque.mask?.opacity = 1
        try await ClipMediaEngine.burn(input: fixture, output: output, captions: [], style: opaque)
        let decoder = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let frame = try decoder.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        let pixels = NSBitmapImageRep(cgImage: frame)
        try require(near(pixels.colorAt(x: frame.width / 4 + 1, y: frame.height / 2), "#25B756", tolerance: 0.18) &&
                    near(pixels.colorAt(x: frame.width / 2, y: frame.height / 2), "#BEDDF4", tolerance: 0.14),
                    "exported_video_retains_distinct_mask_border_and_fill")
        return checks
    }
}
