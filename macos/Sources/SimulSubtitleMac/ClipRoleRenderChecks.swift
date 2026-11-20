import AppKit
import AVFoundation

/// Exercises inherited assignments in both generated preview and the actual batch exporter.
@MainActor
enum ClipRoleRenderChecks {
    static func run(directory: URL, fixture: URL) async throws -> [String] {
        var checks: [String] = []
        func require(_ condition: Bool, _ description: String) throws {
            guard condition else { throw ClipError.message("CHECK FAILED: " + description) }
            checks.append(description)
        }
        let store = ClipStore(root: directory.appendingPathComponent("store"))
        let id = try await store.importVideo(fixture)
        var base = ClipSubtitleStyle.classic
        base.position = .init(x: 0.5, y: 0.5, width: 0.85)
        base.mask = .init(x: 0.5, y: 0.5, width: 0.96, height: 0.46, color: "#000000")
        var range = ClipRange(title: "角色样式", start: 0.25, end: 2.05)
        range.subtitleStyle = base
        var a = ClipCaptionRole(name: "甲", chinese: .init(size: 104), japanese: .init(size: 72))
        a.chinese.color = "#FF2020"; a.japanese.color = "#FF2020"
        a.chinese.outline = 8; a.chinese.outlineColor = "#20FF20"; a.chinese.shadow = 0
        a.japanese.shadow = 1
        var b = a
        b.id = UUID(); b.name = "乙"; b.chinese.color = "#00E5FF"; b.japanese.color = "#00E5FF"
        var marker = Caption(start: 0, end: 0.2, original: "前", translated: "前")
        marker.clipRoleID = a.id
        let first = Caption(start: 0.25, end: 1.15, original: "SPEAKER", translated: "同一片段")
        var second = first
        second.id = UUID(); second.start = 1.15; second.end = 2.05; second.clipRoleID = b.id
        store.update(id) { $0.ranges = [range]; $0.captions = [marker, first, second]; $0.captionRoles = [a, b] }
        let cues = ClipTime.captions(store.projects[0].styledCaptions(for: range), within: range)
        try require(cues.count == 2 && cues[0].clipRoleID == a.id && cues[1].clipRoleID == b.id, "roles_inherit_across_range_boundary_and_switch_on_marker")
        let inherited = store.projects[0].styledCaptions(for: range, inheritingAt: second.id)
        try require(inherited.last?.clipRoleID == a.id && store.projects[0].captions(for: range).last?.clipRoleID == b.id,
                    "inspector_can_display_inheritance_without_writing_a_role_marker")
        var overlap = store.projects[0]
        var overlapping = first
        overlapping.id = UUID(); overlapping.start += 0.1
        overlap.captions.append(overlapping)
        var markerOnly = overlapping
        markerOnly.original = "old draft"
        markerOnly.assignClipRole(b.id)
        overlap.setRoleMarker(from: markerOnly, in: range.id)
        let edited = overlap.captions(for: overlap.ranges[0]).first { $0.id == overlapping.id }
        try require(edited?.clipRoleID == b.id && edited?.original == overlapping.original && edited?.end == overlapping.end,
                    "role_menu_preserves_overlapping_caption_text_and_timing")
        var deletion = overlap
        deletion.ranges[0].importedCaptions = [marker, second]
        deletion.ranges[0].proofreadCandidates = [marker]
        deletion.candidates = deletion.ranges
        deletion.removeCaptionRole(a.id)
        let surviving = deletion.captionRoles ?? []
        try require(surviving.count == 1 && surviving.first?.id == b.id && surviving.first?.number == 2,
                    "removing_first_legacy_role_preserves_number_of_survivor")
        try require(deletion.captions.first?.clipUsesDefault == true && deletion.captions.first?.clipRoleID == nil &&
                    deletion.ranges[0].importedCaptions?.first?.clipUsesDefault == true &&
                    deletion.ranges[0].proofreadCandidates?.first?.clipUsesDefault == true &&
                    deletion.candidates?.first?.importedCaptions?.first?.clipUsesDefault == true &&
                    deletion.ranges[0].captionEdits?.first?.clipRoleID == b.id,
                    "deleting_role_resets_its_markers_and_preserves_other_assignments")
        deletion.showsRoleBadges = false
        let reloaded = try JSONDecoder().decode(ClipProject.self, from: JSONEncoder().encode(deletion))
        try require(reloaded.showsRoleBadges == false && reloaded.styledCaptions(for: reloaded.ranges[0]).last?.clipRoleID == b.id,
                    "hiding_badges_preserves_saved_role_assignments_and_styling")
        var expected = base; expected.chinese = a.chinese; expected.japanese = a.japanese
        let resolved = base.resolving(cue: cues[0], roles: [a, b])
        try require(resolved == expected && base.resolving(cue: cues[0], roles: [b]) == base, "roles_override_typography_only_and_missing_role_uses_range")
        var originalOnly = base; originalOnly.mode = .japanese
        let style = originalOnly.resolving(cue: cues[0], roles: [a])
        try require(style.lines(cues[0]).count == 1 && style.lines(cues[0]).first?.1 == a.japanese &&
                    style.position == base.position && style.mask == base.mask, "role_keeps_single_language_and_placement")
        let size = CGSize(width: 640, height: 360)
        // Source masks and text backplates use the same rounded geometry at both resolutions.
        for width in [640, 1280] {
            let canvas = CGSize(width: width, height: width * 9 / 16)
            var masked = base
            masked.mask = .init(x: 0.5, y: 0.5, width: 0.8, height: 0.25, color: "#000000")
            guard let image = ClipSubtitleRenderer.frame(nil, size: canvas, style: masked) else {
                throw ClipError.message("Missing mask frame")
            }
            let mask = ClipSubtitleRenderer.maskRect(size: canvas, mask: masked.mask!)
            let inset = CGFloat(width) / 320
            let rep = NSBitmapImageRep(cgImage: image)
            let alpha = rep.colorAt(x: Int(mask.minX + inset), y: Int(mask.minY + inset))?.alphaComponent ?? 1
            let interior = rep.colorAt(x: Int(mask.midX), y: Int(mask.minY + inset))?.alphaComponent ?? 0
            try require(alpha < 0.2 && interior > 0.95, "rounded_source_mask_preserves_corner_at_" + String(width))
            var plate = base
            plate.background = 1
            guard let textImage = ClipSubtitleRenderer.overlay(cues[0], size: canvas, style: plate) else {
                throw ClipError.message("Missing subtitle background")
            }
            let textRep = NSBitmapImageRep(cgImage: textImage)
            let corner = textRep.colorAt(x: Int(inset), y: Int(inset))?.alphaComponent ?? 1
            let top = textRep.colorAt(x: textImage.width / 2, y: Int(inset))?.alphaComponent ?? 0
            try require(corner < 0.2 && top > 0.95, "rounded_text_backplate_preserves_corner_at_" + String(width))
        }
        guard let overlay = ClipSubtitleRenderer.overlay(cues[0], size: size, style: resolved) else { throw ClipError.message("Missing preview") }
        let colors = ink(in: overlay, middleOnly: false)
        try require(colors.red > 50 && colors.green > 30, "preview_has_role_fill_and_independent_outline_pixels")
        var shadowless = resolved; shadowless.japanese.shadow = 0
        guard let plain = ClipSubtitleRenderer.overlay(cues[0], size: size, style: shadowless) else { throw ClipError.message("Missing shadow comparison") }
        try require(plain.width == overlay.width && plain.height == overlay.height &&
                    plain.dataProvider?.data != overlay.dataProvider?.data, "per_language_shadow_strength_changes_pixels_without_moving_type")
        for mode in [ClipLanguageMode.japanese, .chinese] {
            var legacy = resolved
            legacy.mode = mode
            legacy.mask = nil
            legacy.chinese.shadow = 1
            legacy.japanese.shadow = 1
            var explicit = legacy
            explicit.chinese.shadowOffsetY = 1
            explicit.japanese.shadowOffsetY = 1
            func pixels(_ style: ClipSubtitleStyle) throws -> Data {
                guard let image = ClipSubtitleRenderer.frame(cues[0], size: size, style: style),
                      let data = image.dataProvider?.data else { throw ClipError.message("Missing shadow frame") }
                return data as Data
            }
            let baseline = try pixels(legacy)
            let originalSettings = try pixels(explicit)
            try require(baseline == originalSettings, "legacy_shadow_matches_one_pixel_offset_" + mode.id)
            var adjusted = legacy
            if mode == .japanese { adjusted.chinese.shadowOffsetY = 12 }
            else { adjusted.japanese.shadowOffsetY = 12 }
            let otherLanguage = try pixels(adjusted)
            try require(otherLanguage == baseline, "hidden_language_shadow_does_not_change_visible_line_" + mode.id)
            if mode == .japanese { adjusted.japanese.shadowOffsetY = -12 }
            else { adjusted.chinese.shadowOffsetY = -12 }
            let moved = try pixels(adjusted)
            try require(moved != baseline, "visible_language_shadow_offset_changes_pixels_" + mode.id)
        }
        // Exercise the actual player's coordinator while paused, including editing its visible role.
        let player = AVPlayer(url: fixture)
        let positionView = ClipStyledPlayer.PositionView()
        let coordinator = ClipStyledPlayer.Coordinator()
        coordinator.player = player
        coordinator.image = positionView
        var source = ClipStyledPlayer(player: player, captions: cues, style: base, roles: [a,b], mediaSize: size)
        coordinator.configure(source)
        func visiblePixels() throws -> (red: Int, cyan: Int, green: Int) {
            guard let image = positionView.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ClipError.message("No image from paused player")
            }
            return ink(in: image, middleOnly: true)
        }
        let firstPlayerPixels = try visiblePixels()
        try require(firstPlayerPixels.red > 60 && firstPlayerPixels.cyan < firstPlayerPixels.red / 3, "paused_player_renders_inherited_speaker")
        var recolored = a; recolored.chinese.color = b.chinese.color; recolored.japanese.color = b.japanese.color
        source.roles = [recolored,b]
        coordinator.configure(source)
        let recoloredPixels = try visiblePixels()
        try require(recoloredPixels.cyan > 60 && recoloredPixels.red < recoloredPixels.cyan / 3, "paused_player_redraws_current_cue_after_role_edit")
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = positionView
        positionView.frame = CGRect(origin: .zero, size: size)
        var wroteGlobalStyle = false
        var resized: (id: UUID, chinese: Double, japanese: Double)?
        source.onStyle = { _, _ in wroteGlobalStyle = true }
        source.onRoleResize = { resized = ($0, $1, $2) }
        coordinator.configure(source)
        let overlaySize = CGSize(width: overlay.width, height: overlay.height)
        let origin = ClipSubtitleRenderer.origin(size: size, overlay: overlaySize, style: resolved)
        let handle = CGPoint(x: origin.x + overlaySize.width - 3, y: origin.y + 2)
        let end = CGPoint(x: handle.x - 60, y: handle.y)
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: positionView.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        positionView.mouseDown(with: mouse(.leftMouseDown, handle))
        positionView.mouseDragged(with: mouse(.leftMouseDragged, end))
        try require(resized == nil && !wroteGlobalStyle, "dragging_speaker_type_previews_before_single_commit")
        positionView.mouseUp(with: mouse(.leftMouseUp, end))
        try require(resized?.id == a.id && (resized?.chinese ?? 200) < a.chinese.size &&
                    (resized?.japanese ?? 200) < a.japanese.size && !wroteGlobalStyle, "speaker_resize_targets_current_role_and_preserves_range_style")
        window.contentView = nil; window.close()
        coordinator.stop()
        let job = ClipJob(projectID: id, kind: .export, ranges: [range], burnSubtitles: true, outputFolder: directory.path)
        let oldReceipt = try ClipExportReceipt.fingerprint(media: store.projects[0].media, range: range, cues: cues, job: job, roles: [a,b])
        var changed = a; changed.chinese.shadow = 0.5
        let newReceipt = try ClipExportReceipt.fingerprint(media: store.projects[0].media, range: range, cues: cues, job: job, roles: [changed,b])
        try require(oldReceipt != newReceipt, "changing_used_role_invalidates_export_retry_receipt")
        for kind in [ClipJobKind.preview, .export] {
            let requested = kind == .export ? job : ClipJob(projectID: id, kind: .preview, range: range, burnSubtitles: true)
            store.start(requested, model: nil)
            for _ in 0..<1600 { if !store.isBusy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
            guard store.jobs.first?.state == .completed,
                  let path = kind == .export ? store.projects[0].exports.first : store.projects[0].previewPath else {
                throw ClipError.message(store.jobs.first?.message ?? "Missing role movie")
            }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            for (index, t) in [0.45, 1.35].enumerated() {
                let frame = try generator.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
                let pixels = ink(in: frame, middleOnly: true)
                let valid = index == 0 ? pixels.red > 60 && pixels.red > pixels.cyan * 3 : pixels.cyan > 60 && pixels.cyan > pixels.red * 3
                let label = kind.rawValue + "-role-" + String(index + 1)
                try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(label + ".png"))
                try require(valid, label + "_decoded_pixels_match_speaker")
            }
        }
        guard let oldPreview = store.projects[0].previewPath else { throw ClipError.message("Missing saved preview") }
        store.update(id) { $0.captionRoles = [changed,b] }
        try require(store.projects[0].previewPath == nil && !FileManager.default.fileExists(atPath: oldPreview), "edited_speaker_invalidates_saved_preview_movie")
        return checks
    }

    private static func ink(in image: CGImage, middleOnly: Bool) -> (red: Int, cyan: Int, green: Int) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var red = 0, cyan = 0, green = 0
        for y in (middleOnly ? h / 3 : 0)..<(middleOnly ? h * 2 / 3 : h) {
            for x in (middleOnly ? w / 4 : 0)..<(middleOnly ? w * 3 / 4 : w) {
                let i = (y * w + x) * 4, r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
                if r > 130 && r > g + 65 && r > b + 65 { red += 1 }
                if g > 110 && b > 110 && r + 65 < min(g,b) { cyan += 1 }
                if g > 110 && g > r + 60 && g > b + 60 { green += 1 }
            }
        }
        return (red,cyan,green)
    }
}
