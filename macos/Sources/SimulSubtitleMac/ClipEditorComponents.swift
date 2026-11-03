import SwiftUI
import AVKit

@MainActor
final class ClipPlayback: ObservableObject {
    let player: AVPlayer
    @Published var time: Double = 0
    @Published var speed: Double = 1 { didSet { player.defaultRate = Float(speed); if player.rate != 0 { player.rate = Float(speed) } } }
    private var observer: Any?
    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor [weak self] in if t.seconds.isFinite { self?.time = t.seconds } }
        }
    }
    func seek(_ time: Double) { player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    deinit { if let observer { player.removeTimeObserver(observer) }; player.pause() }
}

struct ClipStyledPlayer: NSViewRepresentable {
    let player: AVPlayer
    var captions: [Caption]
    var style: ClipSubtitleStyle
    var mediaSize: CGSize
    var onPosition: ((CGPoint, Bool) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline; view.showsFullScreenToggleButton = true
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
        var mediaSize = CGSize(width: 1920, height: 1080)
        override func hitTest(_ point: NSPoint) -> NSView? { onPosition == nil ? nil : super.hitTest(point) }
        override func resetCursorRects() { if onPosition != nil { addCursorRect(bounds, cursor: .openHand) } }
        private func move(_ event: NSEvent, commit: Bool) {
            let scale = min(bounds.width / max(1, mediaSize.width), bounds.height / max(1, mediaSize.height))
            let w = mediaSize.width * scale, h = mediaSize.height * scale
            guard w > 0, h > 0 else { return }
            let p = convert(event.locationInWindow, from: nil)
            onPosition?(CGPoint(x: min(1, max(0, (p.x - (bounds.width - w) / 2) / w)),
                y: min(1, max(0, 1 - (p.y - (bounds.height - h) / 2) / h))), commit)
        }
        override func mouseDown(with event: NSEvent) { move(event, commit: false) }
        override func mouseDragged(with event: NSEvent) { move(event, commit: false) }
        override func mouseUp(with event: NSEvent) { move(event, commit: true) }
    }
    final class Coordinator {
        weak var image: PositionView?
        weak var player: AVPlayer?
        var observer: Any?
        var source: ClipStyledPlayer?
        var lastID: UUID?
        func configure(_ source: ClipStyledPlayer) { image?.onPosition = source.onPosition; image?.mediaSize = source.mediaSize; if self.source?.style != source.style || self.source?.captions != source.captions { lastID = nil }; self.source = source; refresh(force: true) }
        func refresh(force: Bool = false) {
            guard let source else { return }
            let time = player?.currentTime().seconds ?? 0
            let cue = source.captions.first { $0.start <= time && time < $0.end } ?? (source.onPosition == nil ? nil : source.captions.first)
            if !force && lastID == cue?.id { return }; lastID = cue?.id
            // Bound editor bitmaps while keeping the same 1920px design scale.
            let factor = min(1, 960 / source.mediaSize.width)
            let size = CGSize(width: max(16, source.mediaSize.width * factor), height: max(16, source.mediaSize.height * factor))
            image?.image = cue.flatMap { ClipSubtitleRenderer.image($0, size: size, style: source.style) }
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
        }.accessibilityElement(children: .contain).accessibilityLabel("选段起终点")
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
            .accessibilityLabel(isStart ? "起点" : "终点")
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
        }.accessibilityLabel("字幕样式预览")
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
            HStack { Text("自定义字幕样式").font(.title2.bold()); Spacer(); Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭样式设置") }
            Picker("样式", selection: $tab) { Text("预设").tag(0); Text("自定义").tag(1); Text("我的样式").tag(2) }.pickerStyle(.segmented)
            ClipStylePreview(cue: cue, style: style).frame(height: 125)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if tab == 0 {
                        preset("白色经典", .classic); preset("粉色双语", .pink); preset("暖金双语", .gold)
                    } else if tab == 2 {
                        if library.presets.isEmpty { Text("还没有保存的样式，可在自定义后保存为预设。").font(.callout).foregroundStyle(ThemeColor.muted) }
                        ForEach(library.presets) { item in preset(item.name, item.style) }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            language("中文", text: $style.chinese)
                            language("日语", text: $style.japanese)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("布局设置").font(.headline)
                            Picker("上下顺序", selection: $style.chineseFirst) { Text("中文在上").tag(true); Text("日语在上").tag(false) }.pickerStyle(.segmented)
                            Picker("对齐方式", selection: $style.alignment) { Text("左").tag(0); Text("居中").tag(1); Text("右").tag(2) }.pickerStyle(.segmented)
                            slider("行间距", value: $style.spacing, in: 0...60)
                            if style.position != nil {
                                HStack { Text("字幕宽度").font(.caption); Slider(value: Binding(get: { style.position?.width ?? 0.6 }, set: { style.position?.width = $0 }), in: 0.2...0.92) }
                                Button("恢复底部居中") { style.position = nil }
                            } else { slider("距底部", value: $style.bottom, in: 0...400) }
                            DisclosureGroup("高级设置 · 阴影与背景") {
                                Toggle("文字阴影", isOn: $style.shadow).toggleStyle(.checkbox)
                                HStack { Text("背景透明度").font(.caption); Slider(value: $style.background, in: 0...1); Text("\(Int(style.background * 100))%").font(.caption).frame(width: 40) }
                            }.font(.caption)
                        }.padding(12).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let notice { Text(notice).font(.caption).foregroundStyle(ThemeColor.muted) }
                }.padding(.vertical, 2)
            }
            Divider()
            Toggle("同步到全部选段", isOn: $scopeAll).font(.caption).toggleStyle(.checkbox)
            HStack {
                TextField("预设名称", text: $presetName).textFieldStyle(ClipFieldStyle())
                Button("保存为预设") { do { try library.save(name: presetName.isEmpty ? "自定义样式" : presetName, style: style); notice = "已保存，可在“我的样式”中选择。" } catch { notice = error.localizedDescription } }
            }.font(.caption)
            HStack { Button("恢复默认") { style = .classic }; Spacer(); Button("应用样式") { onApply(scopeAll) }.buttonStyle(ClipActionButtonStyle(accent: ClipTheme.violet, prominent: true)) }
            Text("样式即时预览，应用后用于内嵌字幕导出。").font(.system(size: 10)).foregroundStyle(ThemeColor.muted)
        }.buttonStyle(ClipActionButtonStyle()).padding(20)
    }
    private func language(_ name: String, text: Binding<ClipTextStyle>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            Picker("字体", selection: text.font) {
                ForEach(fonts(including: text.wrappedValue.font), id: \.self) { Text($0).tag($0) }
            }.font(.caption)
            Stepper(value: text.size, in: 12...120, step: 1) { Text("字号  \(Int(text.wrappedValue.size)) px").font(.caption) }
            color("颜色", value: text.color)
            Toggle("加粗", isOn: text.bold).font(.caption).toggleStyle(.switch).controlSize(.mini)
            color("描边颜色", value: text.outlineColor)
            Stepper(value: text.outline, in: 0...10, step: 0.5) { Text(String(format: "描边  %.1f px", text.wrappedValue.outline)).font(.caption) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func color(_ title: String, value: Binding<String>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(nsColor: .clipHex(value.wrappedValue)) }, set: { value.wrappedValue = NSColor($0).clipHex }), supportsOpacity: false).font(.caption)
    }
    private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack { Text(label).font(.caption).frame(width: 58, alignment: .leading); Slider(value: value, in: range, step: 1); Text("\(Int(value.wrappedValue)) px").font(.caption).monospacedDigit().frame(width: 48) }
    }
    private func fonts(including name: String) -> [String] { Array(Set(NSFontManager.shared.availableFontFamilies + [name])).sorted() }
    private func preset(_ name: String, _ item: ClipSubtitleStyle) -> some View {
        Button { style = item } label: { HStack { Text(name); Spacer(); Image(systemName: "arrow.down.circle") }.padding(12).frame(maxWidth: .infinity).background(ThemeColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
    }
}
