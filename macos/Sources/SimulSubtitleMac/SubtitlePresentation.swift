import AppKit
import SwiftUI

enum SubtitlePresentation: Equatable {
    case workspace, bilingual, single

    init(size: CGSize, subtitleOnly: Bool, displayMode: SubtitleDisplayMode = .bilingual) {
        guard subtitleOnly else { self = .workspace; return }
        // Window size controls the viewport, never the user's language choice.
        self = displayMode == .bilingual ? .bilingual : .single
    }
}

/// Geometry shared by the floating panel and its pointer-interaction checks.
/// Coordinates for the paper and controls use the panel's top-leading origin.
struct SubtitleToolbarLayout {
    let size: CGSize

    let controlWidth: CGFloat = 24
    let controlSize: CGFloat = 24
    // A window resize moves each rail continuously, without changing the reading mode.
    private var toolMidY: CGFloat { size.height / 2 }
    var lightsCenter: CGPoint { CGPoint(x: 41, y: min(19, max(13, toolMidY - 21))) }
    var paperFrame: CGRect {
        CGRect(x: 93, y: 2, width: max(1, size.width - 186), height: max(1, size.height - 4))
    }

    private func rightColumn(_ index: Int, lower: Bool = false) -> CGPoint {
        CGPoint(x: size.width - 75 + CGFloat(index) * 27, y: toolMidY + (lower ? 13 : -13))
    }
    var playbackCenter: CGPoint {
        CGPoint(x: 39, y: (lightsCenter.y + 6 + size.height) / 2)
    }
    var pinCenter: CGPoint { rightColumn(0) }
    var homeCenter: CGPoint { rightColumn(1) }
    var exportCenter: CGPoint { rightColumn(2) }
    var clearCenter: CGPoint { rightColumn(0, lower: true) }
    var modeCenter: CGPoint { rightColumn(1, lower: true) }
    var languagesCenter: CGPoint { rightColumn(2, lower: true) }

}

struct SubtitleStrip: View {
    let captions: [Caption]
    let presentation: SubtitlePresentation
    let size: CGSize
    var isUserResizing = false
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onExit: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void
    var onCollapse: (() -> Void)? = nil
    let displayMode: SubtitleDisplayMode
    let onToggleDisplayMode: () -> Void
    let onExport: (SubtitleExportFormat) -> Void
    let onClear: () -> Void
    let canClear: Bool
    var sourceLanguage: SubtitleLanguage = .japanese
    var targetLanguage: SubtitleLanguage = .simplifiedChinese
    var canChangeLanguages = false
    var onApplyLanguages: ((SubtitleLanguage, SubtitleLanguage) -> Void)? = nil
    var idleText: String = "等待字幕…"
    var isCapturing = false
    var isBusy = false
    var canStartStop = true
    var onStartStop: (() -> Void)? = nil
    var previewControlsVisible = false
    var japaneseFont = ""
    var chineseFont = ""
    var japaneseSize: Double = 16
    var chineseSize: Double = 20
    var zoom: WorkspaceZoom = .normal
    @State private var pointerInside = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var showingLanguages = false
    @State private var showingExport = false
    @State private var showingClearConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var fullCaption: FullCaption?
    private var logicalHeight: CGFloat { zoom.logicalSize(size).height }
    private var compact: Bool { logicalHeight < 80 }
    private var layout: SubtitleToolbarLayout {
        SubtitleToolbarLayout(size: size)
    }
    private var controlSize: CGFloat { layout.controlSize }
    private var controlWidth: CGFloat { layout.controlWidth }
    private func cueLayout(_ caption: Caption) -> SubtitleCueLayout {
        SubtitleCueLayout(caption: caption, mode: displayMode, size: size,
            japaneseFont: japaneseFont, chineseFont: chineseFont,
            japaneseSize: japaneseSize, chineseSize: chineseSize, zoom: zoom)
    }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        let paper = layout.paperFrame
        ZStack(alignment: .topLeading) {
            Group {
                if captions.isEmpty {
                    Text(verbatim: L10n.text(idleText))
                        .font(.system(size: min(15 * zoom.factor, size.height * 0.52), weight: .medium))
                        .foregroundStyle(ThemeColor.muted)
                        .lineLimit(1).truncationMode(.tail).help(L10n.text(idleText))
                        .accessibilityIdentifier("subtitle.idleText")
                } else {
                    ScrollView(.vertical, showsIndicators: captions.count > 1) {
                        let history = captions.dropLast()
                        let rowHeight = SubtitleCueLayout.historyHeight(mode: displayMode, japaneseFont: japaneseFont,
                            chineseFont: chineseFont, japaneseSize: japaneseSize, chineseSize: chineseSize, zoom: zoom)
                        VStack(spacing: 0) {
                            LazyVStack(spacing: 0) {
                                ForEach(history) { caption in
                                    captionView(caption, layout: cueLayout(caption))
                                        .frame(maxWidth: .infinity).frame(height: rowHeight)
                                }
                            }
                            .frame(height: CGFloat(history.count) * rowHeight)
                            if let latest = captions.last {
                                captionView(latest, layout: cueLayout(latest))
                                    .frame(maxWidth: .infinity).frame(height: paper.height)
                            }
                        }
                        .background(alignment: .topLeading) {
                            SubtitleHistoryScroll(latestID: captions.last?.id, size: paper.size)
                                .frame(width: 1, height: 1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityIdentifier("subtitle.history")
                }
            }
            .frame(width: paper.width, height: paper.height)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("subtitle.paper")
            .popover(item: $fullCaption) { FullCaptionDetail(caption: $0) }
            .position(x: paper.midX, y: paper.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { toolbar }
        .contentShape(Rectangle())
        .background { SubtitlePointerTracking(isInside: $pointerInside) }
        .onDisappear { pointerInside = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(displayMode == .original ? "原文字幕" : displayMode == .chinese ? "译文字幕" : "双语字幕"))
        .accessibilityIdentifier(compact ? "subtitle.layout.compact" : "subtitle.layout.regular")
        .alert(L10n.text("清空所有字幕？"), isPresented: $showingClearConfirmation) {
            Button(L10n.text("取消"), role: .cancel) { }
            Button(L10n.text("清空 \(captions.count) 条字幕"), role: .destructive, action: onClear)
        } message: {
            Text(L10n.text("将删除当前保存的全部原文、译文和待处理字幕，无法恢复。已导出的文件不受影响。\(isCapturing ? "清空后将继续监听所选应用。" : "")"))
        }
    }

    private func captionView(_ caption: Caption, layout: SubtitleCueLayout) -> some View {
        PaperCaption(layout: layout, isDraft: caption.isDraft) {
            // The selected cue stays readable while new audio advances the strip.
            fullCaption = FullCaption(id: caption.id, lines: layout.lines.map(\.fullText))
        }
    }

    private var controlsVisible: Bool {
        isUserResizing || previewControlsVisible || voiceOverEnabled || pointerInside || showingExport || showingClearConfirmation || showingLanguages
    }

    private var toolbar: some View {
        ZStack {
            SubtitleNativeControls(onZoom: onZoom, onClose: onClose, onMinimize: onCollapse)
                .frame(width: 66, height: 26)
                .position(layout.lightsCenter)
            Group {
                playbackButton.position(layout.playbackCenter)
                pinButton.position(layout.pinCenter)
                homeButton.position(layout.homeCenter)
                exportButton.position(layout.exportCenter)
                clearButton.position(layout.clearCenter)
                modeButton.position(layout.modeCenter)
                languagesButton.position(layout.languagesCenter)
            }
            .modifier(SubtitleToolVisibility(visible: controlsVisible))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle.toolbar")
        .animation(reduceMotion || isUserResizing ? nil : .easeOut(duration: 0.14), value: controlsVisible)
    }

    private var homeButton: some View {
        toolButton(.home, title: "返回首页（⌘⇧F）", action: onExit).accessibilityIdentifier("subtitle.home")
    }
    private var clearButton: some View {
        toolButton(.clear, title: "清空所有字幕…", action: { showingClearConfirmation = true })
            .disabled(!canClear).accessibilityIdentifier("subtitle.clear")
    }

    private var playbackButton: some View {
        Group {
            if let onStartStop {
                if isBusy { ProgressView().controlSize(.small).frame(width: controlWidth, height: controlSize) }
                else {
                    toolButton(isCapturing ? .pause : .play,
                               title: isCapturing ? "暂停同传" : "开始／继续同传",
                               tint: ThemeColor.primary, action: onStartStop)
                        .disabled(!canStartStop)
                        .accessibilityIdentifier("subtitle.playback")
                }
            }
        }
    }

    private var pinButton: some View {
        toolButton(.pin, title: isPinned ? "取消置顶" : "置顶字幕",
                   tint: isPinned ? ThemeColor.primary : ThemeColor.muted, action: onTogglePin)
            .accessibilityIdentifier("subtitle.pin")
    }
    private var modeButton: some View {
        let actionTitle = L10n.text(displayMode == .bilingual ? "切换为仅原文" : "切换为双语字幕")
        return toolButton(displayMode == .bilingual ? .bilingual : .original, title: "字幕显示",
                          tint: ThemeColor.primary, action: onToggleDisplayMode)
        .help(actionTitle)
        .accessibilityLabel(L10n.text("字幕显示"))
        .accessibilityValue(L10n.text(displayMode.title))
        .accessibilityHint(actionTitle)
        .accessibilityIdentifier("subtitle.displayMode")
    }
    private var languagesButton: some View {
        toolButton(.languages, title: "翻译语言") { showingLanguages.toggle() }
            .disabled(!canChangeLanguages)
            .accessibilityValue(L10n.text(sourceLanguage.name) + " → " + L10n.text(targetLanguage.name))
            .accessibilityIdentifier("subtitle.languages")
            .popover(isPresented: $showingLanguages, arrowEdge: .bottom) {
                SubtitleLanguagePicker(source: sourceLanguage, target: targetLanguage,
                    onCancel: { showingLanguages = false },
                    onApply: { source, target in
                        showingLanguages = false
                        onApplyLanguages?(source, target)
                    })
            }
    }

    private var exportButton: some View {
        toolButton(.export, title: "导出字幕", action: { showingExport.toggle() })
            .disabled(captions.isEmpty).accessibilityIdentifier("subtitle.export")
            .popover(isPresented: $showingExport, arrowEdge: .bottom) {
                SubtitleExportPicker { format in
                    showingExport = false
                    DispatchQueue.main.async { onExport(format) }
                }
            }
    }

    private func toolButton(_ glyph: SubtitlePanelGlyph, title: String, tint: Color = ThemeColor.muted,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let dimension: CGFloat = glyph == .play || glyph == .pause ? 12 : 14
            ZStack {
                if glyph == .play || (glyph == .pin && isPinned) { glyph.fill() }
                glyph.stroke(style: .init(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }
                .frame(width: dimension, height: dimension)
                .frame(width: controlWidth, height: controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(SubtitleToolStyle(tint: tint)).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
}

private struct SubtitleToolVisibility: ViewModifier {
    let visible: Bool

    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

private struct SubtitleToolStyle: ButtonStyle {
    let tint: Color
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tint.opacity(isEnabled && hovered ? 0.15 : 0.06))
                    .frame(width: 20, height: 20)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct PaperCaption: View {
    let layout: SubtitleCueLayout
    let isDraft: Bool
    let showFullCaption: () -> Void

    private var rows: some View {
        VStack(spacing: layout.spacing) {
            ForEach(layout.lines, id: \.original) { line in
                Text(verbatim: line.text)
                    .font(Font(line.font))
                    .foregroundStyle(isDraft || (line.original && layout.lines.count > 1) ? ThemeColor.muted : ThemeColor.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: layout.width)
            }
        }
    }

    var body: some View {
        if layout.lines.contains(where: \.truncated) {
            Button(action: showFullCaption) { rows.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(L10n.text("查看完整字幕"))
            .accessibilityLabel(L10n.text("查看完整字幕"))
            .accessibilityValue(layout.lines.map(\.fullText).joined(separator: "\n"))
            .accessibilityIdentifier("subtitle.fullCaption")
        } else {
            rows.textSelection(.enabled)
        }
    }
}

private struct FullCaption: Identifiable {
    let id: UUID
    let lines: [String]
}

private struct FullCaptionDetail: View {
    let caption: FullCaption

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }
        }
        .frame(width: 340).frame(maxHeight: 280)
        .textSelection(.enabled)
        .accessibilityIdentifier("subtitle.fullCaptionDetail")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(caption.lines.indices, id: \.self) { index in
                Text(verbatim: caption.lines[index]).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SubtitleExportPicker: View {
    var onSelect: (SubtitleExportFormat) -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("导出字幕")).font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.muted)
            HStack(spacing: 8) {
                ForEach(SubtitleExportFormat.allCases) { format in
                    ExportFormatButton(format: format) { onSelect(format) }
                }
            }
        }
        .padding(16)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: appeared)
        .onAppear { appeared = true }
    }
}

private struct ExportFormatButton: View {
    var format: SubtitleExportFormat
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: format == .txt ? "doc.plaintext" : "captions.bubble")
                    .font(.system(size: 21, weight: .light))
                Text(format.title).font(.system(size: 12, weight: .medium))
            }
            .frame(width: 64, height: 66)
            .background(ThemeColor.primary.opacity(hovered ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(hovered && !reduceMotion ? 1.04 : 1)
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .help(L10n.text("导出 \(format.title)")).accessibilityLabel(L10n.text("导出 \(format.title)"))
    }
}

private struct SubtitleGlassBackground: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = GlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
    private final class GlassView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct SubtitleWindowMenu: View {
    @ObservedObject var model: AppModel

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        Button(L10n.text(model.isSubtitleOnly ? "退出纯字幕" : "进入纯字幕")) {
            model.isSubtitleOnly.toggle()
        }.keyboardShortcut("b", modifiers: [.command, .shift])
        Button(L10n.text("恢复完整界面")) { model.isSubtitleOnly = false }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Divider()
        Toggle(L10n.text("纯字幕置顶"), isOn: $model.isSubtitlePinned)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Picker(L10n.text("字幕显示"), selection: $model.subtitleDisplayMode) {
            ForEach(model.isSubtitleOnly ? [.original, .bilingual] : SubtitleDisplayMode.allCases) { mode in
                Text(L10n.text(mode.title)).tag(mode)
            }
        }
        Divider()
        Button(L10n.text(model.isCapturing ? "暂停字幕" : "开始／继续字幕")) {
            model.isSubtitleOnly = true
            model.toggleSubtitlePlayback()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model.isStarting || model.isStopping || model.isProcessingFile)
        Menu(L10n.text("导出字幕")) {
            ForEach(SubtitleExportFormat.allCases) { format in
                Button(format.title) { model.exportCaptions(format: format) }
            }
        }.disabled(model.captions.isEmpty)
    }
}
