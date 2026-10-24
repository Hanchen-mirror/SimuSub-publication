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
    @State private var pointerInside = false
    @State private var showingExport = false
    @State private var showingClearConfirmation = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "subtitle.paper.bottom"

    private var compact: Bool { SubtitleDensity.forSize(size) == .compact }
    private var paperInset: CGFloat { size.height < 120 ? 4 : 10 }

    var body: some View {
        ZStack {
            if captions.isEmpty {
                Text(idleText).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(compact ? 1 : nil)
                    .truncationMode(.tail).help(idleText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.leading, 112).padding(.trailing, compact ? 190 : 112)
            } else if compact, let latest = captions.last {
                HStack(spacing: 6) {
                    if displayMode == .bilingual {
                        Text(compactLine(latest.original, original: true)).font(.system(size: 14)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .trailing)
                        Text("｜").foregroundStyle(.tertiary)
                    }
                    Text(compactLine(SubtitleDocument.completedTranslation(latest) ?? (latest.translated.hasPrefix("翻译失败") || latest.translated.hasPrefix("译文未完成") ? "翻译未完成" : "正在翻译…"), original: false))
                        .font(.system(size: 16, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: displayMode == .bilingual ? .leading : .center)
                }
                .help(compactText(latest))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.leading, 112).padding(.trailing, 190)
            } else {
                ScrollViewReader { reader in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .center, spacing: 18) {
                            ForEach(captions) { caption in
                                PaperCaption(caption: caption, mode: displayMode, textWidth: max(24, size.width - 224), shortWindow: size.height < 120).id(caption.id)
                            }
                            Color.clear.frame(height: 1).id(bottomID)
                        }
                        .frame(minHeight: max(0, size.height - paperInset * 2), alignment: captions.count <= 1 ? .center : .bottom)
                        .padding(.horizontal, 112).padding(.vertical, paperInset)
                    }
                    .onAppear { reader.scrollTo(bottomID, anchor: .bottom) }
                    .onChange(of: captions.last) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                    .onChange(of: displayMode) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                    .onChange(of: size) { _ in reader.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SubtitleGlassBackground()
                .overlay(Color(white: colorScheme == .dark ? 0.12 : 0.98).opacity(colorScheme == .dark ? 0.12 : 0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: compact ? .leading : .topLeading) {
            SubtitleNativeControls(onZoom: onZoom, onClose: onClose).frame(width: 66, height: 26)
                .padding(.leading, 8).padding(.top, compact ? 0 : 3)
        }
        .overlay(alignment: .leading) { playbackButton.padding(.leading, compact ? 80 : 8) }
        .overlay(alignment: .trailing) { rightControls.padding(.trailing, 8) }
        .contentShape(Rectangle())
        .onHover { pointerInside = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displayMode == .chinese ? "中文字幕" : "日中双语字幕")
        .alert("清空所有字幕？", isPresented: $showingClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("清空 \(captions.count) 条字幕", role: .destructive, action: onClear)
        } message: {
            Text("将删除当前保存的全部原文、译文和待处理字幕，无法恢复。已导出的文件不受影响。\(isCapturing ? "清空后将继续监听所选应用。" : "")")
        }
    }

    private func compactText(_ caption: Caption) -> String {
        let chinese = SubtitleDocument.completedTranslation(caption) ?? caption.translated
        let text = displayMode == .bilingual ? caption.original + " ｜ " + chinese : chinese
        return text
    }

    private func compactLine(_ text: String, original: Bool) -> String {
        let available = max(24, size.width - 302)
        let width = displayMode == .bilingual ? max(24, (available - 24) / 2) : available
        // A one-row strip follows the current tail; the full text remains in
        // history, in the hover description, and in exports.
        return SubtitleLineLayout.format(text, language: original ? .japanese : .chinese, width: width,
            font: .systemFont(ofSize: original ? 14 : 16, weight: original ? .regular : .medium))
            .components(separatedBy: "\n").last ?? text
    }

    private var controlsVisible: Bool { pointerInside || captions.isEmpty || isBusy || showingExport || showingClearConfirmation }

    private var playbackButton: some View {
        Group {
            if let onStartStop {
                if isBusy { ProgressView().controlSize(.small).frame(width: 26, height: 26) }
                else {
                    toolButton(isCapturing ? "pause.fill" : "play.fill",
                               title: isCapturing ? "暂停同传" : "开始／继续同传",
                               tint: .accentColor, action: onStartStop)
                        .disabled(!canStartStop)
                        .accessibilityIdentifier("subtitle.playback")
                }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controlsVisible)
    }

    private var rightControls: some View {
        Group {
            if compact {
                HStack(spacing: 4) { pinButton; homeButton; languageButton; exportButton; clearButton; settingsButton }
            } else {
                HStack(spacing: 4) {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) { pinButton; homeButton }
                        HStack(spacing: 4) { languageButton; exportButton }
                    }
                    VStack(spacing: 4) { clearButton; settingsButton }
                }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controlsVisible)
    }

    private var pinButton: some View {
        toolButton(isPinned ? "pin.fill" : "pin", title: isPinned ? "取消置顶" : "置顶字幕",
                   tint: isPinned ? .accentColor : .primary, action: onTogglePin)
            .accessibilityIdentifier("subtitle.pin")
    }
    private var homeButton: some View {
        toolButton("house", title: "返回首页（⌘⇧F）", action: onExit).accessibilityIdentifier("subtitle.home")
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

    private var settingsButton: some View {
        toolButton("gearshape", title: "字幕设置 · 术语库与翻译模型", action: onSettings)
            .accessibilityIdentifier("subtitle.settings")
    }

    private var clearButton: some View {
        toolButton("trash", title: "清空所有字幕…", action: { showingClearConfirmation = true })
            .disabled(!canClear).accessibilityIdentifier("subtitle.clear")
    }

    private func toolButton(_ symbol: String, title: String, tint: Color = .primary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
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
    private var typeLevel: Int {
        guard shortWindow else { return 0 }
        let originalRows = mode == .bilingual ? SubtitleLineLayout.format(caption.original, language: .japanese,
            width: textWidth, font: .systemFont(ofSize: 16)).components(separatedBy: "\n").count : 0
        let translatedRows = SubtitleLineLayout.format(SubtitleDocument.completedTranslation(caption) ?? "正在翻译…",
            language: .chinese, width: textWidth, font: .systemFont(ofSize: 20, weight: .medium)).components(separatedBy: "\n").count
        return min(2, max(0, originalRows + translatedRows - 2))
    }
    private var originalSize: CGFloat { 16 - CGFloat(typeLevel) * 2 }
    private var translatedSize: CGFloat { 20 - CGFloat(typeLevel) * 2 }

    var body: some View {
        VStack(alignment: .center, spacing: shortWindow ? 2 : 5) {
            if !caption.recognitionNotice.isEmpty {
                Text("日语识别有修订 · 记录中可核对").font(.system(size: 10)).foregroundStyle(.orange)
                    .help(caption.recognitionNotice)
            }
            if caption.isDraft && !caption.confirmedPrefix.isEmpty {
                Text("前段已确认 · 后文识别中").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(caption.confirmedPrefix)
            }
            if mode == .bilingual {
                Text(SubtitleLineLayout.format(caption.original, language: .japanese, width: textWidth, font: .systemFont(ofSize: originalSize)))
                    .font(.system(size: originalSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let chinese = SubtitleDocument.completedTranslation(caption) {
                Text(SubtitleLineLayout.format(chinese, language: .chinese, width: textWidth, font: .systemFont(ofSize: translatedSize, weight: .medium))).font(.system(size: translatedSize, weight: .medium))
                    .foregroundStyle(caption.isDraft ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption.translated.hasPrefix("翻译失败") || caption.translated.hasPrefix("译文未完成")
                     ? "翻译未完成" : "正在翻译…")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .help(caption.translated)
            }
        }
        .lineSpacing(shortWindow ? 0 : 4)
        .multilineTextAlignment(.center)
        .frame(maxWidth: min(textWidth, 480), alignment: .center)
        .textSelection(.enabled)
    }
}

private struct SubtitleExportPicker: View {
    var onSelect: (SubtitleExportFormat) -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出字幕").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
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
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: format == .txt ? "doc.plaintext" : "captions.bubble")
                    .font(.system(size: 21, weight: .light))
                Text(format.title).font(.system(size: 12, weight: .medium))
            }
            .frame(width: 64, height: 66)
            .background(Color.accentColor.opacity(hovered ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 12))
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

    var body: some View {
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
