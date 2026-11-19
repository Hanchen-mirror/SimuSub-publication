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

enum SingleSubtitleLanguage: String, CaseIterable, Identifiable {
    case original = "原文"
    case translation = "译文"
    var id: String { rawValue }
}

struct SubtitleStrip: View {
    let captions: [Caption]
    let presentation: SubtitlePresentation
    let size: CGSize
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onExit: () -> Void
    let onZoom: () -> Void
    let onClose: () -> Void
    let displayMode: SubtitleDisplayMode
    let onToggleDisplayMode: () -> Void
    let onExport: (SubtitleExportFormat) -> Void
    let onClear: () -> Void
    let canClear: Bool
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
    @State private var showingExport = false
    @State private var showingClearConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "subtitle.paper.bottom"
    private var logicalHeight: CGFloat { zoom.logicalSize(size).height }
    private var compact: Bool { logicalHeight < 80 }
    private var latest: Caption? { captions.last.map(SubtitleDocument.liveCaption) }
    private var compactBilingual: Bool { displayMode == .bilingual && latest?.isOriginalOnly != true && latest?.original != latest?.translated }
    private var compactOriginalSize: CGFloat { min(min(japaneseSize, 14) * zoom.factor, size.height * 0.52) }
    private var compactTranslationSize: CGFloat { min(min(chineseSize, 16) * zoom.factor, size.height * 0.52) }
    private var controlSize: CGFloat { compact ? 20 : 26 }
    private var controlSpacing: CGFloat { compact ? 2 : 4 }
    // Match the larger toolbar gutter so the compact caption stays centered.
    private var textInset: CGFloat { compact ? (controlsVisible ? 116 : 76) : 16 }
    private var textWidth: CGFloat { max(24, size.width - textInset * 2) }
    private var paperInset: CGFloat { 8 }
    private var contentHeight: CGFloat { max(1, size.height - (compact ? 0 : 34)) }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            if !compact {
                HStack(spacing: 10) {
                    SubtitleNativeControls(onZoom: onZoom, onClose: onClose).frame(width: 66, height: 26)
                    playbackButton
                    Spacer(minLength: 8)
                    rightControls
                }.padding(.horizontal, 8).frame(height: 34)
                .accessibilityIdentifier("subtitle.toolbar")
            }
            ZStack {
                if captions.isEmpty {
                    Text(L10n.text(idleText)).font(.system(size: min(15 * zoom.factor, size.height * 0.52), weight: .medium)).foregroundStyle(ThemeColor.muted)
                        .multilineTextAlignment(.center).lineLimit(compact ? 1 : 2)
                        .truncationMode(.tail).help(L10n.text(idleText))
                        .frame(width: textWidth, height: max(1, contentHeight - paperInset * 2))
                        .accessibilityIdentifier("subtitle.idleText")
                } else if compact, let latest {
                    let showsOriginal = displayMode == .original || latest.isOriginalOnly
                    HStack(spacing: 6) {
                        if compactBilingual {
                            Text(compactLine(latest.original, original: true))
                                .font(Font(SubtitleFont.native(japaneseFont, size: compactOriginalSize)))
                                .foregroundStyle(ThemeColor.muted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text("｜").foregroundStyle(ThemeColor.muted)
                        }
                        Text(compactLine(translation(latest), original: showsOriginal))
                            .font(Font(SubtitleFont.native(showsOriginal ? japaneseFont : chineseFont,
                                size: showsOriginal ? compactOriginalSize : compactTranslationSize, weight: .medium)))
                            .foregroundStyle(ThemeColor.ink)
                            .frame(maxWidth: .infinity, alignment: compactBilingual ? .leading : .center)
                    }
                    .lineLimit(1).help(compactText(latest))
                    .frame(width: textWidth, height: max(1, contentHeight - paperInset * 2))
                } else {
                    ScrollViewReader { reader in
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(alignment: .center, spacing: 18) {
                                ForEach(captions) { caption in
                                    PaperCaption(caption: SubtitleDocument.liveCaption(caption), mode: displayMode, textWidth: textWidth,
                                        shortWindow: logicalHeight < 120, japaneseFont: japaneseFont, chineseFont: chineseFont,
                                        japaneseSize: japaneseSize * zoom.factor, chineseSize: chineseSize * zoom.factor).id(caption.id)
                                }
                                Color.clear.frame(height: 1).id(bottomID).allowsHitTesting(false)
                            }
                            .frame(minHeight: max(0, contentHeight - paperInset * 2), alignment: captions.count <= 1 ? .center : .bottom)
                            .padding(.horizontal, textInset).padding(.vertical, paperInset)
                        }
                        .onAppear { reader.scrollTo(bottomID, anchor: .bottom) }
                        .onChange(of: captions.last) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                        .onChange(of: displayMode) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                        .onChange(of: size) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .accessibilityIdentifier("subtitle.history")
                }
            }.frame(height: contentHeight).clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: compact ? .leading : .topLeading) {
            if compact { SubtitleNativeControls(onZoom: onZoom, onClose: onClose).frame(width: 66, height: 26).padding(.leading, 8) }
        }
        .overlay(alignment: .leading) { if compact { playbackButton.padding(.leading, 80) } }
        .overlay(alignment: .trailing) { if compact { rightControls.padding(.trailing, 8) } }
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

    private func translation(_ caption: Caption) -> String {
        if displayMode == .original || caption.isOriginalOnly { return caption.original }
        return SubtitleDocument.completedTranslation(caption)
            ?? (caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成") ? L10n.text("翻译未完成") : L10n.text("正在翻译…"))
    }

    private func compactText(_ caption: Caption) -> String {
        if displayMode == .original || caption.isOriginalOnly { return caption.original }
        let chinese = SubtitleDocument.completedTranslation(caption) ?? caption.translated
        let text = displayMode == .bilingual && caption.original != chinese ? caption.original + " ｜ " + chinese : chinese
        return text
    }

    private func compactLine(_ text: String, original: Bool) -> String {
        let available = textWidth
        let width = compactBilingual ? max(24, (available - 24) / 2) : available
        let font = SubtitleFont.native(original ? japaneseFont : chineseFont,
            size: original ? compactOriginalSize : compactTranslationSize, weight: original ? .regular : .medium)
        let clean = text.replacingOccurrences(of: "\n", with: " ")
        if (clean as NSString).size(withAttributes: [.font: font]).width <= width { return clean }
        var tail = ""
        for character in clean.reversed() {
            let next = String(character) + tail
            if (("…" + next) as NSString).size(withAttributes: [.font: font]).width > width { break }
            tail = next
        }
        return "…" + tail
    }

    private var controlsVisible: Bool {
        previewControlsVisible || voiceOverEnabled || pointerInside || showingExport || showingClearConfirmation
    }

    private var rightControls: some View {
        HStack(spacing: controlSpacing) {
            HStack(spacing: controlSpacing) {
                pinButton
                homeButton
                exportButton
                clearButton
            }
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .accessibilityHidden(!controlsVisible)
            languageButton
                .opacity(controlsVisible ? 1 : 0.78)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controlsVisible)
    }

    private var homeButton: some View {
        toolButton("house", title: "返回首页（⌘⇧F）", action: onExit).accessibilityIdentifier("subtitle.home")
    }
    private var clearButton: some View {
        toolButton("trash", title: "清空所有字幕…", action: { showingClearConfirmation = true })
            .disabled(!canClear).accessibilityIdentifier("subtitle.clear")
    }

    private var playbackButton: some View {
        Group {
            if let onStartStop {
                if isBusy { ProgressView().controlSize(.small).frame(width: controlSize, height: controlSize) }
                else {
                    toolButton(isCapturing ? "pause.fill" : "play.fill",
                               title: isCapturing ? "暂停同传" : "开始／继续同传",
                               tint: ThemeColor.primary, action: onStartStop)
                        .disabled(!canStartStop)
                        .accessibilityIdentifier("subtitle.playback")
                }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controlsVisible)
    }

    private var pinButton: some View {
        toolButton(isPinned ? "pin.fill" : "pin", title: isPinned ? "取消置顶" : "置顶字幕",
                   tint: isPinned ? ThemeColor.primary : ThemeColor.muted, action: onTogglePin)
            .accessibilityIdentifier("subtitle.pin")
    }
    private var languageButton: some View {
        let bilingual = displayMode == .bilingual
        return toolButton(bilingual ? "captions.bubble.fill" : "captions.bubble",
                          title: bilingual ? "切换为单语字幕" : "切换为双语字幕",
                          tint: bilingual ? ThemeColor.primary : ThemeColor.muted, action: onToggleDisplayMode)
            .accessibilityLabel(L10n.text("双语字幕"))
            .accessibilityValue(L10n.text(displayMode.title))
            .accessibilityAddTraits(bilingual ? .isSelected : [])
            .accessibilityIdentifier("subtitle.displayMode")
    }
    private var exportButton: some View {
        toolButton("square.and.arrow.up", title: "导出字幕", action: { showingExport.toggle() })
            .disabled(captions.isEmpty).accessibilityIdentifier("subtitle.export")
            .popover(isPresented: $showingExport, arrowEdge: .bottom) {
                SubtitleExportPicker { format in
                    showingExport = false
                    DispatchQueue.main.async { onExport(format) }
                }
            }
    }

    private func toolButton(_ symbol: String, title: String, tint: Color = ThemeColor.muted,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: controlSize, height: controlSize)
                .background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(tint).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
}

private struct PaperCaption: View {
    let caption: Caption
    let mode: SubtitleDisplayMode
    let textWidth: CGFloat
    let shortWindow: Bool
    var japaneseFont = ""
    var chineseFont = ""
    var japaneseSize: Double = 16
    var chineseSize: Double = 20
    // Window height reveals more lines/history; it must never inflate fonts.
    private var originalSize: CGFloat { max(12, japaneseSize) }
    private var translatedSize: CGFloat { max(12, chineseSize) }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .center, spacing: shortWindow ? 2 : 5) {
            if mode == .original || caption.isOriginalOnly {
                Text(SubtitleLineLayout.format(caption.original, language: caption.sourceLanguage.layoutLanguage, width: textWidth, font: SubtitleFont.native(japaneseFont, size: originalSize)))
                    .font(Font(SubtitleFont.native(japaneseFont, size: originalSize)))
                    .foregroundStyle(caption.isDraft ? ThemeColor.muted : ThemeColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
            if mode == .bilingual && caption.original != caption.translated {
                Text(SubtitleLineLayout.format(caption.original, language: caption.sourceLanguage.layoutLanguage, width: textWidth, font: SubtitleFont.native(japaneseFont, size: originalSize)))
                    .font(Font(SubtitleFont.native(japaneseFont, size: originalSize)))
                    .foregroundStyle(ThemeColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chinese = SubtitleDocument.completedTranslation(caption) {
                Text(SubtitleLineLayout.format(chinese, language: caption.targetLanguage.layoutLanguage, width: textWidth, font: SubtitleFont.native(chineseFont, size: translatedSize, weight: .medium))).font(Font(SubtitleFont.native(chineseFont, size: translatedSize, weight: .medium)))
                    .foregroundStyle(caption.isDraft ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成")
                     ? L10n.text("翻译未完成") : L10n.text("正在翻译…"))
                    .font(.system(size: 14)).foregroundStyle(ThemeColor.muted)
                    .help(caption.translated)
            }
            }
        }
        .lineSpacing(shortWindow ? 0 : 4)
        .multilineTextAlignment(.center)
        .frame(maxWidth: textWidth, alignment: .center)
        .textSelection(.enabled)
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
            ForEach(SubtitleDisplayMode.allCases) { mode in
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
