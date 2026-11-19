import SwiftUI
import AVKit

/// A small style surface: typography stays here; placement stays on the video.
struct ClipStyleEditor150: View {
    let player: AVPlayer
    let captions: [Caption]
    let mediaSize: CGSize
    @Binding var style: ClipSubtitleStyle
    let onClose: () -> Void
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var themeID
    @State private var showingMask = false

    var body: some View {
        let _ = themeID
        VStack(spacing: 20) {
            HStack {
                Text(L10n.text("字幕样式")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { showingMask.toggle() } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .frame(width: 30, height: 30)
                        .background(showingMask ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk)
                    .help(L10n.text("遮挡原视频字幕"))
                    .accessibilityLabel(L10n.text("字幕遮罩设置"))
                    .accessibilityIdentifier("clip.style.mask")
                    .popover(isPresented: $showingMask, arrowEdge: .top) { maskControls }
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(ThemeColor.muted)
                    .accessibilityLabel(L10n.text("关闭字幕样式"))
            }
            ClipStyledPlayer(player: player, captions: captions, style: style, mediaSize: mediaSize,
                             onStyle: { value, _ in style = value })
                .frame(height: 200).background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("clip.style.preview")
            HStack(alignment: .top, spacing: 24) {
                textControls("原文", text: $style.japanese, role: "original")
                textControls("译文", text: $style.chinese, role: "translation")
            }
            HStack {
                Spacer()
                Button(L10n.text("完成"), action: onClose)
                    .buttonStyle(ThemeActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
            .background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
            .onExitCommand { if showingMask { showingMask = false } else { onClose() } }
    }

    private func textControls(_ title: String, text: Binding<ClipTextStyle>, role: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("字体")
                DesignMenuField(title: fontLabel(text.wrappedValue.font), height: 36) {
                    ForEach(fontChoices(including: text.wrappedValue.font), id: \.self) { font in
                        Button(L10n.text(fontLabel(font))) { text.wrappedValue.font = font }
                    }
                }.accessibilityLabel(L10n.text(title + "字体"))
            }
            VStack(spacing: 8) {
                HStack {
                    fieldLabel("字号"); Spacer()
                    Text("\(Int(text.wrappedValue.size.rounded())) px").font(.system(size: 11)).monospacedDigit()
                }
                Slider(value: text.size, in: 12...120, step: 1)
                    .tint(ThemeColor.primary).controlSize(.small)
                    .accessibilityLabel(L10n.text(title + "字号"))
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("颜色")
                ClipColorPalette150(value: text.color, role: role, title: title + "颜色")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var maskControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("遮罩")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(L10n.text("遮罩"), isOn: Binding(get: { style.mask?.enabled ?? false }, set: { enabled in
                    withAnimation(appearance.reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        var mask = style.mask ?? ClipSubtitleMask(); mask.enabled = enabled; style.mask = mask
                    }
                })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(L10n.text("启用字幕遮罩"))
            }
            ClipColorPalette150(value: Binding(get: { style.mask?.color ?? "#17151C" }, set: { color in
                var mask = style.mask ?? ClipSubtitleMask(); mask.color = color; style.mask = mask
            }), role: "mask", title: "遮罩颜色")
            VStack(spacing: 8) {
                HStack {
                    fieldLabel("不透明度"); Spacer()
                    Text("\(Int(((style.mask?.opacity ?? 1) * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit()
                }
                Slider(value: Binding(get: { style.mask?.opacity ?? 1 }, set: { opacity in
                    var mask = style.mask ?? ClipSubtitleMask(); mask.opacity = opacity; style.mask = mask
                }), in: 0...1).tint(ThemeColor.primary).controlSize(.small)
                    .accessibilityLabel(L10n.text("遮罩不透明度"))
            }
        }.padding(16).frame(width: 244).background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(L10n.text(title)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
    }
    private func fontLabel(_ font: String) -> String {
        switch font {
        case "PingFang SC", "Hiragino Sans": "系统字体"
        case "Songti SC": "宋体"
        case "Yuanti SC": "圆体"
        default: font
        }
    }
    private func fontChoices(including current: String) -> [String] {
        let choices = [current == "Hiragino Sans" ? "Hiragino Sans" : "PingFang SC", "Songti SC", "Yuanti SC"]
        return choices.contains(current) ? choices : choices + [current]
    }
}

/// Three initial colors; additional colors use visual swatches, never hex labels.
private struct ClipColorPalette150: View {
    @Binding var value: String
    let title: String
    @AppStorage private var storedColors: String
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var editing = false
    @State private var adding = false
    @State private var pendingColor = Color.white
    private let presets = ["#FFFFFF", "#F6E4B5", "#BEDDF4"]

    init(value: Binding<String>, role: String, title: String) {
        _value = value; self.title = title
        _storedColors = AppStorage(wrappedValue: "", "clip.style.colors.v150." + role)
    }
    private var customColors: [String] {
        var seen = Set(presets)
        return storedColors.split(separator: "|").map { String($0).uppercased() }.filter { ClipSubtitleStyle.isColor($0) && seen.insert($0).inserted }
    }
    private var colors: [String] {
        let all = presets + customColors, current = value.uppercased()
        return all.contains(current) || !ClipSubtitleStyle.isColor(current) ? all : all + [current]
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(colors, id: \.self) { color in
                ZStack(alignment: .topTrailing) {
                    Circle().fill(Color(nsColor: .clipHex(color))).frame(width: 18, height: 18)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(value.uppercased() == color ? ThemeColor.primary : .clear, lineWidth: 1))
                        .contentShape(Circle())
                        .modifier(ClipColorJiggle150(enabled: editing && !presets.contains(color) && !appearance.reduceMotion))
                        .gesture(LongPressGesture(minimumDuration: 0.55, maximumDistance: 8).exclusively(before: TapGesture()).onEnded { result in
                            switch result {
                            case .first(true): if !presets.contains(color) { withAnimation(motion) { editing = true } }
                            case .second: withAnimation(motion) { value = color; editing = false }
                            default: break
                            }
                        })
                        .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                        .accessibilityLabel(L10n.text(colorName(color)))
                        .accessibilityAddTraits(value.uppercased() == color ? .isSelected : [])
                        .accessibilityAction { value = color; editing = false }
                    if editing && !presets.contains(color) {
                        Button { withAnimation(motion) { remove(color) } } label: {
                            Image(systemName: "xmark").font(.system(size: 6, weight: .semibold)).frame(width: 12, height: 12)
                                .foregroundStyle(ThemeColor.ink).background(ThemeColor.control, in: Circle())
                                .overlay(Circle().strokeBorder(ThemeColor.line))
                        }.buttonStyle(.plain).offset(x: 2, y: -2)
                            .accessibilityLabel(L10n.text("删除自定义颜色"))
                    }
                }
            }
            Button { editing = false; pendingColor = Color(nsColor: .clipHex(value)); adding = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                    .foregroundStyle(ThemeColor.muted).overlay(Circle().strokeBorder(ThemeColor.line))
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("自定义颜色"))
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 16) {
                        ColorPicker(L10n.text("自定义颜色"), selection: $pendingColor, supportsOpacity: false).font(.system(size: 12))
                        HStack {
                            Button(L10n.text("取消")) { adding = false }.buttonStyle(ThemeActionButtonStyle())
                            Spacer()
                            Button(L10n.text("添加")) { addColor() }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                        }
                    }.padding(16).frame(width: 220).background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
                }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text(title))
            .onExitCommand { editing = false; adding = false }
    }
    private var motion: Animation? { appearance.reduceMotion ? nil : .easeInOut(duration: 0.16) }
    private func addColor() {
        let color = NSColor(pendingColor).clipHex.uppercased()
        if !presets.contains(color), !customColors.contains(color) { storedColors = (customColors + [color]).joined(separator: "|") }
        withAnimation(motion) { value = color; adding = false }
    }
    private func remove(_ color: String) {
        storedColors = customColors.filter { $0 != color }.joined(separator: "|")
        if value.uppercased() == color { value = presets[0] }
        if customColors.isEmpty { editing = false }
    }
    private func colorName(_ color: String) -> String {
        switch color { case "#FFFFFF": "白色"; case "#F6E4B5": "淡黄色"; case "#BEDDF4": "淡蓝色"; default: "自定义颜色" }
    }
}

private struct ClipColorJiggle150: ViewModifier {
    let enabled: Bool
    @State private var phase = false
    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(enabled ? (phase ? 3 : -3) : 0))
            .animation(enabled ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .easeOut(duration: 0.12), value: phase)
            .onChange(of: enabled) { phase = $0 }.onAppear { phase = enabled }
    }
}
