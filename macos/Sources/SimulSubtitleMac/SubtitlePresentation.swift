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
    var onSettings: () -> Void = {}
    var japaneseFont = ""
    var chineseFont = ""
    var japaneseSize: Double = 16
    var chineseSize: Double = 20
    @State private var pointerInside = false
    @State private var showingExport = false
    @State private var showingClearConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "subtitle.paper.bottom"
    private var compact: Bool { size.height < 80 }
    private var singleRowControls: Bool { true }
    private var controlSize: CGFloat { compact ? 20 : 26 }
    private var controlSpacing: CGFloat { compact ? 2 : 4 }
    // Equal gutters preserve the window center with either six-button layout.
    private var textInset: CGFloat { compact ? 146 : 16 }
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
                Text(idleText).font(.system(size: 15, weight: .medium)).foregroundStyle(ThemeColor.muted)
                    .multilineTextAlignment(.center).lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail).help(idleText)
                    .frame(width: textWidth, height: max(1, contentHeight - paperInset * 2))
                    .accessibilityIdentifier("subtitle.idleText")
            } else if compact, let latest = captions.last {
                HStack(spacing: 6) {
                    if displayMode == .bilingual {
                        Text(compactLine(latest.original, original: true))
                            .font(Font(SubtitleFont.native(japaneseFont, size: min(japaneseSize, 14))))
                            .foregroundStyle(ThemeColor.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text("｜").foregroundStyle(ThemeColor.muted)
                    }
                    Text(compactLine(translation(latest), original: false))
                        .font(Font(SubtitleFont.native(chineseFont, size: min(chineseSize, 16), weight: .medium)))
                        .foregroundStyle(ThemeColor.ink)
                        .frame(maxWidth: .infinity, alignment: displayMode == .bilingual ? .leading : .center)
                }
                .lineLimit(1).help(compactText(latest))
                .frame(width: textWidth, height: max(1, contentHeight - paperInset * 2))
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .center, spacing: 18) {
                            ForEach(captions) { caption in
                                PaperCaption(caption: caption, mode: displayMode, textWidth: textWidth,
                                    shortWindow: size.height < 120, japaneseFont: japaneseFont, chineseFont: chineseFont,
                                    japaneseSize: japaneseSize, chineseSize: chineseSize).id(caption.id)
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
        .accessibilityLabel(displayMode == .chinese ? "中文字幕" : "日中双语字幕")
        .alert("清空所有字幕？", isPresented: $showingClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("清空 \(captions.count) 条字幕", role: .destructive, action: onClear)
        } message: {
            Text("将删除当前保存的全部原文、译文和待处理字幕，无法恢复。已导出的文件不受影响。\(isCapturing ? "清空后将继续监听所选应用。" : "")")
        }
    }

    private func translation(_ caption: Caption) -> String {
        SubtitleDocument.completedTranslation(caption)
            ?? (caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成") ? "翻译未完成" : "正在翻译…")
    }

    private func compactText(_ caption: Caption) -> String {
        let chinese = SubtitleDocument.completedTranslation(caption) ?? caption.translated
        let text = displayMode == .bilingual ? caption.original + " ｜ " + chinese : chinese
        return text
    }

    private func compactLine(_ text: String, original: Bool) -> String {
        let available = textWidth
        let width = displayMode == .bilingual ? max(24, (available - 24) / 2) : available
        let font = SubtitleFont.native(original ? japaneseFont : chineseFont,
            size: original ? min(japaneseSize, 14) : min(chineseSize, 16), weight: original ? .regular : .medium)
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
        pointerInside || showingExport || showingClearConfirmation
    }

    private var rightControls: some View {
        Group {
            if singleRowControls {
                HStack(spacing: controlSpacing) { pinButton; homeButton; languageButton; exportButton; clearButton; settingsButton }
            } else {
                HStack(spacing: controlSpacing) {
                    VStack(spacing: controlSpacing) {
                        HStack(spacing: controlSpacing) { pinButton; homeButton }
                        HStack(spacing: controlSpacing) { languageButton; exportButton }
                    }
                    VStack(spacing: controlSpacing) { clearButton; settingsButton }
                }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controlsVisible)
    }

    private var homeButton: some View {
        toolButton("house", title: "返回首页（⌘⇧F）", action: onExit).accessibilityIdentifier("subtitle.home")
    }
    private var settingsButton: some View {
        toolButton("gearshape", title: "字幕设置", action: onSettings)
            .accessibilityIdentifier("subtitle.settings")
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
        toolButton(displayMode == .bilingual ? "rectangle.split.2x1" : "rectangle",
                   title: displayMode == .bilingual ? "日中双语 · 点击切换为仅中文" : "仅中文 · 点击切换为日中双语", action: onToggleDisplayMode)
            .accessibilityValue(displayMode.rawValue).accessibilityIdentifier("subtitle.displayMode")
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
        .buttonStyle(.plain).foregroundStyle(tint).help(title).accessibilityLabel(title)
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
            if mode == .bilingual {
                Text(SubtitleLineLayout.format(caption.original, language: .japanese, width: textWidth, font: SubtitleFont.native(japaneseFont, size: originalSize)))
                    .font(Font(SubtitleFont.native(japaneseFont, size: originalSize)))
                    .foregroundStyle(ThemeColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chinese = SubtitleDocument.completedTranslation(caption) {
                Text(SubtitleLineLayout.format(chinese, language: .chinese, width: textWidth, font: SubtitleFont.native(chineseFont, size: translatedSize, weight: .medium))).font(Font(SubtitleFont.native(chineseFont, size: translatedSize, weight: .medium)))
                    .foregroundStyle(caption.isDraft ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成")
                     ? "翻译未完成" : "正在翻译…")
                    .font(.system(size: 14)).foregroundStyle(ThemeColor.muted)
                    .help(caption.translated)
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
            Text("导出字幕").font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.muted)
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
        .help("导出 \(format.title)").accessibilityLabel("导出 \(format.title)")
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
        Button(model.isSubtitleOnly ? "退出纯字幕" : "进入纯字幕") {
            model.isSubtitleOnly.toggle()
        }.keyboardShortcut("b", modifiers: [.command, .shift])
        Button("恢复完整界面") { model.isSubtitleOnly = false }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        Divider()
        Toggle("纯字幕置顶", isOn: $model.isSubtitlePinned)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Picker("字幕显示", selection: $model.subtitleDisplayMode) {
            ForEach(SubtitleDisplayMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        Divider()
        Button(model.isCapturing ? "暂停字幕" : "开始／继续字幕") {
            model.isSubtitleOnly = true
            model.toggleSubtitlePlayback()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model.isStarting || model.isStopping || model.isProcessingFile)
        Menu("导出字幕") {
            ForEach(SubtitleExportFormat.allCases) { format in
                Button(format.title) { model.exportCaptions(format: format) }
            }
        }.disabled(model.captions.isEmpty)
    }
}
