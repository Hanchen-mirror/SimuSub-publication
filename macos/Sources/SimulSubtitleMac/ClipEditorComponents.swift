import SwiftUI
import AVKit

@MainActor
final class ClipPlayback: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var speed: Double = 1 { didSet { player.defaultRate = Float(speed); if player.rate != 0 { player.rate = Float(speed) } } }
    private var observer: Any?
    private var boundaryObserver: Any?
    private var playbackRequest = UUID()
    var selection: ClosedRange<Double>?
    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in if t.seconds.isFinite { self?.time = t.seconds } }
        }
    }
    func seek(_ time: Double) { playbackRequest = UUID(); self.time = max(0, time); player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func select(_ bounds: ClosedRange<Double>) { select(ClipRange(title: "", start: bounds.lowerBound, end: bounds.upperBound)) }
    func select(_ range: ClipRange) {
        player.pause(); selection = range.start...range.end
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        let end = range.end
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))], queue: .main) { [weak self] in
            self?.player.pause(); self?.seek(end)
        }
        seek(range.start)
    }
    func clearSelection() { player.pause(); selection = nil; if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }; boundaryObserver = nil; seek(0) }
    func toggle() {
        if player.rate != 0 { playbackRequest = UUID(); player.pause(); return }
        if let selection, time < selection.lowerBound || time >= selection.upperBound - 0.02 {
            let request = UUID(); playbackRequest = request; time = selection.lowerBound
            player.seek(to: CMTime(seconds: selection.lowerBound, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, finished, self.playbackRequest == request else { return }
                    self.player.playImmediately(atRate: Float(self.speed))
                }
            }
        } else { player.playImmediately(atRate: Float(speed)) }
    }
    deinit { if let observer { player.removeTimeObserver(observer) }; if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }; player.pause() }
}

struct ClipStyledPlayer: NSViewRepresentable {
    let player: AVPlayer
    var captions: [Caption]
    var style: ClipSubtitleStyle
    var mediaSize: CGSize
    var onPosition: ((CGPoint, Bool) -> Void)? = nil
    var onStyle: ((ClipSubtitleStyle, Bool) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.showsFullScreenToggleButton = false
        let image = PositionView(); image.imageScaling = .scaleProportionallyUpOrDown; image.autoresizingMask = [.width, .height]
        if let container = view.contentOverlayView { image.frame = container.bounds; container.addSubview(image) }
        context.coordinator.image = image; context.coordinator.player = player; context.coordinator.configure(self)
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak coordinator = context.coordinator] _ in coordinator?.refresh() }
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { context.coordinator.configure(self) }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { coordinator.stop(); view.player = nil }
    final class PositionView: NSImageView {
        var onPosition: ((CGPoint, Bool) -> Void)?
        var onStyle: ((ClipSubtitleStyle, Bool) -> Void)?
        var mediaSize = CGSize(width: 1920, height: 1080)
        var style = ClipSubtitleStyle.classic
        var cue: Caption?
        private var hover = false
        private var tracking: NSTrackingArea?
        private var initialPoint = CGPoint.zero
        private var initialStyle = ClipSubtitleStyle.classic
        private var initialRect = CGRect.zero
        private var operation = ""
        private var videoRect: CGRect {
            let scale = min(bounds.width / max(1, mediaSize.width), bounds.height / max(1, mediaSize.height))
            let size = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
            return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        }
        private var captionRect: CGRect {
            let raster = ClipSubtitleRenderer.previewSize(mediaSize)
            guard let cue, let overlay = ClipSubtitleRenderer.overlay(cue, size: raster, style: style) else { return .zero }
            let size = CGSize(width: overlay.width, height: overlay.height)
            let p = ClipSubtitleRenderer.origin(size: raster, overlay: size, style: style)
            let scale = videoRect.width / raster.width
            return CGRect(x: videoRect.minX+p.x*scale, y: videoRect.minY+p.y*scale, width: size.width*scale, height: size.height*scale)
        }
        private var maskRect: CGRect {
            guard let mask = style.mask, mask.enabled else { return .zero }
            return ClipSubtitleRenderer.maskRect(size: videoRect.size, mask: mask).offsetBy(dx: videoRect.minX, dy: videoRect.minY)
        }
        private var resizeRect: CGRect { CGRect(x: captionRect.maxX-9, y: captionRect.minY-5, width: 14, height: 14) }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard onStyle != nil || onPosition != nil else { return nil }
            let p = convert(point, from: superview)
            return captionRect.insetBy(dx: -7, dy: -7).contains(p) || maskRect.insetBy(dx: -6, dy: -6).contains(p) ? self : nil
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseMoved(with event: NSEvent) { hover = captionRect.insetBy(dx: -10, dy: -10).contains(convert(event.locationInWindow, from: nil)); needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
        override func resetCursorRects() { if onStyle != nil { addCursorRect(captionRect, cursor: .openHand); addCursorRect(maskRect, cursor: .openHand) } }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard hover, onStyle != nil, !captionRect.isEmpty else { return }
            NSColor.secondaryLabelColor.setStroke()
            let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: CGPoint(x: captionRect.maxX-7, y: captionRect.minY+1)); p.line(to: CGPoint(x: captionRect.maxX-1, y: captionRect.minY+7))
            p.move(to: CGPoint(x: captionRect.maxX-4, y: captionRect.minY+1)); p.line(to: CGPoint(x: captionRect.maxX-1, y: captionRect.minY+4)); p.stroke()
        }
        override func mouseDown(with event: NSEvent) {
            initialPoint = convert(event.locationInWindow, from: nil); initialStyle = style
            initialRect = captionRect
            if resizeRect.contains(initialPoint) { operation = "scale" }
            else if captionRect.contains(initialPoint) { operation = "caption" }
            else if maskRect.insetBy(dx: -6, dy: -6).contains(initialPoint), !maskRect.isEmpty {
                initialRect = maskRect
                let xEdge = abs(initialPoint.x-maskRect.minX)<7 || abs(initialPoint.x-maskRect.maxX)<7
                let yEdge = abs(initialPoint.y-maskRect.minY)<7 || abs(initialPoint.y-maskRect.maxY)<7
                operation = xEdge && yEdge ? "maskBoth" : xEdge ? "maskX" : yEdge ? "maskY" : "mask"
            } else { operation = "" }
        }
        private func change(_ event: NSEvent, commit: Bool) {
            guard !operation.isEmpty, videoRect.width > 0, videoRect.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil), dx = point.x-initialPoint.x, dy = point.y-initialPoint.y
            var value = initialStyle
            func clamp(_ x: Double) -> Double { min(1,max(0,x)) }
            if operation == "scale" {
                let raw = 1+(dx-dy)/max(40,initialRect.width+initialRect.height)
                let lower = max(12/value.chinese.size,12/value.japanese.size), upper = min(120/value.chinese.size,120/value.japanese.size)
                let factor = min(upper,max(lower,raw)); value.chinese.size *= factor; value.japanese.size *= factor
            } else if operation == "caption" {
                var position = value.position ?? ClipSubtitlePosition(width: 0.92)
                position.x = clamp((initialRect.midX-videoRect.minX+dx)/videoRect.width)
                position.y = clamp(1-(initialRect.midY-videoRect.minY+dy)/videoRect.height)
                value.position = position; onPosition?(CGPoint(x: position.x,y: position.y),commit)
            } else if var mask = value.mask {
                if operation == "mask" { mask.x = clamp((initialRect.midX-videoRect.minX+dx)/videoRect.width); mask.y = clamp(1-(initialRect.midY-videoRect.minY+dy)/videoRect.height) }
                else {
                    if operation != "maskY" { mask.width = min(1,max(0.02,initialRect.width/videoRect.width + 2*dx/videoRect.width*(initialPoint.x < initialRect.midX ? -1 : 1))) }
                    if operation != "maskX" { mask.height = min(1,max(0.02,initialRect.height/videoRect.height + 2*dy/videoRect.height*(initialPoint.y < initialRect.midY ? -1 : 1))) }
                }
                value.mask = mask
            }
            onStyle?(value,commit)
            if commit { operation = "" }
        }
        override func mouseDragged(with event: NSEvent) { change(event,commit:false) }
        override func mouseUp(with event: NSEvent) { change(event,commit:true) }
    }
    final class Coordinator {
        weak var image: PositionView?
        weak var player: AVPlayer?
        var observer: Any?
        var source: ClipStyledPlayer?
        var lastID: UUID?
        func configure(_ source: ClipStyledPlayer) {
            let changed = self.source?.style != source.style || self.source?.captions != source.captions
            image?.onPosition = source.onPosition; image?.onStyle = source.onStyle; image?.mediaSize = source.mediaSize; image?.style = source.style
            self.source = source; refresh(force: changed)
        }
        func refresh(force: Bool = false) {
            guard let source else { return }
            let time = player?.currentTime().seconds ?? 0
            let cue = source.captions.first { $0.start <= time && time < $0.end }
            if !force && lastID == cue?.id { return }; lastID = cue?.id
            let size = ClipSubtitleRenderer.previewSize(source.mediaSize)
            image?.cue = cue; image?.image = ClipSubtitleRenderer.image(cue, size: size, style: source.style)
            image?.needsDisplay = true
        }
        func stop() { if let observer { player?.removeTimeObserver(observer) }; observer = nil; image?.image = nil; source = nil }
    }
}

struct ClipRangeTimeline: View {
    @Binding var start: Double
    @Binding var end: Double
    var duration: Double
    var energy: [ClipEnergy]
    var onCommit: () -> Void
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            let width = max(1, geometry.size.width), a = width * start / max(duration, 0.2), b = width * end / max(duration, 0.2)
            VStack(spacing: 7) {
                HStack { Text("00:00"); Spacer(); Text(ClipTime.label(duration)) }.font(.system(size: 9)).monospacedDigit().foregroundStyle(ThemeColor.muted)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 7).fill(ThemeColor.ink.opacity(0.05))
                    Path { p in
                        let maxRMS = energy.map(\.rms).max() ?? 1
                        for i in 0..<80 {
                            let x = CGFloat(i) / 79 * width
                            let t = Double(i) / 79 * duration
                            let e = energy.min(by: { abs($0.start - t) < abs($1.start - t) })?.rms ?? 0
                            let h = energy.isEmpty ? 2.0 : max(2, e / max(0.001, maxRMS) * 16)
                            p.move(to: CGPoint(x: x, y: 21 - h)); p.addLine(to: CGPoint(x: x, y: 21 + h))
                        }
                    }.stroke(ThemeColor.ink.opacity(0.28), lineWidth: 1)
                    Rectangle().fill(ClipTheme.cyan.opacity(0.2)).frame(width: max(0, b - a)).offset(x: a)
                    handle(x: a, width: width, isStart: true)
                    handle(x: b, width: width, isStart: false)
                }.frame(height: 42).coordinateSpace(name: "clip.range")
            }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text("选段起终点"))
    }
    private func handle(x: CGFloat, width: CGFloat, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 10, height: 34)
            .overlay(Capsule().fill(ClipTheme.violet).frame(width: 2, height: 18))
            .shadow(color: ClipTheme.violet.opacity(0.5), radius: 5).offset(x: min(width - 10, max(0, x - 5)))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clip.range")).onChanged { value in
                let t = max(0, min(duration, value.location.x / width * duration))
                if isStart { start = min(end - 0.2, max(max(0, end - 600), t)) }
                else { end = max(start + 0.2, min(min(duration, start + 600), t)) }
            }.onEnded { _ in onCommit() })
            .accessibilityLabel(L10n.text(isStart ? "起点" : "终点"))
            .accessibilityValue(ClipTime.label(isStart ? start : end))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                if isStart { start = max(max(0, end - 600), min(end - 0.2, start + delta)) }
                else { end = min(min(duration, start + 600), max(start + 0.2, end + delta)) }
                onCommit()
            }
    }
}

struct ClipStylePreview: View {
    var cue: Caption
    var style: ClipSubtitleStyle
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                if let image = ClipSubtitleRenderer.preview(cue, style: style) {
                    Image(nsImage: image).resizable().scaledToFit().padding(14).frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }.accessibilityLabel(L10n.text("字幕样式预览"))
    }
}

struct ClipStyleDrawer: View {
    @Binding var style: ClipSubtitleStyle
    var cue: Caption
    var onClose: () -> Void
    var onApply: (Bool) -> Void
    @StateObject private var library: ClipStyleLibrary
    @State private var scopeAll = false
    @State private var tab = 1
    @State private var presetName = "我的双语样式"
    @State private var notice: String?
    init(style: Binding<ClipSubtitleStyle>, cue: Caption, root: URL, onClose: @escaping () -> Void, onApply: @escaping (Bool) -> Void) {
        _style = style; self.cue = cue; self.onClose = onClose; self.onApply = onApply
        _library = StateObject(wrappedValue: ClipStyleLibrary(root: root))
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(L10n.text("自定义字幕样式")).font(.title2.bold()); Spacer(); Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("关闭样式设置")) }
            Picker(L10n.text("样式"), selection: $tab) { Text(L10n.text("预设")).tag(0); Text(L10n.text("自定义")).tag(1); Text(L10n.text("我的样式")).tag(2) }.pickerStyle(.segmented)
            ClipStylePreview(cue: cue, style: style).frame(height: 125)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 {
                        preset("白色经典", .classic); preset("粉色双语", .pink); preset("暖金双语", .gold)
                    } else if tab == 2 {
                        if library.presets.isEmpty { Text(L10n.text("还没有保存的样式，可在自定义后保存为预设。")).font(.callout).foregroundStyle(ThemeColor.muted) }
                        ForEach(library.presets) { item in preset(item.name, item.style) }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            language("中文", text: $style.chinese)
                            language("日语", text: $style.japanese)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("布局设置")).font(.headline)
                            Picker(L10n.text("上下顺序"), selection: $style.chineseFirst) { Text(L10n.text("中文在上")).tag(true); Text(L10n.text("日语在上")).tag(false) }.pickerStyle(.segmented)
                            Picker(L10n.text("对齐方式"), selection: $style.alignment) { Text(L10n.text("左")).tag(0); Text(L10n.text("居中")).tag(1); Text(L10n.text("右")).tag(2) }.pickerStyle(.segmented)
                            slider("行间距", value: $style.spacing, in: 0...60)
                            if style.position != nil {
                                HStack { Text(L10n.text("字幕宽度")).font(.caption); Slider(value: Binding(get: { style.position?.width ?? 0.6 }, set: { style.position?.width = $0 }), in: 0.2...0.92) }
                                Button(L10n.text("恢复底部居中")) { style.position = nil }
                            } else { slider("距底部", value: $style.bottom, in: 0...400) }
                            DisclosureGroup(L10n.text("高级设置 · 阴影与背景")) {
                                Toggle(L10n.text("文字阴影"), isOn: $style.shadow).toggleStyle(.checkbox)
                                HStack { Text(L10n.text("背景透明度")).font(.caption); Slider(value: $style.background, in: 0...1); Text("\(Int(style.background * 100))%").font(.caption).frame(width: 40) }
                            }.font(.caption)
                        }.padding(12).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let notice { Text(L10n.text(notice)).font(.caption).foregroundStyle(ThemeColor.muted) }
                }.padding(.vertical, 2)
            }
            Divider()
            Toggle(L10n.text("同步到全部选段"), isOn: $scopeAll).font(.caption).toggleStyle(.checkbox)
            HStack {
                TextField(L10n.text("预设名称"), text: $presetName).textFieldStyle(ClipFieldStyle())
                Button(L10n.text("保存为预设")) { do { try library.save(name: presetName.isEmpty ? "自定义样式" : presetName, style: style); notice = "已保存，可在“我的样式”中选择。" } catch { notice = error.localizedDescription } }
            }.font(.caption)
            HStack { Button(L10n.text("恢复默认")) { style = .classic }; Spacer(); Button(L10n.text("应用样式")) { onApply(scopeAll) }.buttonStyle(ClipActionButtonStyle(accent: ClipTheme.violet, prominent: true)) }
            Text(L10n.text("样式即时预览，应用后用于内嵌字幕导出。")).font(.system(size: 10)).foregroundStyle(ThemeColor.muted)
        }.buttonStyle(ClipActionButtonStyle()).padding(20)
    }
    private func language(_ name: String, text: Binding<ClipTextStyle>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(name)).font(.headline)
            Picker(L10n.text("字体"), selection: text.font) {
                ForEach(fonts(including: text.wrappedValue.font), id: \.self) { Text($0).tag($0) }
            }.font(.caption)
            Stepper(value: text.size, in: 12...120, step: 1) { Text(L10n.text("字号  \(Int(text.wrappedValue.size)) px")).font(.caption) }
            color("颜色", value: text.color)
            Toggle(L10n.text("加粗"), isOn: text.bold).font(.caption).toggleStyle(.switch).controlSize(.mini)
            color("描边颜色", value: text.outlineColor)
            Stepper(value: text.outline, in: 0...10, step: 0.5) { Text(String(format: "描边  %.1f px", text.wrappedValue.outline)).font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func color(_ title: String, value: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(nsColor: .clipHex(value.wrappedValue)) }, set: { value.wrappedValue = NSColor($0).clipHex }), supportsOpacity: false).font(.caption)
    }
    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack { Text(L10n.text(label)).font(.caption).frame(width: 58, alignment: .leading); Slider(value: value, in: range, step: 1); Text("\(Int(value.wrappedValue)) px").font(.caption).monospacedDigit().frame(width: 48) }
    }
    private func fonts(including name: String) -> [String] { Array(Set(NSFontManager.shared.availableFontFamilies + [name])).sorted() }
    private func preset(_ name: String, _ item: ClipSubtitleStyle) -> some View {
        Button { style = item } label: { HStack { Text(L10n.text(name)); Spacer(); Image(systemName: "arrow.down.circle") }.padding(12).frame(maxWidth: .infinity).background(ThemeColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
}
