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
    @State private var showingHistory = false
    @State private var showingClearConfirmation = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bottomID = "subtitle.paper.bottom"

    private var compact: Bool { SubtitleDensity.forSize(size) == .compact }
    private var paperInset: CGFloat { size.height < 120 ? 4 : 10 }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SubtitleNativeControls(onZoom: onZoom, onClose: onClose).frame(width: 66, height: 26)
                playbackButton
                Spacer(minLength: 0)
                languageButton; exportButton; pinButton
                Menu {
                    Button("字幕记录") { showingHistory = true }
                    Button("返回主界面", action: onExit)
                    Button("清空字幕", role: .destructive) { showingClearConfirmation = true }.disabled(!canClear)
                } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26)
            }.padding(.horizontal, 8).frame(height: 34)
            GeometryReader { geometry in
                if let latest = captions.last {
                    let chinese = SubtitleDocument.completedTranslation(latest) ?? (latest.translated.hasPrefix("翻译失败") ? "翻译未完成" : "正在翻译…")
                    let ratio = japaneseSize / max(1, chineseSize)
                    let fitted = SubtitleAdaptiveType.fit(original: displayMode == .bilingual ? latest.original : "", translated: chinese,
                        size: CGSize(width: max(20, geometry.size.width - 50), height: max(10, geometry.size.height - 22)), ratio: ratio, japaneseFont: japaneseFont, chineseFont: chineseFont)
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: max(3, fitted * 0.2)) {
                            if displayMode == .bilingual { Text(latest.original).font(Font(SubtitleFont.native(japaneseFont, size: fitted * ratio))).foregroundStyle(ThemeColor.muted).fixedSize(horizontal: false, vertical: true) }
                            Text(chinese).font(Font(SubtitleFont.native(chineseFont, size: fitted, weight: .semibold))).foregroundStyle(ThemeColor.ink).fixedSize(horizontal: false, vertical: true)
                        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(minHeight: max(0, geometry.size.height - 22))
                            .padding(.horizontal, 25).padding(.bottom, 22).textSelection(.enabled)
                    }.accessibilityIdentifier("subtitle.adaptiveText")
                } else {
                    Text(idleText).font(.system(size: 15, weight: .medium)).foregroundStyle(ThemeColor.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(ThemeColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .popover(isPresented: $showingHistory) {
            ScrollView {
                VStack(spacing: 22) { ForEach(captions) { caption in PaperCaption(caption: caption, mode: displayMode, textWidth: 460, shortWindow: false, japaneseFont: japaneseFont, chineseFont: chineseFont, japaneseSize: japaneseSize, chineseSize: chineseSize) } }.padding(24)
            }.frame(width: 510, height: 420).background(ThemeColor.surface)
        }
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
            font: SubtitleFont.native(original ? japaneseFont : chineseFont, size: original ? max(12, japaneseSize - 2) : max(14, chineseSize - 4), weight: original ? .regular : .medium))
            .components(separatedBy: "\n").last ?? text
    }

    private var controlsVisible: Bool { true }

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

    private var clearButton: some View {
        toolButton("trash", title: "清空所有字幕…", action: { showingClearConfirmation = true })
            .disabled(!canClear).accessibilityIdentifier("subtitle.clear")
    }

    private func toolButton(_ symbol: String, title: String, tint: Color = .primary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain).foregroundStyle(tint).help(title).accessibilityLabel(title)
    }
}

enum SubtitleAdaptiveType {
    static func fit(original: String, translated: String, size: CGSize, ratio: Double, japaneseFont: String = "", chineseFont: String = "") -> CGFloat {
        func height(_ text: String, font: NSFont) -> CGFloat {
            guard !text.isEmpty else { return 0 }
            return (text as NSString).boundingRect(with: NSSize(width: max(1, size.width), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        }
        var low: CGFloat = 9, high: CGFloat = 100
        for _ in 0..<14 {
            let point = (low + high) / 2
            let required = height(original, font: SubtitleFont.native(japaneseFont, size: point * ratio)) + height(translated, font: SubtitleFont.native(chineseFont, size: point, weight: .semibold)) + (original.isEmpty ? 0 : max(3, point * 0.2)) + 8
            if required <= size.height { low = point } else { high = point }
        }
        return floor(low)
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
    private var typeLevel: Int {
        guard shortWindow else { return 0 }
        let originalRows = mode == .bilingual ? SubtitleLineLayout.format(caption.original, language: .japanese,
            width: textWidth, font: SubtitleFont.native(japaneseFont, size: japaneseSize)).components(separatedBy: "\n").count : 0
        let translatedRows = SubtitleLineLayout.format(SubtitleDocument.completedTranslation(caption) ?? "正在翻译…",
            language: .chinese, width: textWidth, font: SubtitleFont.native(chineseFont, size: chineseSize, weight: .medium)).components(separatedBy: "\n").count
        return min(2, max(0, originalRows + translatedRows - 2))
    }
    private var originalSize: CGFloat { max(12, japaneseSize - CGFloat(typeLevel) * 2) }
    private var translatedSize: CGFloat { max(14, chineseSize - CGFloat(typeLevel) * 2) }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .center, spacing: shortWindow ? 2 : 5) {
            if let candidate = caption.pendingOriginal {
                Text("待核对候选：" + candidate).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
            if !caption.recognitionNotice.isEmpty {
                Text("日语识别有修订 · 记录中可核对").font(.system(size: 10)).foregroundStyle(.orange)
                    .help(caption.recognitionNotice)
            }
            if caption.isDraft && !caption.confirmedPrefix.isEmpty {
                Text("前段已确认 · 后文识别中").font(.system(size: 10)).foregroundStyle(ThemeColor.muted)
                    .help(caption.confirmedPrefix)
            }
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
        .frame(maxWidth: min(textWidth, 480), alignment: .center)
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
