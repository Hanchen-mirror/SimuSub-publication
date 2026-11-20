import SwiftUI
import AVKit

/// A small style surface: typography stays here; placement stays on the video.
struct ClipStyleEditor150: View {
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
        VStack(spacing: 14) {
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
            ClipStyledPlayer(player: player, captions: captions, style: style, roles: roles, mediaSize: mediaSize,
                             onStyle: { value, _ in style = value }, onRoleResize: onRoleResize)
                .frame(height: 166).background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("clip.style.preview")
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    ClipTextStyleControls(title: "原文", text: $style.japanese, role: "original", inheritedShadow: style.shadow ? 0.8 : 0)
                    ClipTextStyleControls(title: "译文", text: $style.chinese, role: "translation", inheritedShadow: style.shadow ? 0.8 : 0)
                }.padding(.horizontal, 2)
            }.frame(height: min(344, max(154, (NSScreen.main?.visibleFrame.height ?? 760) - 348)))
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
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("填充颜色")
                ClipColorPalette150(value: Binding(get: { style.mask?.color ?? "#17151C" }, set: { color in
                    var mask = style.mask ?? ClipSubtitleMask(enabled: false); mask.color = color; style.mask = mask
                }), role: "mask", title: "遮罩颜色")
            }
            let opacity = style.mask?.opacity ?? 1
            ClipStyleSlider(title: "不透明度", section: "遮罩",
                            value: Binding(get: { opacity }, set: { value in
                                var mask = style.mask ?? ClipSubtitleMask(enabled: false); mask.opacity = value; style.mask = mask
                            }), limits: 0...1, step: 0.01, readout: opacity.formatted(.percent))
            Divider().overlay(ThemeColor.line)
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("描边颜色")
                ClipColorPalette150(value: Binding(get: { style.mask?.borderColor ?? "#000000" }, set: { color in
                    var mask = style.mask ?? ClipSubtitleMask(enabled: false); mask.borderColor = color; style.mask = mask
                }), role: "maskBorder", title: "描边颜色")
            }
            let borderWidth = style.mask?.borderWidth ?? 0
            ClipStyleSlider(title: "描边宽度", section: "遮罩",
                            value: Binding(get: { borderWidth }, set: { value in
                                var mask = style.mask ?? ClipSubtitleMask(enabled: false); mask.borderWidth = value; style.mask = mask
                            }), limits: 0...12, step: 0.5,
                            readout: borderWidth.formatted(.number.precision(.fractionLength(0...1))) + " px")
        }.padding(16).frame(width: 244).background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(L10n.text(title)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
    }
}

/// The toolbar manages project roles. A cue's number opens a single-choice palette.
struct ClipCaptionRoleMenu: View {
    let projectID: UUID
    let baseStyle: ClipSubtitleStyle
    let sample: Caption?
    var cue: Binding<Caption>?
    var inheritedRoleID: UUID?
    var badgeOnly = false
    @EnvironmentObject private var clips: ClipStore
    @State private var presented = false
    @State private var draft: ClipCaptionRole?
    @State private var deleting: UUID?

    private var project: ClipProject? { clips.projects.first { $0.id == projectID } }
    private var roles: [ClipCaptionRole] { project?.captionRoles ?? [] }
    private var badgesVisible: Bool { project?.showsRoleBadges != false }
    private var effectiveRole: ClipCaptionRole? {
        guard let marker = cue?.wrappedValue else { return nil }
        let id = marker.clipRoleID ?? (marker.clipUsesDefault == true ? nil : inheritedRoleID)
        return roles.first { $0.id == id }
    }

    private func number(_ role: ClipCaptionRole?) -> Int {
        guard let role, let index = roles.firstIndex(where: { $0.id == role.id }) else { return 0 }
        return role.number ?? (index + 1)
    }
    private var selectedTitle: String {
        guard let role = effectiveRole else { return "0 · " + L10n.text("片段默认") }
        return roleTitle(role)
    }
    private func roleTitle(_ role: ClipCaptionRole) -> String {
        let n = String(number(role))
        return role.name == n ? n : n + " · " + role.name
    }

    @ViewBuilder var body: some View {
        if cue == nil {
            Button { presented = true } label: {
                ZStack {
                    badge(2, size: 14).offset(x: 4, y: -3)
                    badge(1, size: 14).offset(x: -3, y: 3)
                }.frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("多角色")).accessibilityLabel(L10n.text("多角色"))
            .accessibilityIdentifier("clips.multipleRoles")
            .popover(isPresented: $presented) { manager }
        } else {
            Button { presented = true } label: { badge(number(effectiveRole), size: 26) }
                .buttonStyle(.plain)
                .help(selectedTitle).accessibilityLabel(L10n.text("角色样式"))
                .accessibilityValue(selectedTitle)
                .accessibilityIdentifier(badgeOnly ? "clips.roleBadge." + (sample?.id.uuidString ?? "") : "clips.selectCaptionRole")
                .popover(isPresented: $presented) { choices }
        }
    }

    private func badge(_ number: Int, size: CGFloat) -> some View {
        Text(verbatim: String(number)).monospacedDigit()
            .font(.system(size: size < 20 ? 9 : 13, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(ThemeColor.primaryInk)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: size / 4))
            .overlay { RoundedRectangle(cornerRadius: size / 4).strokeBorder(ThemeColor.primaryInk.opacity(0.6)) }
    }

    private func tool(_ image: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image).font(.system(size: 13, weight: .medium))
                .frame(width: 27, height: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk)
            .help(label).accessibilityLabel(label).accessibilityIdentifier(id)
    }
    private var close: some View {
        tool("xmark", L10n.text("关闭"), "clips.closeRoles") { presented = false }
            .keyboardShortcut(.cancelAction)
    }
    private var manager: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                Text(L10n.text("多角色")).font(.headline)
                Spacer()
                tool(badgesVisible ? "eye" : "eye.slash", L10n.text(badgesVisible ? "隐藏角色编号" : "显示角色编号"), "clips.toggleRoleBadges") {
                    clips.update(projectID) { $0.showsRoleBadges = !($0.showsRoleBadges ?? true) }
                }
                tool("plus", L10n.text("新建角色样式"), "clips.addRole") {
                    let next = (roles.map { number($0) }.max() ?? 0) + 1
                    draft = ClipCaptionRole(number: next, name: String(next), chinese: baseStyle.chinese, japanese: baseStyle.japanese)
                }
                close
            }
            if !roles.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(roles) { role in
                            HStack(spacing: 4) {
                                Button { draft = role } label: {
                                    HStack(spacing: 8) {
                                        badge(number(role), size: 24)
                                        if role.name != String(number(role)) {
                                            Text(verbatim: role.name).font(.callout).lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "pencil").font(.caption).foregroundStyle(ThemeColor.muted)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help(L10n.text("编辑"))
                                    .accessibilityLabel(L10n.text("编辑") + " " + roleTitle(role))
                                if deleting == role.id {
                                    tool("checkmark", L10n.text("确认删除"), "clips.confirmDeleteRole") {
                                        clips.update(projectID) { $0.removeCaptionRole(role.id) }
                                        deleting = nil
                                    }
                                    tool("xmark", L10n.text("取消"), "clips.cancelDeleteRole") { deleting = nil }
                                } else {
                                    tool("trash", L10n.text("删除") + " " + roleTitle(role), "clips.deleteRole." + role.id.uuidString) { deleting = role.id }
                                }
                            }.padding(.horizontal, 7).frame(height: 35)
                                .background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: min(225, CGFloat(roles.count) * 38 - 3))
            }
        }.padding(12).frame(width: 225).background(ThemeColor.surface)
            .foregroundStyle(ThemeColor.ink)
            .onDisappear { deleting = nil }
            .sheet(item: $draft) { role in
                ClipCaptionRoleEditor(role: role, roles: roles, baseStyle: baseStyle, sample: sample) { changed in
                    clips.update(projectID) { project in
                        var all = project.captionRoles ?? []
                        if let i = all.firstIndex(where: { $0.id == changed.id }) { all[i] = changed }
                        else { all.append(changed) }
                        project.captionRoles = all
                    }
                    draft = nil
                }.appTheme()
            }
    }
    @ViewBuilder private var choices: some View {
        if let cue {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.text("角色样式")).font(.headline)
                    Spacer()
                    close
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 6) {
                        let inherits = cue.wrappedValue.clipRoleID == nil && cue.wrappedValue.clipUsesDefault != true
                        selectButton("0", help: L10n.text("片段默认"), selected: cue.wrappedValue.clipUsesDefault == true) {
                            cue.wrappedValue.assignClipRole(nil)
                        }
                        ForEach(roles) { role in
                            selectButton(String(number(role)), help: roleTitle(role), selected: cue.wrappedValue.clipRoleID == role.id) {
                                cue.wrappedValue.assignClipRole(role.id)
                            }
                        }
                        selectButton(nil, help: L10n.text("沿用上一条"), selected: inherits) { cue.wrappedValue.inheritClipRole() }
                    }
                }.frame(height: min(180, CGFloat((roles.count + 6) / 5) * 34 - 6))
            }.padding(12).frame(width: 195).background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
        }
    }

    private func selectButton(_ title: String?, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); presented = false } label: {
            Group {
                if let title { Text(verbatim: title).monospacedDigit() }
                else { Image(systemName: "arrow.turn.down.right") }
            }.frame(maxWidth: .infinity).frame(height: 28)
                .foregroundStyle(selected ? ThemeColor.primaryInk : ThemeColor.ink)
                .background(selected ? ThemeColor.selection : ThemeColor.soft, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ClipRolePresetButton: View {
    @Binding var style: ClipSubtitleStyle
    @StateObject private var library: ClipStyleLibrary
    @State private var open = false
    @State private var name = ""
    @State private var error: String?

    init(style: Binding<ClipSubtitleStyle>, root: URL) {
        _style = style
        _library = StateObject(wrappedValue: ClipStyleLibrary(root: root))
    }

    var body: some View {
        Button { library.reload(); open.toggle() } label: {
            Image(systemName: "square.stack.3d.up").frame(width: 28, height: 28)
        }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk)
            .accessibilityLabel(L10n.text("我的样式")).help(L10n.text("我的样式"))
            .accessibilityIdentifier("clips.openStylePresets")
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(L10n.text("我的样式")).font(.headline)
                    if !library.presets.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(library.presets) { preset in
                                    Button {
                                        style = preset.style
                                        open = false
                                    } label: {
                                        HStack {
                                            Text(verbatim: preset.name).lineLimit(1)
                                            Spacer()
                                            Image(systemName: "arrow.uturn.down").font(.caption)
                                        }.padding(7).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(height: min(CGFloat(library.presets.count) * 34, 170))
                    }
                    HStack {
                        TextField(L10n.text("预设名称"), text: $name).textFieldStyle(ClipFieldStyle())
                        Button {
                            do {
                                try library.save(name: name.trimmingCharacters(in: .whitespacesAndNewlines), style: style)
                                name = ""; error = nil
                            } catch { self.error = error.localizedDescription }
                        } label: { Image(systemName: "plus").frame(width: 25, height: 25) }
                            .buttonStyle(.plain).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(L10n.text("保存为预设")).accessibilityLabel(L10n.text("保存为预设"))
                    }
                    if let error { Text(verbatim: error).font(.caption) }
                }.padding(12).frame(width: 230).foregroundStyle(ThemeColor.ink).background(ThemeColor.surface)
            }
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
    @EnvironmentObject private var clips: ClipStore

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
            HStack {
                Text(L10n.text("角色样式")).font(.title3.weight(.semibold))
                Spacer()
                ClipRolePresetButton(style: Binding(get: { previewStyle }, set: { preset in
                    role.japanese = preset.japanese
                    role.chinese = preset.chinese
                    // A preset with inherited shadow keeps its appearance when applied to another range.
                    if role.japanese.shadow == nil { role.japanese.shadow = preset.shadow ? 0.8 : 0 }
                    if role.chinese.shadow == nil { role.chinese.shadow = preset.shadow ? 0.8 : 0 }
                }), root: clips.root)
            }
            HStack {
                Text(L10n.text("角色名称")).font(.caption)
                TextField(L10n.text("角色名称"), text: $role.name).textFieldStyle(ClipFieldStyle()).focused($naming)
                    .accessibilityIdentifier("clips.captionRoleName")
            }
            if duplicate { Text(L10n.text("角色名称已存在")).font(.caption).foregroundStyle(ThemeColor.muted) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ClipStylePreview(cue: previewCue, style: previewStyle).frame(height: 72)
                    HStack(alignment: .top, spacing: 24) {
                        ClipTextStyleControls(title: "原文", text: $role.japanese, role: "original",
                                              inheritedShadow: baseStyle.shadow ? 0.8 : 0)
                        ClipTextStyleControls(title: "译文", text: $role.chinese, role: "translation",
                                              inheritedShadow: baseStyle.shadow ? 0.8 : 0)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("字体")
                DesignMenuField(title: fontLabel(text.font), height: 36) {
                    ForEach(fontChoices(including: text.font), id: \.self) { font in
                        Button(L10n.text(fontLabel(font))) { text.font = font }
                    }
                }.accessibilityLabel(L10n.text(title + "字体"))
            }
            ClipStyleSlider(title: "字号", section: title, value: $text.size, limits: 12...120, step: 1, readout: "\(Int(text.size.rounded())) px")
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel("颜色")
                ClipColorPalette150(value: $text.color, role: role, title: title + "颜色")
            }
            HStack {
                fieldLabel("描边颜色"); Spacer()
                ColorPicker(L10n.text("描边颜色"), selection: Binding(get: {
                    Color(nsColor: .clipHex(text.outlineColor))
                }, set: { text.outlineColor = NSColor($0).clipHex }), supportsOpacity: false)
                    .labelsHidden().controlSize(.small)
                    .accessibilityLabel(L10n.text(title) + " " + L10n.text("描边颜色"))
            }
            ClipStyleSlider(title: "描边宽度", section: title, value: $text.outline, limits: 0...10, step: 0.1,
                            readout: text.outline.formatted(.number.precision(.fractionLength(0...1))) + " px")
            let strength = text.shadow ?? inheritedShadow ?? 0.8
            ClipStyleSlider(title: "阴影强度", section: title,
                            value: Binding(get: { strength }, set: { text.shadow = $0 }), limits: 0...1, step: 0.05, readout: strength.formatted(.percent))
            let offset = text.shadowOffsetY ?? 1
            ClipStyleSlider(title: "阴影高度", section: title,
                            value: Binding(get: { offset }, set: { text.shadowOffsetY = $0 }), limits: -12...12, step: 1, readout: "\(Int(offset.rounded())) px")
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

/// Continuous theme-colored track with discrete adjustments in document units.
struct ClipStyleSlider: View {
    let title: String
    let section: String
    @Binding var value: Double
    let limits: ClosedRange<Double>
    let step: Double
    let readout: String
    @FocusState private var focused: Bool
    private let thumb: CGFloat = 12

    private func setValue(_ newValue: Double) {
        let stepped = limits.lowerBound + ((newValue - limits.lowerBound) / step).rounded() * step
        value = min(limits.upperBound, max(limits.lowerBound, stepped))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.text(title)).interfaceFont(size: 11).foregroundStyle(ThemeColor.muted)
                Spacer()
                Text(verbatim: readout).interfaceFont(size: 11).monospacedDigit()
            }
            GeometryReader { geometry in
                let travel = max(1, geometry.size.width - thumb)
                let fraction = min(1, max(0, (value - limits.lowerBound) / (limits.upperBound - limits.lowerBound)))
                ZStack(alignment: .leading) {
                    Capsule().fill(ThemeColor.line).frame(height: 4)
                    Capsule().fill(ThemeColor.primary).frame(width: thumb / 2 + travel * fraction, height: 4)
                    Circle().fill(ThemeColor.surface)
                        .overlay(Circle().strokeBorder(ThemeColor.primaryInk, lineWidth: focused ? 2 : 1.5))
                        .frame(width: thumb, height: thumb).offset(x: travel * fraction)
                }
                .frame(height: 22).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    focused = true
                    let position = (gesture.location.x - thumb / 2) / travel
                    setValue(limits.lowerBound + position * (limits.upperBound - limits.lowerBound))
                })
            }.frame(height: 22)
        }
        .focusable().focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: setValue(value - step)
            case .right, .up: setValue(value + step)
            default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: limits, step: step)
                .accessibilityLabel(L10n.text(section) + " " + L10n.text(title))
                .accessibilityValue(readout)
        }
    }
}

/// Mask and text palettes keep their own built-in and saved swatches.
private struct ClipColorPalette150: View {
    @Binding var value: String
    let title: String
    @AppStorage private var storedColors: String
    @AppStorage private var hiddenColors: String
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var editingColor: String?
    @State private var adding = false
    @State private var pendingColor = Color.white
    private let presets: [String]
    private let fallback: String
    private let role: String

    init(value: Binding<String>, role: String, title: String) {
        _value = value
        self.role = role
        self.title = title
        let textColors = ["#FFFFFF", "#F6E4B5", "#BEDDF4"]
        let maskColor = ClipSubtitleMask().color
        switch role {
        case "mask": fallback = maskColor; presets = textColors + [maskColor]
        case "maskBorder": fallback = "#000000"; presets = textColors + ["#000000"]
        default: fallback = textColors[0]; presets = textColors
        }
        _storedColors = AppStorage(wrappedValue: "", "clip.style.colors.v150." + role)
        _hiddenColors = AppStorage(wrappedValue: "", "clip.style.colors.hidden." + role)
    }
    private var customColors: [String] {
        var seen = Set(presets)
        return storedColors.split(separator: "|").map { String($0).uppercased() }.filter { ClipSubtitleStyle.isColor($0) && seen.insert($0).inserted }
    }
    private var hidden: [String] {
        hiddenColors.split(separator: "|").map(String.init)
    }
    private var colors: [String] {
        let excluded = Set(hidden)
        let all = (presets + customColors).filter { !excluded.contains($0) }
        let current = value.uppercased()
        guard !all.contains(current), !excluded.contains(current), ClipSubtitleStyle.isColor(current) else { return all }
        return all + [current]
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(colors, id: \.self) { color in
                ZStack(alignment: .topTrailing) {
                    swatch(color)
                        .simultaneousGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                            editingColor = color
                        })
                        .contextMenu {
                            Button(L10n.text("删除颜色"), role: .destructive) { remove(color) }
                        }
                        .accessibilityAction(named: Text(L10n.text("删除颜色"))) { editingColor = color }
                    if editingColor == color {
                        Button { remove(color) } label: {
                            Image(systemName: "xmark").font(.system(size: 6, weight: .semibold)).frame(width: 12, height: 12)
                                .foregroundStyle(ThemeColor.ink).background(ThemeColor.control, in: Circle())
                                .overlay(Circle().strokeBorder(ThemeColor.line))
                        }.buttonStyle(.plain).offset(x: 2, y: -2)
                            .accessibilityLabel(L10n.text("删除颜色"))
                            .accessibilityIdentifier("clip.color." + role + ".remove." + color)
                    }
                }
            }
            Button { editingColor = nil; pendingColor = Color(nsColor: .clipHex(value)); adding = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26)
                    .foregroundStyle(ThemeColor.muted).overlay(Circle().strokeBorder(ThemeColor.line))
            }.buttonStyle(.plain).accessibilityLabel(L10n.text("自定义颜色"))
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 16) {
                        ColorPicker(L10n.text("自定义颜色"), selection: $pendingColor, supportsOpacity: false).font(.system(size: 12))
                        if !hidden.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.text("恢复颜色")).font(.caption).foregroundStyle(ThemeColor.muted)
                                ScrollView {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 8)], alignment: .leading, spacing: 8) {
                                        ForEach(hidden, id: \.self) { color in
                                            Button { addColor(color) } label: {
                                                Circle().fill(Color(nsColor: .clipHex(color))).frame(width: 18, height: 18)
                                                    .frame(width: 26, height: 26).contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                                .accessibilityLabel(L10n.text("恢复颜色") + " " + L10n.text(colorName(color)))
                                                .accessibilityIdentifier("clip.color." + role + ".restore." + color)
                                        }
                                    }
                                }.frame(height: min(94, CGFloat((hidden.count + 4) / 5) * 34 - 8))
                            }
                        }
                        HStack {
                            Button(L10n.text("取消")) { adding = false }.buttonStyle(ThemeActionButtonStyle())
                            Spacer()
                            Button(L10n.text("添加")) { addColor(NSColor(pendingColor).clipHex) }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                        }
                    }.padding(16).frame(width: 220).background(ThemeColor.surface).foregroundStyle(ThemeColor.ink)
                }
        }.accessibilityElement(children: .contain).accessibilityLabel(L10n.text(title))
            .onExitCommand { editingColor = nil; adding = false }
    }
    private func swatch(_ color: String) -> some View {
        Button {
            // The release ending a long press must leave the delete control available.
            guard editingColor != color else { return }
            value = color
            editingColor = nil
        } label: {
            Circle().fill(Color(nsColor: .clipHex(color))).frame(width: 18, height: 18)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(value.uppercased() == color ? ThemeColor.primary : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .modifier(ClipColorJiggle150(enabled: editingColor == color && !appearance.reduceMotion && !systemReduceMotion))
            .accessibilityLabel(L10n.text(colorName(color)))
            .accessibilityIdentifier("clip.color." + role + "." + color)
            .accessibilityAddTraits(value.uppercased() == color ? .isSelected : [])
    }
    private var motion: Animation? { appearance.reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.16) }
    private func addColor(_ color: String) {
        let color = color.uppercased()
        hiddenColors = hidden.filter { $0 != color }.joined(separator: "|")
        if !presets.contains(color), !customColors.contains(color) { storedColors = (customColors + [color]).joined(separator: "|") }
        withAnimation(motion) { value = color; adding = false }
    }
    private func remove(_ color: String) {
        let remaining = colors.filter { $0 != color }
        editingColor = nil
        if value.uppercased() == color, let next = remaining.first {
            value = remaining.contains(fallback) ? fallback : next
        }
        if !hidden.contains(color) { hiddenColors = (hidden + [color]).joined(separator: "|") }
        if customColors.contains(color) { storedColors = customColors.filter { $0 != color }.joined(separator: "|") }
    }
    private func colorName(_ color: String) -> String {
        switch color { case "#FFFFFF": "白色"; case "#F6E4B5": "淡黄色"; case "#BEDDF4": "淡蓝色"; case "#17151C": "深色"; case "#000000": "黑色"; default: "自定义颜色" }
    }
}

private struct ClipColorJiggle150: ViewModifier {
    let enabled: Bool
    @State private var phase = false
    func body(content: Content) -> some View {
        content.offset(x: enabled ? (phase ? 1.4 : -1.4) : 0)
            .animation(enabled ? .easeInOut(duration: 0.13).repeatForever(autoreverses: true) : .easeOut(duration: 0.12), value: phase)
            .onChange(of: enabled) { phase = $0 }.onAppear { phase = enabled }
    }
}
