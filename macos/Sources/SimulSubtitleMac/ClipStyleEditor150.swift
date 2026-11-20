import SwiftUI
import AVKit

/// A small style surface: typography stays here; placement stays on the video.
struct ClipStyleEditor150: View {
    let projectID: UUID
    let player: AVPlayer
    let captions: [Caption]
    var roles: [ClipCaptionRole] = []
    let mediaSize: CGSize
    @Binding var style: ClipSubtitleStyle
    let onClose: () -> Void
    var onRoleResize: ((UUID, Double, Double) -> Void)? = nil
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var themeID
    @State private var showingMask = false

    var body: some View {
        let _ = themeID
        VStack(spacing: 20) {
            HStack {
                Text(L10n.text("字幕样式")).font(.system(size: 18, weight: .semibold))
                Spacer()
                ClipCaptionRoleMenu(projectID: projectID, baseStyle: style, sample: captions.first)
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
            ClipStyledPlayer(player: player, captions: captions, style: style, roles: roles, mediaSize: mediaSize,
                             onStyle: { value, _ in style = value }, onRoleResize: onRoleResize)
                .frame(height: 200).background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("clip.style.preview")
            HStack(alignment: .top, spacing: 24) {
                ClipTextStyleControls(title: "原文", text: $style.japanese, role: "original")
                ClipTextStyleControls(title: "译文", text: $style.chinese, role: "translation")
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
}

/// Used by the clip style toolbar and by the editor for an individual cue.
struct ClipCaptionRoleMenu: View {
    let projectID: UUID
    let baseStyle: ClipSubtitleStyle
    let sample: Caption?
    var cue: Binding<Caption>?
    var inheritedRoleID: UUID?
    @EnvironmentObject private var clips: ClipStore
    @State private var draft: ClipCaptionRole?

    private var roles: [ClipCaptionRole] {
        clips.projects.first { $0.id == projectID }?.captionRoles ?? []
    }
    private var selectedRole: ClipCaptionRole? { roles.first { $0.id == cue?.wrappedValue.clipRoleID } }
    private var effectiveRole: ClipCaptionRole? {
        guard let marker = cue?.wrappedValue else { return nil }
        if marker.clipRoleID != nil { return selectedRole }
        guard marker.clipUsesDefault != true else { return nil }
        return roles.first { $0.id == inheritedRoleID }
    }
    private var selectionName: String { effectiveRole?.name ?? L10n.text("片段默认") }

    var body: some View {
        Menu {
            if let cue {
                Button {
                    cue.wrappedValue.inheritClipRole()
                } label: { choice(L10n.text("沿用上一条"), selected: cue.wrappedValue.clipRoleID == nil && cue.wrappedValue.clipUsesDefault != true) }
                Button {
                    cue.wrappedValue.assignClipRole(nil)
                } label: { choice(L10n.text("片段默认"), selected: cue.wrappedValue.clipUsesDefault == true) }
                ForEach(roles) { role in
                    Button { cue.wrappedValue.assignClipRole(role.id) } label: {
                        choice(role.name, selected: selectedRole?.id == role.id)
                    }
                }
                Divider()
                if let effectiveRole { Button(L10n.text("重命名或编辑样式")) { draft = effectiveRole } }
            } else {
                ForEach(roles) { role in
                    Button { draft = role } label: { Text(verbatim: role.name) }
                }
                if !roles.isEmpty { Divider() }
            }
            Button {
                draft = ClipCaptionRole(id: UUID(), name: "", chinese: baseStyle.chinese, japanese: baseStyle.japanese)
            } label: { Label(L10n.text("新建角色样式"), systemImage: "plus") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: cue == nil ? "person.2" : "person")
                Text(verbatim: cue == nil ? L10n.text("角色样式") : selectionName)
                    .lineLimit(1).truncationMode(.tail)
            }.font(.system(size: cue == nil ? 12 : 11, weight: .medium))
                .padding(.horizontal, 7).frame(height: 23)
                .foregroundStyle(ThemeColor.primaryInk).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: cue == nil ? 120 : 180, alignment: .leading)
        .help(cue == nil ? L10n.text("角色样式") : selectionName)
        .accessibilityLabel(L10n.text("角色样式"))
        .accessibilityValue(cue == nil ? "" : selectionName)
        .accessibilityIdentifier(cue == nil ? "clips.manageCaptionRoles" : "clips.selectCaptionRole")
        .sheet(item: $draft) { role in
            ClipCaptionRoleEditor(role: role, roles: roles, baseStyle: baseStyle, sample: sample) { changed in
                let isNew = !roles.contains { $0.id == changed.id }
                clips.update(projectID) { project in
                    var all = project.captionRoles ?? []
                    if let i = all.firstIndex(where: { $0.id == changed.id }) { all[i] = changed }
                    else { all.append(changed) }
                    project.captionRoles = all
                }
                if isNew, let cue { cue.wrappedValue.assignClipRole(changed.id) }
                draft = nil
            }
            .appTheme()
        }
    }

    @ViewBuilder private func choice(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(verbatim: title) }
    }
}

private struct ClipCaptionRoleEditor: View {
    @State var role: ClipCaptionRole
    let roles: [ClipCaptionRole]
    let baseStyle: ClipSubtitleStyle
    let sample: Caption?
    let onSave: (ClipCaptionRole) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var naming: Bool
    @State private var showEffects = false

    private var name: String { role.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool { roles.contains { $0.id != role.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
    private var previewStyle: ClipSubtitleStyle {
        var style = baseStyle
        style.chinese = role.chinese
        style.japanese = role.japanese
        return style
    }
    private var previewCue: Caption {
        if let sample, !sample.original.isEmpty || !sample.translated.isEmpty { return sample }
        return Caption(start: 0, end: 3, original: model.sourceLanguage.preview, translated: model.targetLanguage.preview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("角色样式")).font(.title3.weight(.semibold))
            HStack {
                Text(L10n.text("角色名称")).font(.caption)
                TextField(L10n.text("角色名称"), text: $role.name).textFieldStyle(ClipFieldStyle()).focused($naming)
                    .accessibilityIdentifier("clips.captionRoleName")
            }
            if duplicate { Text(L10n.text("角色名称已存在")).font(.caption).foregroundStyle(ThemeColor.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ClipStylePreview(cue: previewCue, style: previewStyle).frame(height: 72)
                    Toggle(L10n.text("描边与阴影"), isOn: $showEffects)
                        .toggleStyle(.button).controlSize(.small).accessibilityIdentifier("clips.captionRoleEffects")
                    HStack(alignment: .top, spacing: 24) {
                        ClipTextStyleControls(title: "原文", text: $role.japanese, role: "original",
                                              inheritedShadow: showEffects ? (baseStyle.shadow ? 0.8 : 0) : nil)
                        ClipTextStyleControls(title: "译文", text: $role.chinese, role: "translation",
                                              inheritedShadow: showEffects ? (baseStyle.shadow ? 0.8 : 0) : nil)
                    }
                }.frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                Button(L10n.text("取消")) { dismiss() }.buttonStyle(ThemeActionButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) {
                    var changed = role
                    changed.name = name
                    onSave(changed)
                }.buttonStyle(ThemeActionButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || duplicate || !previewStyle.valid)
                    .accessibilityIdentifier("clips.saveCaptionRole")
            }
        }.padding(20).frame(width: 470, height: 452)
            .background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
            .onAppear { naming = role.name.isEmpty }
    }
}

private struct ClipTextStyleControls: View {
    let title: String
    @Binding var text: ClipTextStyle
    let role: String
    var inheritedShadow: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("字体")
                DesignMenuField(title: fontLabel(text.font), height: 36) {
                    ForEach(fontChoices(including: text.font), id: \.self) { font in
                        Button(L10n.text(fontLabel(font))) { text.font = font }
                    }
                }.accessibilityLabel(L10n.text(title + "字体"))
            }
            VStack(spacing: 8) {
                HStack {
                    fieldLabel("字号"); Spacer()
                    Text("\(Int(text.size.rounded())) px").font(.system(size: 11)).monospacedDigit()
                }
                Slider(value: $text.size, in: 12...120, step: 1)
                    .tint(ThemeColor.primary).controlSize(.small)
                    .accessibilityLabel(L10n.text(title + "字号"))
            }
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("颜色")
                ClipColorPalette150(value: $text.color, role: role, title: title + "颜色")
            }
            if let inheritedShadow {
                ColorPicker(L10n.text("描边颜色"), selection: Binding(get: {
                    Color(nsColor: .clipHex(text.outlineColor))
                }, set: { text.outlineColor = NSColor($0).clipHex }), supportsOpacity: false)
                    .font(.system(size: 11))
                VStack(spacing: 5) {
                    HStack { fieldLabel("描边宽度"); Spacer(); Text(text.outline.formatted() + " px").font(.caption2).monospacedDigit() }
                    Slider(value: $text.outline, in: 0...10, step: 0.1).controlSize(.small)
                        .accessibilityLabel(L10n.text(title) + " " + L10n.text("描边宽度"))
                }
                VStack(spacing: 5) {
                    HStack { fieldLabel("阴影"); Spacer(); Text((text.shadow ?? inheritedShadow).formatted(.percent)).font(.caption2).monospacedDigit() }
                    Slider(value: Binding(get: { text.shadow ?? inheritedShadow }, set: { text.shadow = $0 }), in: 0...1, step: 0.05)
                        .controlSize(.small).accessibilityLabel(L10n.text(title) + " " + L10n.text("阴影"))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
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
