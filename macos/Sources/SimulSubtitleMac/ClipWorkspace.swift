import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ClipWorkspace: View {
    var creatorID: UUID?
    var initialTool: ClipWorkspaceTool = .edit
    var onBack: () -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @EnvironmentObject private var clips: ClipStore
    @EnvironmentObject private var model: AppModel
    @State private var showingLibrary = false
    @State private var removing = false
    @State private var pendingProjectRemoval: UUID?
    @State private var importing = false
    @State private var entered = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            if let project = clips.selected {
                ClipEditor(project: project, onImport: importVideo, onBack: { clips.selectedID = nil }, onLibrary: { showingLibrary = true }, onRemove: { pendingProjectRemoval = project.id; removing = true }).id(project.id)
            } else {
                importPage
            }
            if let job = clips.currentJob ?? clips.jobs.first(where: { $0.projectID == clips.selectedID }) {
                jobBar(job)
            }
        }.buttonStyle(ClipActionButtonStyle()).background(ClipTheme.background)
            .onAppear {
                guard !entered else { return }; entered = true
                if let creatorID, clips.selected?.creatorID != creatorID {
                    if let existing = clips.projects.first(where: { $0.creatorID == creatorID }) { clips.selectedID = existing.id }
                    else if let recording = monitor.recordings.first(where: { $0.creatorID == creatorID && !$0.closedMediaURLs.isEmpty }), let url = recording.closedMediaURLs.last {
                        load(url, creator: creatorID, name: recording.creatorName)
                    }
                }
            }
            .sheet(isPresented: $showingLibrary) { library }
            .confirmationDialog(L10n.text("移出当前项目？原视频和导出文件会保留。"), isPresented: $removing, titleVisibility: .visible) {
                Button(L10n.text("移出工作台")) { if let id = pendingProjectRemoval { withAnimation(.easeInOut(duration: 0.2)) { clips.removeProject(id) } }; pendingProjectRemoval = nil }
                Button(L10n.text("取消"), role: .cancel) {}
            }
            .alert(L10n.text("剪辑工作台"), isPresented: Binding(get: { clips.notice != nil }, set: { if !$0 { clips.notice = nil } })) { Button(L10n.text("知道了")) { clips.notice = nil } } message: { Text(clips.notice ?? "") }
            .accessibilityIdentifier("clips.workspace")
    }
    private var importPage: some View {
        GeometryReader { geometry in
            let metrics = WorkspaceMetrics(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 12) {
                        Button(action: onBack) {
                            Image(systemName: "arrow.left").frame(width: 32, height: 32).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(ThemeColor.muted)
                            .help(L10n.text("返回工作空间")).accessibilityLabel(L10n.text("返回工作空间"))
                            .accessibilityIdentifier("clips.back")
                        Text(L10n.text("剪辑工作台")).interfaceFont(size: 24, weight: .semibold)
                    }
                    VStack(spacing: 18) {
                        Image(systemName: "scissors").interfaceFont(size: 27, weight: .light).foregroundStyle(ThemeColor.primary).frame(width: 66, height: 66).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 22))
                        Text(L10n.text(importing ? "正在导入…" : "把视频放到这里")).interfaceFont(size: 23, weight: .semibold)

                        Button(action: importVideo) { Label(L10n.text("打开视频"), systemImage: "plus") }.buttonStyle(ThemeActionButtonStyle(prominent: true)).disabled(importing || clips.isBusy).accessibilityIdentifier("clips.import")

                    }.frame(maxWidth: .infinity).frame(minHeight: max(180, min(368, geometry.size.height * 0.48)))
                        .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(ThemeColor.primary, style: StrokeStyle(lineWidth: 1, dash: [3,2])))
                        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                            guard !importing, !clips.isBusy, let provider = providers.first else { return false }
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                                if let url { Task { @MainActor in load(url, creator: creatorID, name: nil) } }
                            }
                            return true
                        }
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Text(L10n.text("最近项目")).interfaceFont(size: 15, weight: .semibold)
                            Spacer()
                            Button { showingLibrary = true } label: {
                                Label(L10n.text("项目与录制历史"), systemImage: "clock.arrow.circlepath")
                            }.buttonStyle(.plain).foregroundStyle(ThemeColor.primaryInk)
                                .accessibilityIdentifier("clips.history")
                        }
                        if clips.projects.isEmpty { Text(L10n.text("暂无项目")).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted) }
                        ForEach(clips.projects.prefix(4)) { project in
                            Divider().overlay(ThemeColor.line)
                            HStack(spacing: 14) {
                                Button { withAnimation(.easeInOut(duration: 0.2)) { clips.selectedID = project.id } } label: {
                                    HStack(spacing: 14) {
                                        if let path = project.posterPath, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 108, height: 60).clipped().clipShape(RoundedRectangle(cornerRadius: 8)) }
                                        else { Image(systemName: "film").frame(width: 108, height: 60).background(ThemeColor.soft) }
                                        Text(project.name); Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { pendingProjectRemoval = project.id; removing = true } label: { Image(systemName: "xmark").font(.system(size: 10)).frame(width: 28, height: 28) }.buttonStyle(.plain).help(L10n.text("移出工作台"))
                            }.disabled(clips.isBusy)

                        }
                    }.designPanel(inset: metrics.cardInset)
                }.padding(metrics.gutter)
            }.accessibilityIdentifier("clips.importPage")
        }.background(ThemeColor.background)
    }
    private func jobBar(_ job: ClipJob) -> some View {
        HStack(spacing: 12) {
            if job.state == .running {
                ProgressView(value: job.progress).frame(width: 100)
            } else {
                Image(systemName: job.state == .completed ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(job.state == .completed ? ThemeColor.primaryInk : Color.orange)
            }
            Text(L10n.text(job.message)).font(.caption).lineLimit(3).textSelection(.enabled)
            Spacer()
            if job.state == .running {
                Button(L10n.text("暂停"), action: clips.pause)
                Button(L10n.text("取消"), action: clips.cancel)
            } else if job.state == .completed, let path = job.exportReceipts?.first?.mediaPath {
                Button(L10n.text("查看成片")) { clips.reveal(path) }
            } else if [.failed, .interrupted, .paused, .cancelled].contains(job.state) {
                Button(L10n.text("按已保存设置重试")) { clips.start(job, model: model) }
            }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(ThemeColor.soft)
    }
    private var library: some View {
        ClipLibrarySheet(onProject: { clips.selectedID = $0; showingLibrary = false },
            onRecording: { recording, url in load(url, creator: recording.creatorID, name: recording.creatorName); showingLibrary = false },
            onImport: { showingLibrary = false; DispatchQueue.main.async { importVideo() } },
            onClose: { showingLibrary = false }).appTheme()
    }
    private func importVideo() {
        guard !importing, !clips.isBusy else { return }
        let panel = NSOpenPanel(); panel.title = "导入视频"; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["mp4", "mkv", "mov", "webm", "flv", "m4v"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { load(url, creator: creatorID, name: nil) }
    }
    private func load(_ url: URL, creator: UUID?, name: String?) {
        importing = true
        Task { defer { importing = false }; do {
            let recording = monitor.recordings.first { $0.mediaURLs.contains(url) }
            let grouping: [String]? = recording.map {
                let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
                return [LiveRecordingEngine.safeName($0.creatorName) + "-" + $0.platform.title, date.string(from: $0.broadcastStartedAt ?? $0.startedAt)]
            }
            try await clips.importVideo(url, creatorID: creator, name: name, outputGrouping: grouping)
        } catch { clips.notice = ClipFailure.message(error, operation: "导入视频") } }
    }
}

struct ClipEditor: View {
    var project: ClipProject
    var onImport: () -> Void = {}
    var onBack: () -> Void = {}
    var onLibrary: () -> Void = {}
    var onRemove: () -> Void = {}
    @State private var rightTab = 0
    @State private var selectedCueID: UUID?
    @EnvironmentObject private var clips: ClipStore
    @EnvironmentObject private var model: AppModel
    @State private var working: ClipRange
    @State private var startText = ""
    @State private var endText = ""
    @State private var configured = true
    @State private var burn = true
    @State private var editing: Caption?
    @State private var showingImport = false
    @State private var showingProofread = false
    @State private var showingStyle = false
    @State private var showingHighlights = false
    @State private var draftStyle = ClipSubtitleStyle.classic
    @State private var previewing: URL?
    @State private var movingSubtitles = false
    @State private var draggedStyle: ClipSubtitleStyle?
    @State private var pendingRecommendation: Int?
    @State private var removeID: UUID?
    @State private var undoStack: [ClipProject] = []
    @State private var gestureSnapshot: ClipProject?
    @State private var renameRange: ClipRange?
    @State private var chooseExportFolder = false
    @State private var showingExport = false
    @State private var showingTimes = false
    @State private var textUndoCue: UUID?
    @StateObject private var playback: ClipPlayback
    init(project: ClipProject, onImport: @escaping () -> Void = {}, onBack: @escaping () -> Void = {}, onLibrary: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}) {
        self.project = project; self.onImport = onImport; self.onBack = onBack; self.onLibrary = onLibrary; self.onRemove = onRemove
        _working = State(initialValue: project.ranges.first ?? ClipRange(title: "选段 1", start: 0, end: min(60, project.media.duration)))
        _playback = StateObject(wrappedValue: ClipPlayback(url: project.media.url))
    }
    private var active: ClipRange {
        var value = project.ranges.first(where: { $0.id == working.id }) ?? working
        value.start = working.start; value.end = working.end; value.title = working.title
        return value
    }
    private var hasRange: Bool { project.ranges.contains { $0.id == working.id } }
    private var cues: [Caption] { hasRange ? project.captions(for: active) : [] }
    private var sample: Caption { cues.first ?? Caption(start: 0, end: 4, original: "今日はここから始めましょう。", translated: "今天我们从这里开始。") }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            let metrics = WorkspaceMetrics(width: geometry.size.width)
            let width = max(1, geometry.size.width - metrics.gutter * 2)
            let inspectorWidth = min(420, max(300, width * 0.34))
            let videoWidth = metrics.stacked ? width : width - inspectorWidth - metrics.gap
            let aspect = CGFloat(project.media.height) / CGFloat(max(1, project.media.width))
            let heightLimit = metrics.stacked ? 360 : max(180, min(440, geometry.size.height - 330))
            let videoHeight = max(120, min(heightLimit, videoWidth * aspect))
            let controls = metrics.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    editorToolbar
                    metrics.columns {
                        VStack(alignment: .leading, spacing: 12) {
                            ClipStyledPlayer(player: playback.player, captions: cues, style: showingStyle ? draftStyle : (draggedStyle ?? active.style),
                                mediaSize: CGSize(width: project.media.width, height: project.media.height),
                                onStyle: { style, commit in
                                    if gestureSnapshot == nil { gestureSnapshot = project }
                                    draggedStyle = style
                                    if commit { finishGesture(); applyStyle(style); draggedStyle = nil }
                                })
                                .frame(height: videoHeight).clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Text(ClipTime.label(playback.time) + " / " + ClipTime.label(project.media.duration)).font(.caption).monospacedDigit().foregroundStyle(ThemeColor.muted)
                                Spacer()
                                DesignMenuField(title: String(format: "%g×", playback.speed), height: 30) {
                                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button(String(format: "%g×", rate)) { playback.speed = rate } }
                                }.frame(width: 62)
                                editorIcon(playback.player.rate == 0 ? "play" : "pause", title: "播放 / 暂停", action: playback.toggle)
                            }
                        }.frame(maxWidth: .infinity).accessibilityIdentifier("clips.videoPanel")
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text(L10n.text("字幕")).interfaceFont(size: 16, weight: .semibold); Spacer()
                                editorIcon("lightbulb", title: "生成字幕", action: transcribe)
                                    .accessibilityIdentifier("clips.transcribe")
                                editorIcon("checkmark.bubble", title: "核对译文", action: { showingProofread = true })
                                    .disabled(cues.isEmpty).accessibilityIdentifier("clips.proofread")
                                editorIcon("tray.and.arrow.down", title: "导入字幕", action: importSubtitles)
                                    .accessibilityIdentifier("clips.importSubtitles")
                                Menu {
                                    ForEach(SubtitleExportFormat.allCases) { format in
                                        Button(format.title) { exportSubtitles(format) }
                                    }
                                } label: {
                                    Image(systemName: "tray.and.arrow.up").interfaceFont(size: 14, weight: .medium)
                                        .frame(width: 32, height: 32)
                                        .foregroundStyle(ThemeColor.primaryInk)
                                        .background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32)
                                .help(L10n.text("导出字幕")).accessibilityLabel(L10n.text("导出字幕"))
                                .accessibilityIdentifier("clips.exportSubtitles").disabled(cues.isEmpty)
                                editorIcon("slider.horizontal.3", title: "字幕样式", action: { draftStyle = active.style; remember(); playback.player.pause(); if let cue = cues.first, !cues.contains(where: { playback.time >= $0.start && playback.time < $0.end }) { playback.seek(cue.start) }; showingStyle = true })
                                    .accessibilityIdentifier("clips.customStyle")
                            }.buttonStyle(.plain).disabled(!hasRange || clips.isBusy)
                            subtitleColumn
                        }.padding(metrics.cardInset).frame(maxWidth: .infinity, alignment: .leading)
                            .frame(width: metrics.stacked ? nil : inspectorWidth,
                                   height: metrics.stacked ? 260 : max(236, videoHeight + 44))
                            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("clips.inspector")
                    }
                    rangePanel(metrics)
                }.padding(.horizontal, metrics.gutter).padding(.vertical, 24)
            }.accessibilityIdentifier(metrics.stacked ? "clips.layout.stacked" : "clips.layout.columns")
        }
            .onAppear { syncTimes(); if !project.ranges.isEmpty { playback.select(working.start...working.end) } }
            .onDisappear { playback.player.pause() }
            .onChange(of: clips.jobs.first?.state) { state in
                if let count = pendingRecommendation, let job = clips.jobs.first, job.projectID == project.id, job.kind == .transcribe, state != .running {
                    pendingRecommendation = nil
                    if state == .completed { clips.start(ClipJob(projectID: project.id, kind: .recommend, recommendationCount: count), model: nil) }
                }
            }
            .onChange(of: project.ranges.map(\.id)) { ids in
                if !ids.contains(working.id) { if let next = project.ranges.first { working = next; syncTimes(); playback.select(next.start...next.end) } else { playback.clearSelection() } }
            }
            .sheet(item: $editing) { cue in ClipCaptionEditor(projectID: project.id, range: active, cue: cue).appTheme() }
            .sheet(isPresented: $showingStyle, onDismiss: { applyStyle(draftStyle) }) {
                ClipStyleEditor150(player: playback.player, captions: cues, mediaSize: CGSize(width: project.media.width, height: project.media.height), style: $draftStyle, onClose: { showingStyle = false }).appTheme()
            }
            .sheet(item: $renameRange) { range in
                VStack(spacing: 18) {
                    Text(L10n.text("片段名称")).font(.headline)
                    TextField("", text: Binding(get: { renameRange?.title ?? range.title }, set: { renameRange?.title = $0 })).textFieldStyle(ClipFieldStyle())
                    Button(L10n.text("完成")) { if let next = renameRange, !next.title.trimmingCharacters(in: .whitespaces).isEmpty { remember(); clips.saveRange(project.id, range: next); if working.id == next.id { working.title = next.title } }; renameRange = nil }
                }.padding(24).frame(width: 340).background(ThemeColor.surface).appTheme()
            }
            .sheet(isPresented: $showingExport, onDismiss: {
                if chooseExportFolder { chooseExportFolder = false; export(.mp4, subtitles: burn) }
            }) { exportSelection }
            .sheet(isPresented: $showingProofread) { proofreadSheet }
            .sheet(isPresented: $showingHighlights) {
                VStack {
                    HStack { Text(L10n.text("高光候选")).interfaceFont(size: 14, weight: .semibold); Spacer(); Button(L10n.text("完成")) { showingHighlights = false } }
                    ClipHighlightsPanel(project: project, onRecommend: recommend, onEdit: { r in remember(); clips.saveRange(project.id, range: r); working = r; syncTimes(); showingHighlights = false }, onPreview: { r in working = r; syncTimes(); showingHighlights = false; playback.select(r) })
                }.padding(22).frame(width: 700, height: 520).background(ThemeColor.background)
            }
            .sheet(isPresented: Binding(get: { previewing != nil }, set: { if !$0 { previewing = nil } })) {
                if let previewing { ClipVideoPreview(url: previewing, offset: project.previewStart ?? 0, hasSubtitles: project.previewHasSubtitles ?? false,
                    onSetStart: { working.start = min($0, working.end - 0.2); syncTimes(); _ = saveWorking() }, onSetEnd: { working.end = max($0, working.start + 0.2); syncTimes(); _ = saveWorking() }, onClose: { self.previewing = nil }) }
            }
            .confirmationDialog(L10n.text("移除这个选段？原视频和已导出文件会保留。"), isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
                Button(L10n.text("移除选段"), action: removeSelectedRange)
            }
    }
    private func removeSelectedRange() {
        guard let id = removeID else { return }
        remember()
        playback.player.pause()
        let remaining = project.ranges.filter { $0.id != id }
        clips.update(project.id) { $0.ranges = remaining }
        if let next = remaining.first { working = next; syncTimes(); playback.select(next) }
        else { playback.clearSelection() }
        removeID = nil
    }
    private var editorToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { editorTitle; Spacer(minLength: 8); editorActions }
            VStack(alignment: .leading, spacing: 12) { editorTitle; HStack { Spacer(); editorActions } }
        }.disabled(clips.isBusy)
    }
    private var editorTitle: some View {
        HStack(spacing: 14) {
            editorIcon("arrow.left", title: "返回最近项目", action: { if saveWorking() { onBack() } })
            TextField(L10n.text("项目名称"), text: Binding(get: { project.name }, set: { value in
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                clips.update(project.id) { $0.name = String(value.prefix(100)) }
            })).textFieldStyle(.plain).interfaceFont(size: 22, weight: .semibold).frame(minWidth: 140)
        }
    }
    private var editorActions: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                editorIcon("trash", title: "移出工作台", action: onRemove)
                editorIcon("square.and.arrow.down", title: "保存项目", action: { _ = saveWorking() })
            }
            HStack(spacing: 2) {
                DesignMenuField(title: model.sourceLanguage.name, height: 32) { ForEach(SubtitleLanguage.allCases) { lang in Button(lang.name) { model.setSourceLanguage(lang) } } }.frame(width: 112)
                Button(action: model.swapLanguages) { Image(systemName: "arrow.left.arrow.right").font(.system(size: 12)).frame(width: 26, height: 32) }.buttonStyle(.plain).help(L10n.text("交换语言"))
                DesignMenuField(title: model.targetLanguage.name, height: 32) { ForEach(SubtitleLanguage.allCases) { lang in Button(lang.name) { model.setTargetLanguage(lang) } } }.frame(width: 112)
            }
            Button { showingExport = true } label: { Label(L10n.text("导出片段"), systemImage: "square.and.arrow.up") }.buttonStyle(ThemeActionButtonStyle(prominent: true)).disabled(project.ranges.isEmpty)
        }
    }
    private var exportSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L10n.text("导出片段")).font(.headline); Spacer(); Button { showingExport = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(project.ranges) { range in
                        Toggle(isOn: Binding(get: { range.selected }, set: { checked in clips.update(project.id) { p in if let i = p.ranges.firstIndex(where: { $0.id == range.id }) { p.ranges[i].selected = checked } } })) {
                            HStack { Text(range.title); Spacer(); Text(ClipTime.label(range.start) + " – " + ClipTime.label(range.end)).font(.caption).monospacedDigit().foregroundStyle(ThemeColor.muted) }
                        }.toggleStyle(.checkbox).padding(12).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.frame(maxHeight: 280)
            HStack {
                Toggle(L10n.text("烧录字幕到 MP4"), isOn: $burn)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(L10n.text("选择文件夹")) { chooseExportFolder = true; showingExport = false }
                    .buttonStyle(ThemeActionButtonStyle(prominent: true))
                    .disabled(!project.ranges.contains(where: \.selected))
            }
        }.padding(24).frame(width: 510).background(ThemeColor.surface).appTheme()
    }
    private var exportIcon: some View {
        Image(systemName: "square.and.arrow.up").interfaceFont(size: 15, weight: .medium)
            .frame(width: 36, height: 36).foregroundStyle(ThemeColor.surface)
            .background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func editorIcon(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).interfaceFont(size: 14, weight: .medium).frame(width: 32, height: 32)
                .foregroundStyle(ThemeColor.primaryInk).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
    private func rangePanel(_ metrics: WorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                if project.ranges.count > 1 {
                    Menu {
                        Picker(L10n.text("选择选段"), selection: Binding(get: { working.id }, set: { id in
                            if let range = project.ranges.first(where: { $0.id == id }) { switchRange(range) }
                        })) {
                            ForEach(project.ranges) { range in Text(range.title).tag(range.id) }
                        }
                    } label: { Text(working.title).lineLimit(1) }
                    .menuStyle(.borderlessButton).frame(maxWidth: 130, alignment: .leading)
                    .help(L10n.text("选择选段")).accessibilityIdentifier("clips.selectRange")
                } else {
                    Text(L10n.text("时间轴")).interfaceFont(size: 15, weight: .semibold)
                }
                Button { showingTimes.toggle() } label: { Text(project.ranges.isEmpty ? "—" : ClipTime.label(working.start) + " – " + ClipTime.label(working.end)).font(.caption).monospacedDigit().foregroundStyle(ThemeColor.muted) }.buttonStyle(.plain)
                    .popover(isPresented: $showingTimes) { VStack { timeField("开始", text: $startText); timeField("结束", text: $endText); Button(L10n.text("完成")) { remember(); if saveWorking() { playback.select(working.start...working.end); showingTimes = false } } }.padding(20).frame(width: 300).appTheme() }
                Spacer()
                editorIcon("star", title: "高光候选", action: { if cues.isEmpty { recommend(3) } else { showingHighlights = true } })
                editorIcon("arrow.uturn.backward", title: "撤销上一步", action: undo).disabled(undoStack.isEmpty)
                editorIcon("plus", title: "添加选段", action: addRange)
                editorIcon("minus", title: "删除选段", action: { removeID = working.id }).disabled(project.ranges.isEmpty)
            }
            ClipTimeline150(ranges: project.ranges.map { $0.id == working.id ? active : $0 }, selected: working.id, duration: project.media.duration, time: playback.time,
                select: switchRange, change: { range, commit in
                    if gestureSnapshot == nil { gestureSnapshot = project }
                    working = range; syncTimes()
                    if commit { finishGesture(); _ = saveWorking(); playback.select(range.start...range.end) }
                }, seek: playback.seek, rename: { renameRange = $0 })
        }.designPanel(inset: metrics.cardInset).disabled(clips.isBusy).accessibilityIdentifier("clips.rangePanel")
    }
    private func remember() { undoStack.append(project); if undoStack.count > 40 { undoStack.removeFirst() }; textUndoCue = nil }
    private func finishGesture() { if let snapshot = gestureSnapshot { undoStack.append(snapshot); if undoStack.count > 40 { undoStack.removeFirst() } }; gestureSnapshot = nil; textUndoCue = nil }
    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        playback.player.pause()
        withAnimation(.easeInOut(duration: 0.18)) {
            clips.update(project.id) { p in p.ranges = previous.ranges; p.captions = previous.captions }
            if let next = previous.ranges.first(where: { $0.id == working.id }) ?? previous.ranges.first { working = next; syncTimes(); playback.select(next.start...next.end) } else { playback.clearSelection() }
        }
        textUndoCue = nil
    }
    private func timeField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            Text(L10n.text(title)).interfaceFont(size: 10).foregroundStyle(ThemeColor.muted)
            TextField("00:00:00.000", text: text).interfaceFont(size: 11, design: .monospaced).textFieldStyle(ClipFieldStyle()).onSubmit { _ = saveWorking() }
        }.disabled(clips.isBusy)
    }
    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cues) { cue in
                        insertCaptionButton(at: max(active.start, cue.start))
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button { remember(); editing = cue } label: { Text(ClipTime.label(cue.start) + " — " + ClipTime.label(cue.end)).interfaceFont(size: 10).monospacedDigit().foregroundStyle(ThemeColor.muted) }.buttonStyle(.plain)
                                Spacer()
                                
                                Button { remember(); withAnimation(.easeInOut(duration: 0.18)) { clips.deleteSegmentCaption(project.id, rangeID: active.id, cueID: cue.id) } } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .medium)).frame(width: 21, height: 21).overlay(Circle().stroke(ThemeColor.line, lineWidth: 1)) }.buttonStyle(.plain).help(L10n.text("删除字幕"))
                            }
                                TextField(L10n.text("原文"), text: cueText(cue, original: true), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("clips.original")
                                TextField(L10n.text("译文"), text: cueText(cue, original: false), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).interfaceFont(size: 13).accessibilityIdentifier("clips.translation")
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedCaption?.id == cue.id ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle()).onTapGesture { if selectedCaption?.id != cue.id { selectedCueID = cue.id; playback.seek(cue.start) } }
                            .accessibilityIdentifier("clips.cue." + cue.id.uuidString)
                    }
                    if cues.isEmpty {
                        Button { insertCaption(at: playback.time) } label: {
                            Label(L10n.text("添加字幕"), systemImage: "plus")
                        }.buttonStyle(ThemeActionButtonStyle()).padding(.vertical, 24)
                    }
                }
            }
            if !cues.isEmpty { insertCaptionButton(at: playback.time) }
        }.disabled(clips.isBusy || !hasRange)
    }
    private func insertCaptionButton(at time: Double) -> some View {
        Button { insertCaption(at: time) } label: {
            HStack(spacing: 8) { Rectangle().frame(height: 1); Image(systemName: "plus").font(.system(size: 9)); Rectangle().frame(height: 1) }.foregroundStyle(ThemeColor.line).frame(height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text("添加字幕")).accessibilityLabel(L10n.text("添加字幕"))
    }
    private func insertCaption(at requested: Double) {
        guard hasRange else { return }
        let time = max(active.start, min(requested, active.end - 0.2))
        let existing = cues.first { $0.start <= time && $0.end > time }
        var start = time
        var end = min(active.end, cues.first(where: { $0.start > time })?.start ?? active.end, time + 3)
        var trimmed: Caption?
        if var cue = existing {
            let a = max(active.start, cue.start), b = min(active.end, cue.end)
            guard b - a >= 0.4 else { return }
            start = max(a + 0.2, min(time, b - 0.2)); end = b
            cue.start = a; cue.end = start; trimmed = cue
        }
        guard end - start >= 0.19 else { return }
        let cue = Caption(start: start, end: end, original: "", translated: "")
        remember()
        clips.update(project.id) { p in
            guard let i = p.ranges.firstIndex(where: { $0.id == active.id }) else { return }
            var edits = p.ranges[i].captionEdits ?? []
            if let trimmed { edits.removeAll { $0.id == trimmed.id }; edits.append(trimmed) }
            edits.append(cue); p.ranges[i].captionEdits = edits
        }
        selectedCueID = cue.id; playback.seek(start)
    }
    private var selectedCaption: Caption? { cues.first { $0.id == selectedCueID } ?? cues.first }
    private func cueText(_ cue: Caption, original: Bool) -> Binding<String> {
        Binding(get: {
            let current = clips.selected?.captions(for: active).first { $0.id == cue.id } ?? cue
            return original ? current.original : current.translated
        }, set: { value in
            if textUndoCue != cue.id { remember(); textUndoCue = cue.id }
            var current = clips.selected?.captions(for: active).first { $0.id == cue.id } ?? cue
            if original { current.original = value } else { current.translated = value }
            current.start = max(active.start, current.start); current.end = min(active.end, current.end)
            _ = clips.saveSegmentCaption(project.id, rangeID: active.id, cue: current)
        })
    }
    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 6) {
                ForEach(ClipLanguageMode.allCases) { mode in
                    Button { var s = active.style; s.mode = mode; applyStyle(s) } label: { Text(L10n.text(mode.title)).frame(maxWidth: .infinity) }
                        .buttonStyle(ClipActionButtonStyle(accent: active.style.mode == mode ? ClipTheme.violet : nil, prominent: active.style.mode == mode))
                }
            }
            HStack(spacing: 12) { preset("白色", style: .classic); preset("浅粉", style: .pink); preset("浅金", style: .gold) }
        }.disabled(clips.isBusy)
    }
    private func importSubtitles() {
        guard saveWorking() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 5_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ClipError.message("请选择 5 MB 以内的 UTF-8 或 UTF-16 字幕文件。") }
            let captions = try ClipSubtitleImport.parse(text, extension: url.pathExtension, layout: .automatic, offset: 0, duration: project.media.duration)
            guard captions.contains(where: { $0.end > active.start && $0.start < active.end }) else { throw ClipError.message("字幕时间与当前选段没有交集。") }
            remember()
            clips.update(project.id) { p in if let i = p.ranges.firstIndex(where: { $0.id == working.id }) {
                p.ranges[i].importedCaptions = captions; p.ranges[i].captionEdits = nil; p.ranges[i].deletedCaptionIDs = nil; p.ranges[i].proofreadCandidates = nil
            } }
            selectedCueID = captions.first { $0.end > active.start && $0.start < active.end }?.id
        } catch { clips.notice = error.localizedDescription }
    }
    private func exportSubtitles(_ format: SubtitleExportFormat) {
        guard saveWorking() else { return }
        let content = format == .txt ? cues.map { active.style.lines($0).map(\.0).joined(separator: "\n") }.joined(separator: "\n\n") : ClipSubtitleImport.render(cues, format: format, style: active.style)
        guard !content.isEmpty else { return }
        SubtitleSavePanel.present(format: format, suggestedName: project.name, from: NSApp.mainWindow) { url in
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { clips.notice = error.localizedDescription }
        }
    }
    private func preset(_ name: String, style: ClipSubtitleStyle) -> some View {
        Button { var s = style; s.mode = active.style.mode; applyStyle(s) } label: {
            VStack(spacing: 5) { Text(L10n.text("中 / 日")).interfaceFont(size: 11, weight: .semibold).foregroundStyle(Color(nsColor: .clipHex(style.chinese.color))); Text(L10n.text(name)).interfaceFont(size: 9) }.frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active.style.chinese.color == style.chinese.color ? ClipTheme.violet : ThemeColor.ink.opacity(0.1)))
        }.buttonStyle(.plain)
    }
    private var proofreadSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("模型核对")).font(.title3.bold()); Spacer(); Button(L10n.text("完成")) { showingProofread = false } }
            Toggle(L10n.text("使用服务设置中选定的翻译模型"), isOn: $configured).disabled(clips.isBusy)
            Text(L10n.text(configured ? "云端核对将发送当前日语、前两句日中字幕、后一句日语和邻近上下文匹配的术语；不发送音视频。在模型与服务中选择翻译服务。" : "使用本机翻译模型，结合前后文和本地术语库，不上传字幕。")).font(.caption).foregroundStyle(ThemeColor.muted)
            Button(L10n.text("开始核对当前选段")) {
                if saveWorking() { if confirmCloudUse(translationOnly: true) { clips.start(ClipJob(projectID: project.id, kind: .proofread, range: active, configuredServices: configured), model: model) } }
            }.disabled(clips.isBusy || cues.allSatisfy { $0.original.isEmpty })
            ScrollView {
                ForEach(active.proofreadCandidates ?? []) { cue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cue.original)
                        Text(L10n.text("现有：") + (cues.first { $0.id == cue.id }?.translated ?? "")).foregroundStyle(ThemeColor.muted)
                        Text(L10n.text("建议：") + cue.translated).foregroundStyle(ClipTheme.cyan)
                        Button(L10n.text("应用这条建议")) { remember(); _ = clips.applyProofread(project.id, rangeID: working.id, cue: cue) }.disabled(clips.isBusy)
                    }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if clips.isBusy { ProgressView(); Text(L10n.text(clips.currentJob?.message ?? "处理中…")).font(.caption) }
            else if active.proofreadCandidates?.isEmpty == true { Text(L10n.text("核对完成，没有不同的译文建议。")).font(.caption).foregroundStyle(ThemeColor.muted) }
        }.padding(24).frame(width: 650, height: 540).background(ThemeColor.background)
    }
    private func syncTimes() { startText = ClipTime.label(working.start); endText = ClipTime.label(working.end) }
    @discardableResult private func saveWorking() -> Bool {
        guard project.ranges.contains(where: { $0.id == working.id }) else { return true }
        guard let start = ClipTime.parse(startText), let end = ClipTime.parse(endText) else { clips.notice = "请输入有效的时:分:秒.毫秒。"; return false }
        working.start = start; working.end = end
        do { try working.validate(duration: project.media.duration); clips.saveRange(project.id, range: working); syncTimes(); return true } catch { clips.notice = error.localizedDescription; return false }
    }
    private func switchRange(_ range: ClipRange) { guard saveWorking() else { return }; draggedStyle = nil; movingSubtitles = false; working = range; syncTimes(); playback.select(range.start...range.end) }
    private func addRange() { guard saveWorking() else { return }; duplicate(hasRange ? active : ClipRange(title: "", start: 0, end: min(4, project.media.duration))) }
    private func duplicate(_ range: ClipRange) {
        remember()
        var next = range; next.id = UUID(); next.title = "选段 \((project.ranges.compactMap { Int($0.title.split(separator: " ").last ?? "") }.max() ?? project.ranges.count) + 1)"; next.proofreadCandidates = nil
        clips.saveRange(project.id, range: next); working = next; syncTimes(); playback.select(next.start...next.end)
    }
    private func applyStyle(_ style: ClipSubtitleStyle) { guard saveWorking() else { return }; clips.setStyle(project.id, rangeID: working.id, style: style) }
    private func recommend(_ maximum: Int) {
        guard saveWorking() else { return }
        if project.captions.isEmpty {
            guard project.media.hasAudio else { clips.notice = "请先导入字幕，再推荐高光。"; return }
            guard confirmCloudUse(translationOnly: false) else { return }
            pendingRecommendation = maximum
            remember()
            clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: active, configuredServices: configured, sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage), model: model)
        } else { clips.start(ClipJob(projectID: project.id, kind: .recommend, recommendationCount: maximum), model: nil) }
    }
    private func transcribe() { guard saveWorking(), confirmCloudUse(translationOnly: false) else { return }; remember(); clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: active, configuredServices: configured, sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage), model: model) }
    private func confirmCloudUse(translationOnly: Bool) -> Bool {
        guard configured else { return true }
        let ids = translationOnly ? [model.selectedTranslationProfileID] : [model.selectedASRProfileID, model.selectedTranslationProfileID]
        let services = model.profiles.filter { ids.contains($0.id) && $0.kind != .local }
        guard !services.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "调用云端服务？"
        alert.informativeText = services.map(\.name).joined(separator: "、") + "将处理当前选段，可能消耗账户额度并产生费用。" + (services.contains { $0.purpose == .speechRecognition } ? "识别服务会收到音频；翻译服务会收到字幕文本。" : "仅发送字幕文字，不上传音视频。") + "具体费用以服务商计费为准。"
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func generatePreview() { guard saveWorking() else { return }; playback.player.pause(); clips.start(ClipJob(projectID: project.id, kind: .preview, range: active, burnSubtitles: burn), model: nil) }
    private func export(_ kind: ClipExportKind, subtitles: Bool) {
        guard saveWorking() else { return }
        let selected = clips.projects.first { $0.id == project.id }?.ranges ?? []
        let ranges = selected.filter(\.selected)
        guard !ranges.isEmpty else { clips.notice = "请勾选至少一个要导出的选段。"; return }
        let panel = NSOpenPanel(); panel.title = "选择 \(kind.rawValue.uppercased()) 导出文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if let path = UserDefaults.standard.string(forKey: "clips.exportFolder.v150"), !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        playback.player.pause()
        clips.start(ClipJob(projectID: project.id, kind: .export, ranges: ranges, burnSubtitles: subtitles, exportKind: kind, outputFolder: folder.path), model: nil)
    }
}

private struct ClipCaptionEditor: View {
    var projectID: UUID
    var range: ClipRange
    @State var cue: Caption
    @EnvironmentObject private var clips: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("字幕时间")).font(.title3.bold())
            HStack { TextField(L10n.text("起点"), text: $start); Text("→"); TextField(L10n.text("终点"), text: $end) }.textFieldStyle(ClipFieldStyle())
            HStack {
                Button(L10n.text("删除这条字幕"), role: .destructive) { clips.deleteSegmentCaption(projectID, rangeID: range.id, cueID: cue.id); dismiss() }
                Spacer(); Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("保存")) {
                    guard let a = ClipTime.parse(start), let b = ClipTime.parse(end) else { clips.notice = "字幕时间格式无效。"; return }
                    cue.start = a; cue.end = b
                    if clips.saveSegmentCaption(projectID, rangeID: range.id, cue: cue) { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).onAppear { start = ClipTime.label(cue.start); end = ClipTime.label(cue.end) }
    }
}
struct ClipVideoPreview: View {
    let url: URL
    var offset: Double
    var hasSubtitles: Bool
    var onSetStart: (Double) -> Void
    var onSetEnd: (Double) -> Void
    var onClose: () -> Void
    @State private var player: AVPlayer?
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            HStack { Text(L10n.text(hasSubtitles ? "内嵌字幕成片预览" : "原画面选段预览")).interfaceFont(size: 14, weight: .semibold); Spacer(); Button(L10n.text("完成"), action: onClose) }.padding(16)
            ClipNativePlayer(player: player).frame(minWidth: 640, minHeight: 360)
            HStack { Text(L10n.text("拖动进度条检查画面")).font(.caption).foregroundStyle(ThemeColor.muted); Spacer(); Button(L10n.text("设为起点")) { onSetStart(position) }; Button(L10n.text("设为终点")) { onSetEnd(position) } }.padding(16)
        }.onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
    }
    private var position: Double { let t = player?.currentTime().seconds ?? 0; return offset + (t.isFinite ? max(0, t) : 0) }
}
struct ClipNativePlayer: NSViewRepresentable {
    var player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.controlsStyle = .inline; v.showsFullScreenToggleButton = true; v.player = player; return v }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player?.pause(); view.player = nil }
}

enum ClipTheme {
    static var violet: Color { ThemeColor.primary }
    static var cyan: Color { ThemeColor.primary }
    static var background: some View { ClipBackground() }
    static var panel: Color { ThemeColor.surface }
}
struct ClipBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ThemeColor.background
    }
}
struct ClipActionButtonStyle: ButtonStyle {
    @Environment(\.appThemeID) private var appThemeID
    var accent: Color? = nil
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let _ = appThemeID
        return configuration.label.interfaceFont(size: 12, weight: .medium)
            .foregroundStyle(prominent ? ThemeColor.surface : ThemeColor.primaryInk)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(prominent ? ThemeColor.primary : configuration.isPressed ? ThemeColor.selection : ThemeColor.soft, in: RoundedRectangle(cornerRadius: 11))
            .opacity(enabled ? 1 : 0.4)

    }
}
struct ClipFieldStyle: TextFieldStyle {
    @Environment(\.appThemeID) private var appThemeID
    func _body(configuration: TextField<Self._Label>) -> some View {
        let _ = appThemeID
        return configuration.textFieldStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
            .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ThemeColor.line))
    }
}

private struct ClipHighlightsPanel: View {
    var project: ClipProject
    var onRecommend: (Int) -> Void
    var onEdit: (ClipRange) -> Void
    var onPreview: (ClipRange) -> Void
    @EnvironmentObject private var clips: ClipStore
    @State private var maximum = 5
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("高光候选"), systemImage: "sparkles").interfaceFont(size: 14, weight: .semibold).foregroundStyle(.orange)
                Spacer()
                Picker(L10n.text("数量"), selection: $maximum) { Text(L10n.text("最多 3 段")).tag(3); Text(L10n.text("最多 5 段")).tag(5); Text(L10n.text("最多 8 段")).tag(8) }.labelsHidden().frame(width: 110)
                Button(L10n.text(project.captions.isEmpty ? "分析并推荐" : "推荐高光")) { onRecommend(maximum) }
                    .disabled(clips.isBusy || (project.captions.isEmpty && !project.media.hasAudio)).accessibilityIdentifier("clips.recommend")
            }
            ForEach(project.candidates ?? []) { range in
                HStack(alignment: .top, spacing: 10) {
                    Toggle(L10n.text("选择高光"), isOn: Binding(get: { range.selected }, set: { selected in
                        clips.update(project.id) { p in if let i = p.candidates?.firstIndex(where: { $0.id == range.id }) { p.candidates?[i].selected = selected } }
                    })).labelsHidden()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(range.title).interfaceFont(size: 12, weight: .medium).lineLimit(2)
                        Text(ClipTime.label(range.start) + " – " + ClipTime.label(range.end)).interfaceFont(size: 10).monospacedDigit().foregroundStyle(ThemeColor.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L10n.text("预览")) { onPreview(range) }
                    Button(L10n.text("调整")) { onEdit(range) }
                }.padding(10).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 9)).disabled(clips.isBusy)
            }
            if !(project.candidates ?? []).isEmpty {
                HStack {
                    Spacer()
                    Button(L10n.text("添加选中片段")) { clips.addCandidates(project.id) }
                        .disabled(clips.isBusy || !(project.candidates ?? []).contains(where: \.selected))
                }
            }
        }.padding(14).background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ThemeColor.line))
    }
}


extension View {
    func clipPanelCard() -> some View {
        self.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ClipTheme.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ThemeColor.ink.opacity(0.12)))
    }
}
