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
            if let job = clips.bannerJob {
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
                Button(L10n.text("移出工作台"), role: .destructive) { if let id = pendingProjectRemoval { withAnimation(.easeInOut(duration: 0.2)) { clips.removeProject(id) } }; pendingProjectRemoval = nil }
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
            } else if [.failed, .interrupted, .paused].contains(job.state) {
                Button(L10n.text("按已保存设置重试")) { clips.start(job, model: model) }
            }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(ThemeColor.soft)
            .accessibilityIdentifier("clips.jobBanner")
    }
    private var library: some View {
        ClipLibrarySheet(onProject: { clips.selectedID = $0; showingLibrary = false },
            onRecording: { recording, url in load(url, creator: recording.creatorID, name: recording.creatorName); showingLibrary = false },
            onImport: { showingLibrary = false; DispatchQueue.main.async { importVideo() } },
            onClose: { showingLibrary = false }).appTheme()
    }
    private func importVideo() {
        guard !importing, !clips.isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("打开视频")
        panel.prompt = L10n.text("打开视频")
        let folder = URL(fileURLWithPath: (monitor.settings.outputFolder as NSString).expandingTildeInPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path), folder.path == LiveMonitorSettings().outputFolder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        panel.directoryURL = folder
        panel.allowsMultipleSelection = false
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

struct CaptionInspectorIcon: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 16, weight: .medium))
            .frame(width: 20, height: 20)
    }
}

private struct CaptionBulb: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 7.5, y: 14.5))
        path.addCurve(to: CGPoint(x: 12, y: 3), control1: CGPoint(x: 3, y: 9.8), control2: CGPoint(x: 6, y: 3))
        path.addCurve(to: CGPoint(x: 16.5, y: 14.5), control1: CGPoint(x: 18, y: 3), control2: CGPoint(x: 21, y: 9.8))
        path.addQuadCurve(to: CGPoint(x: 15, y: 17), control: CGPoint(x: 15, y: 16))
        path.addLine(to: CGPoint(x: 9, y: 17))
        path.addQuadCurve(to: CGPoint(x: 7.5, y: 14.5), control: CGPoint(x: 9, y: 16))
        path.closeSubpath()
        path.move(to: CGPoint(x: 10, y: 20))
        path.addLine(to: CGPoint(x: 14, y: 20))
        path.move(to: CGPoint(x: 11.2, y: 22))
        path.addLine(to: CGPoint(x: 12.8, y: 22))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct CaptionToolButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var expanded = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(label: configuration.label, pressed: configuration.isPressed, size: size, expanded: expanded)
    }

    private struct Surface: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let size: CGFloat
        let expanded: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size > 26 ? 8 : 6, style: .continuous)
            let active = enabled && (hovered || expanded)
            let idleFill: Color = size < 30 ? ThemeColor.control : .clear
            let idleStroke: Color = size < 30 ? ThemeColor.line.opacity(0.8) : .clear
            label.frame(width: size, height: size)
                .foregroundStyle(enabled ? ThemeColor.primaryInk : ThemeColor.muted)
                .background(pressed ? ThemeColor.selection : (active ? ThemeColor.soft : idleFill), in: shape)
                .overlay { shape.strokeBorder(active && size < 30 ? ThemeColor.primary.opacity(0.65) : idleStroke) }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.46)
                .onHover { hovered = $0 }
        }
    }
}

/// Keeps each toolbar group intact when the project title or interface language changes.
private struct ClipToolbarLayout: Layout {
    let gap: CGFloat = 14

    private func frames(_ proposal: ProposedViewSize, _ views: Subviews) -> (width: CGFloat, items: [CGRect]) {
        let ideal = views.map { $0.sizeThatFits(.unspecified) }
        let idealWidth = ideal.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, views.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth
        var rows: [[CGRect]] = [[]]
        var x: CGFloat = 0
        for (index, size) in ideal.enumerated() {
            let w = min(width, size.width)
            if x > 0 && x + w > width {
                rows.append([])
                x = 0
            }
            let h = views[index].sizeThatFits(ProposedViewSize(width: w, height: nil)).height
            rows[rows.count - 1].append(CGRect(x: x, y: 0, width: w, height: h))
            x += w + gap
        }

        var y: CGFloat = 0
        var items: [CGRect] = []
        for (rowIndex, row) in rows.enumerated() {
            let height = row.map(\.height).max() ?? 0
            let slack = max(0, width - (row.last?.maxX ?? 0))
            for (index, item) in row.enumerated() {
                var rect = item.offsetBy(dx: slack, dy: y + (height - item.height) / 2)
                if rowIndex == 0 && index == 0 {
                    rect.origin.x = 0
                    rect.size.width += slack
                }
                items.append(rect)
            }
            y += height + 10
        }
        return (width, items)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = frames(proposal, subviews)
        return CGSize(width: result.width, height: result.items.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = frames(ProposedViewSize(width: bounds.width, height: nil), subviews)
        for (item, frame) in zip(subviews, result.items) {
            item.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

struct ClipEditor: View {
    var project: ClipProject
    var onImport: () -> Void = {}
    var onBack: () -> Void = {}
    var onLibrary: () -> Void = {}
    var onRemove: () -> Void = {}
    @FocusState private var projectNameFocused: Bool
    @State private var rightTab = 0
    @State private var selectedCueID: UUID?
    @State private var newCueID: UUID?
    @FocusState private var focusedOriginalID: UUID?
    @EnvironmentObject private var clips: ClipStore
    @EnvironmentObject private var model: AppModel
    @State private var working: ClipRange
    @State private var startText = ""
    @State private var endText = ""
    @State private var configuredProofreading = true
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
    @State private var removeID: UUID?
    @State private var undoStack: [ClipProject] = []
    @State private var gestureSnapshot: ClipProject?
    @State private var renameRange: ClipRange?
    @State private var chooseExportFolder = false
    @State private var subtitleExportFormat: SubtitleExportFormat?
    @State private var showingExport = false
    @State private var showingTimes = false
    @State private var textUndoCue: UUID?
    @State private var playbackAttempt = 0
    @State private var initializedSelection = false
    @StateObject private var playback: ClipPlayback
    init(project: ClipProject, onImport: @escaping () -> Void = {}, onBack: @escaping () -> Void = {}, onLibrary: @escaping () -> Void = {}, onRemove: @escaping () -> Void = {}) {
        self.project = project; self.onImport = onImport; self.onBack = onBack; self.onLibrary = onLibrary; self.onRemove = onRemove
        // Playback ticks update this view frequently. Resolve the source track
        // once for each project snapshot, not once per tick or inspector row.
        let range = project.subtitleRange
        let raw = project.captions(for: range)
        let styled = (project.captionRoles ?? []).isEmpty ? raw : project.styledCaptions(for: range)
        cues = raw
        styledCues = styled
        captionStyle = project.subtitleStyle(for: range, displaying: raw)
        effectiveRoles = Dictionary(styled.compactMap { cue in cue.clipRoleID.map { (cue.id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        _working = State(initialValue: project.ranges.first ?? project.wholeRange)
        _playback = StateObject(wrappedValue: ClipPlayback())
    }
    private var active: ClipRange {
        var value = project.ranges.first(where: { $0.id == working.id }) ?? working
        value.start = working.start; value.end = working.end; value.title = working.title
        return value
    }
    private var subtitleRange: ClipRange { project.subtitleRange }
    private var hasRange: Bool { project.ranges.contains { $0.id == working.id } }
    private let cues: [Caption]
    private let styledCues: [Caption]
    private let captionStyle: ClipSubtitleStyle
    private let effectiveRoles: [UUID: UUID]
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
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    editorToolbar
                    metrics.columns {
                        VStack(alignment: .leading, spacing: 12) {
                            let playbackCues = styledCues
                            ClipStyledPlayer(player: playback.player, captions: playbackCues, style: showingStyle ? draftStyle : (draggedStyle ?? captionStyle), roles: project.captionRoles ?? [],
                                mediaSize: CGSize(width: project.media.width, height: project.media.height),
                                onStyle: { style, commit in
                                    if gestureSnapshot == nil { gestureSnapshot = project }
                                    draggedStyle = style
                                    if commit { finishGesture(); applyStyle(style); draggedStyle = nil }
                                }, onRoleResize: resizeRole)
                                .overlay {
                                    if let failure = playback.failure {
                                        VStack {
                                            Text(L10n.text(failure)).font(.callout)
                                            Button(L10n.text("重试")) { playbackAttempt += 1 }
                                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    } else if !playback.ready {
                                        ProgressView(L10n.text("正在准备视频播放…"))
                                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                }
                                .frame(height: videoHeight).clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Text(ClipTime.label(playback.time) + " / " + ClipTime.label(project.media.duration)).font(.caption).monospacedDigit().foregroundStyle(ThemeColor.muted)
                                Spacer()
                                DesignMenuField(title: String(format: "%g×", playback.speed), height: 30) {
                                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in Button(String(format: "%g×", rate)) { playback.speed = rate } }
                                }.frame(width: 62)
                                editorIcon(playback.player.rate == 0 ? "play" : "pause", title: "播放 / 暂停", action: playback.toggle).disabled(!playback.ready)
                            }
                        }.frame(maxWidth: .infinity).accessibilityIdentifier("clips.videoPanel")
                        VStack(alignment: .leading, spacing: 20) {
                            subtitleInspectorHeader
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
            .onAppear {
                guard !initializedSelection else { return }
                initializedSelection = true
                syncTimes()
                if !project.ranges.isEmpty { playback.select(working.start...working.end) }
            }
            .task(id: playbackAttempt) { await playback.prepare(project.media, rebuild: playbackAttempt > 0) }
            .onDisappear { playback.player.pause() }
            .onChange(of: project.ranges.map(\.id)) { ids in
                if !ids.contains(working.id) { if let next = project.ranges.first { working = next; syncTimes(); playback.select(next.start...next.end) } else { playback.clearSelection() } }
            }
            .sheet(item: $editing) { cue in ClipCaptionEditor(projectID: project.id, range: subtitleRange, cue: cue, inheritedRoleID: project.styledCaptions(for: subtitleRange, inheritingAt: cue.id).first { $0.id == cue.id }?.clipRoleID).appTheme() }
            .sheet(isPresented: $showingStyle, onDismiss: { applyStyle(draftStyle, recordingUndo: true) }) {
                ClipStyleEditor150(player: playback.player,
                                   current: styledCues.first { $0.start <= playback.time && playback.time < $0.end },
                                   sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage,
                                   roles: project.captionRoles ?? [], mediaSize: CGSize(width: project.media.width, height: project.media.height),
                                   style: $draftStyle, onClose: { showingStyle = false }).appTheme()
            }
            .sheet(item: $renameRange) { range in
                VStack(spacing: 18) {
                    Text(L10n.text("片段名称")).font(.headline)
                    TextField("", text: Binding(get: { renameRange?.title ?? range.title }, set: { renameRange?.title = $0 })).textFieldStyle(ClipFieldStyle())
                    Button(L10n.text("完成")) { if let next = renameRange, !next.title.trimmingCharacters(in: .whitespaces).isEmpty { remember(); clips.saveRange(project.id, range: next); if working.id == next.id { working.title = next.title } }; renameRange = nil }
                }.padding(24).frame(width: 340).background(ThemeColor.surface).appTheme()
            }
            .sheet(isPresented: $showingExport, onDismiss: {
                if let format = subtitleExportFormat {
                    subtitleExportFormat = nil
                    exportSubtitles(format)
                }
                if chooseExportFolder { chooseExportFolder = false; export(.mp4, subtitles: burn) }
            }) { exportSelection }
            .sheet(isPresented: $showingProofread) { proofreadSheet }
            .sheet(isPresented: $showingHighlights) {
                ClipHighlightsPanel(projectID: project.id, rangeID: hasRange ? working.id : nil, onRecommend: recommend, onEdit: { range in
                    remember()
                    if clips.saveRange(project.id, range: range) {
                        working = range; syncTimes(); showingHighlights = false
                    }
                }, onPreview: { range in
                    showingHighlights = false
                    playback.select(range)
                    playback.toggle()
                }, onClose: { showingHighlights = false }).appTheme()
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
        ClipToolbarLayout {
            editorTitle
            HStack(spacing: 8) {
                editorIcon("trash", title: "移出工作台", subdued: true, action: onRemove)
                    .accessibilityIdentifier("clips.removeProject")
                Button { _ = saveWorking() } label: {
                    ClipSaveGlyph().stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
                        .frame(width: 17, height: 17).frame(width: 32, height: 32)
                        .foregroundStyle(ThemeColor.primaryInk).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help(L10n.text("保存项目")).accessibilityLabel(L10n.text("保存项目"))
                    .accessibilityIdentifier("clips.saveProject")
            }
            HStack(spacing: 4) {
                toolbarLanguage(model.sourceLanguage, set: model.setSourceLanguage)
                Button(action: model.swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12)).frame(width: 26, height: 32)
                }.buttonStyle(.plain).help(L10n.text("交换语言")).accessibilityLabel(L10n.text("交换语言"))
                toolbarLanguage(model.targetLanguage, set: model.setTargetLanguage)
            }
            Button { if saveWorking() { showingExport = true } } label: {
                Label(L10n.text("导出片段"), systemImage: "square.and.arrow.up")
                    .lineLimit(1).fixedSize()
            }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                .fixedSize().disabled(project.ranges.isEmpty && cues.isEmpty)
                .accessibilityIdentifier("clips.exportRanges")
        }.disabled(clips.isBusy)
    }

    private func toolbarLanguage(_ language: SubtitleLanguage, set: @escaping (SubtitleLanguage) -> Void) -> some View {
        // Reserve the ideal localized label width including the menu chevron and insets.
        Text(L10n.text(language.name)).interfaceFont(size: 13)
            .lineLimit(1).padding(.horizontal, 22)
            .frame(minWidth: 78).frame(height: 32)
            .hidden().accessibilityHidden(true)
            .overlay {
                DesignMenuField(title: language.name, height: 32) {
                    ForEach(SubtitleLanguage.allCases) { option in
                        Button(L10n.text(option.name)) { set(option) }
                    }
                }
            }
    }

    private var editorTitle: some View {
        HStack(spacing: 12) {
            editorIcon("arrow.left", title: "返回最近项目", action: { if saveWorking() { onBack() } })
            Text(verbatim: project.name).interfaceFont(size: 22, weight: .semibold)
                .lineLimit(1).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                .hidden().accessibilityHidden(true)
                .overlay(alignment: .leading) {
                    TextField(L10n.text("项目名称"), text: Binding(get: { project.name }, set: { value in
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        clips.update(project.id) { $0.name = String(value.prefix(100)) }
                    }))
                    .textFieldStyle(.plain).interfaceFont(size: 22, weight: .semibold)
                    .focused($projectNameFocused)
                    .overlay(alignment: .leading) {
                        if !projectNameFocused {
                            Text(verbatim: project.name).interfaceFont(size: 22, weight: .semibold)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                .background(ThemeColor.background)
                                .accessibilityHidden(true).allowsHitTesting(false)
                        }
                    }
                    .accessibilityIdentifier("clips.projectName")
                    .help(project.name)
                }
        }
    }
    private var exportSelection: some View {
        let incomplete = burn ? project.ranges.first { $0.selected && !project.hasBurnableCaptions(for: $0) } : nil
        return VStack(alignment: .leading, spacing: 18) {
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
            if let incomplete {
                Text(incomplete.title + " · " + L10n.text("字幕未补齐。请补齐字幕，或关闭烧录。"))
                    .font(.callout).foregroundStyle(ThemeColor.primaryInk)
                    .accessibilityIdentifier("clips.export.incomplete")
            }
            HStack {
                Toggle(L10n.text("烧录字幕到 MP4"), isOn: $burn)
                    .toggleStyle(.checkbox)
                Spacer()
                Menu(L10n.text("导出字幕")) {
                    ForEach(SubtitleExportFormat.allCases) { format in
                        Button(format.title) { subtitleExportFormat = format; showingExport = false }
                    }
                }
                .fixedSize().disabled(cues.isEmpty)
                .accessibilityIdentifier("clips.exportSubtitles")
                Button(L10n.text("选择文件夹")) { chooseExportFolder = true; showingExport = false }
                    .buttonStyle(ThemeActionButtonStyle(prominent: true))
                    .disabled(incomplete != nil || !project.ranges.contains(where: \.selected))
            }
        }.padding(24).frame(width: 510).background(ThemeColor.surface).appTheme()
    }
    private var exportIcon: some View {
        Image(systemName: "square.and.arrow.up").interfaceFont(size: 15, weight: .medium)
            .frame(width: 36, height: 36).foregroundStyle(ThemeColor.surface)
            .background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func editorIcon(_ symbol: String, title: String, subdued: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).interfaceFont(size: 14, weight: .medium).frame(width: 32, height: 32)
                .foregroundStyle(subdued ? ThemeColor.muted : ThemeColor.primaryInk)
                .background(subdued ? .clear : ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
                .overlay { if subdued { RoundedRectangle(cornerRadius: 10).strokeBorder(ThemeColor.line) } }
        }.buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
    private func rangePanel(_ metrics: WorkspaceMetrics) -> some View {
        let laneWidth = max(1, metrics.width - 2 * (metrics.gutter + metrics.cardInset))
        let displayedRanges = project.ranges.map { $0.id == working.id ? active : $0 }
        let total = max(0.2, project.media.duration)
        let shortRanges = displayedRanges.filter { laneWidth * $0.duration / total < 24 }
        let header = metrics.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                                    : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 14) {
            header {
                HStack(spacing: 12) {
                    Text(hasRange ? working.title : L10n.text("时间轴"))
                        .interfaceFont(size: 15, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("clips.rangeTitle")
                    Button { showingTimes.toggle() } label: {
                        Text(hasRange ? ClipTime.label(working.start) + " – " + ClipTime.label(working.end) : "—")
                            .font(.caption).monospacedDigit().foregroundStyle(ThemeColor.muted)
                    }
                    .buttonStyle(.plain).disabled(!hasRange)
                    .popover(isPresented: $showingTimes) {
                        VStack {
                            timeField("开始", text: $startText)
                            timeField("结束", text: $endText)
                            Button(L10n.text("完成")) {
                                remember()
                                if saveWorking() {
                                    playback.select(working.start...working.end)
                                    showingTimes = false
                                }
                            }
                        }.padding(20).frame(width: 300).appTheme()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    editorIcon("star", title: "高光候选", action: { showingHighlights = true })
                    editorIcon("arrow.uturn.backward", title: "撤销上一步", action: undo).disabled(undoStack.isEmpty)
                    editorIcon("plus", title: "添加选段", action: addRange)
                    editorIcon("minus", title: "删除选段", action: { removeID = working.id }).disabled(project.ranges.isEmpty)
                }
            }
            ClipTimeline150(ranges: displayedRanges, selected: working.id, duration: project.media.duration, time: playback.time,
                select: switchRange, change: { range, commit in
                    if gestureSnapshot == nil { gestureSnapshot = project }
                    working = range; syncTimes()
                    if commit { finishGesture(); _ = saveWorking(); playback.select(range.start...range.end) }
                }, seek: playback.seek, rename: { renameRange = $0 })
            if !shortRanges.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(shortRanges) { range in
                            Button { switchRange(range) } label: {
                                Text(range.title)
                                    .interfaceFont(size: 12, weight: range.id == working.id ? .semibold : .regular)
                                    .padding(.horizontal, 9).frame(minWidth: 30, minHeight: 28)
                                    .background(range.id == working.id ? ThemeColor.selection : ThemeColor.soft,
                                                in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(range.id == working.id ? .isSelected : [])
                            .accessibilityValue(ClipTime.label(range.start) + " – " + ClipTime.label(range.end))
                            .accessibilityIdentifier("clips.shortRange." + range.id.uuidString)
                        }
                    }
                }
            }
        }.designPanel(inset: metrics.cardInset).disabled(clips.isBusy).accessibilityIdentifier("clips.rangePanel")
    }
    private func remember() { undoStack.append(project); if undoStack.count > 40 { undoStack.removeFirst() }; textUndoCue = nil }
    private func finishGesture() { if let snapshot = gestureSnapshot { undoStack.append(snapshot); if undoStack.count > 40 { undoStack.removeFirst() } }; gestureSnapshot = nil; textUndoCue = nil }
    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        playback.player.pause()
        withAnimation(.easeInOut(duration: 0.18)) {
            clips.update(project.id) { p in p.ranges = previous.ranges; p.captions = previous.captions; p.subtitleTrack = previous.subtitleTrack; p.analysisCoverage = previous.analysisCoverage; p.captionRoles = previous.captionRoles }
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
    private var subtitleInspectorHeader: some View {
        HStack(spacing: 5) {
            Text(L10n.text("全片字幕")).interfaceFont(size: 16, weight: .semibold)
            Spacer(minLength: 8)
            Button(action: importSubtitles) { CaptionInspectorIcon("doc.badge.plus") }
                .help(L10n.text("导入字幕")).accessibilityLabel(L10n.text("导入字幕"))
                .accessibilityIdentifier("clips.importSubtitles")
            Button(action: openSubtitleStyle) { CaptionInspectorIcon("paintbrush") }
                .help(L10n.text("字幕样式")).accessibilityLabel(L10n.text("字幕样式"))
                .accessibilityIdentifier("clips.customStyle")
            Button(action: transcribe) {
                CaptionBulb().stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
            }
                .help(L10n.text("识别并翻译全片")).accessibilityLabel(L10n.text("生成字幕"))
                .accessibilityIdentifier("clips.transcribe").disabled(!project.media.hasAudio)
            ClipCaptionRoleMenu(projectID: project.id, baseStyle: captionStyle, sample: cues.first)
        }.buttonStyle(CaptionToolButtonStyle()).disabled(clips.isBusy)
    }

    private func openSubtitleStyle() {
        draftStyle = captionStyle
        playback.player.pause()
        showingStyle = true
    }

    private var subtitleResult: ClipJob? {
        guard let job = clips.jobs.first(where: {
            $0.projectID == project.id && $0.kind == .transcribe && $0.recommendationCount == nil && $0.range?.id == project.id
        }), job.showsSubtitleResultInInspector else { return nil }
        return job
    }

    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = subtitleResult {
                let empty = job.noSpeechDetected == true || (job.generationServiceKey == nil && cues.isEmpty)
                if empty {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.slash").accessibilityHidden(true)
                        Text(L10n.text("未检测到语音"))
                        Button(L10n.text("重试"), action: transcribe)
                            .buttonStyle(.link)
                            .accessibilityIdentifier("clips.retrySubtitleGeneration")
                    }.interfaceFont(size: 12).foregroundStyle(ThemeColor.primaryInk)
                        .accessibilityIdentifier("clips.subtitleResult")
                } else if let completion = clips.subtitleCompletion, completion.jobID == job.id {
                    ClipFinishedNotice(started: completion.date)
                }
            }
            if cues.isEmpty {
                Button { insertCaption() } label: {
                    Label(L10n.text("添加字幕"), systemImage: "plus")
                }
                .buttonStyle(ThemeActionButtonStyle())
                .accessibilityIdentifier("clips.addFirstSubtitle")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                populatedSubtitleColumn
            }
        }.disabled(clips.isBusy)
    }

    private var populatedSubtitleColumn: some View {
        let track = cues
        let highlightedID = selectedCueID ?? track.first?.id
        let rowStyle = captionStyle
        return VStack(alignment: .leading, spacing: 14) {
            ScrollViewReader { scroll in
                ScrollView {
                  LazyVStack(spacing: 10) {
                    ForEach(track) { cue in
                        insertCaptionButton(before: cue.id)
                        HStack(alignment: .top, spacing: 6) {
                            if project.showsRoleBadges != false {
                                ClipCaptionRoleMenu(projectID: project.id, baseStyle: rowStyle, sample: cue,
                                                    cue: Binding(get: { cue }, set: { changed in
                                                        remember()
                                                        clips.update(project.id) {
                                                            $0.setRoleMarker(from: changed, in: project.id)
                                                        }
                                                    }), inheritedRoleID: effectiveRoles[cue.id], badgeOnly: true)
                                    .padding(.top, 8)
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Button { remember(); focusCaption(cue); editing = cue } label: { Text(ClipTime.label(cue.start) + " — " + ClipTime.label(cue.end)).interfaceFont(size: 10).monospacedDigit().foregroundStyle(ThemeColor.muted) }.buttonStyle(.plain)
                                        .help(L10n.text("编辑字幕")).accessibilityIdentifier("clips.editCaption." + cue.id.uuidString)
                                    Spacer()

                                    Button { remember(); withAnimation(.easeInOut(duration: 0.18)) { clips.deleteSegmentCaption(project.id, rangeID: project.id, cueID: cue.id) } } label: { Image(systemName: "xmark").font(.system(size: 7, weight: .medium)).frame(width: 21, height: 21).overlay(Circle().stroke(ThemeColor.line, lineWidth: 1)) }.buttonStyle(.plain).help(L10n.text("删除字幕"))
                                }
                                TextField(L10n.text("原文"), text: cueText(cue, original: true), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("clips.original")
                                    .focused($focusedOriginalID, equals: cue.id)
                                    .onAppear { if newCueID == cue.id { focusedOriginalID = cue.id; newCueID = nil } }
                                TextField(L10n.text("译文"), text: cueText(cue, original: false), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).interfaceFont(size: 13).accessibilityIdentifier("clips.translation")
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(highlightedID == cue.id ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle()).onTapGesture { focusCaption(cue) }
                            .accessibilityIdentifier("clips.cue." + cue.id.uuidString)
                        }.id(cue.id).contextMenu {
                            Button(L10n.text("核对译文")) { showingProofread = true }
                                .accessibilityIdentifier("clips.proofread")
                        }
                    }
                  }
                }.onChange(of: selectedCueID) { id in
                    if let id { scroll.scrollTo(id) }
                }
            }
            insertCaptionButton()
        }
    }

    private func focusCaption(_ cue: Caption) {
        selectedCueID = cue.id
        playback.clearSelection(seekingTo: cue.start)
    }

    private func insertCaptionButton(before cueID: UUID? = nil) -> some View {
        Button { insertCaption(before: cueID) } label: {
            HStack(spacing: 8) { Rectangle().frame(height: 1); Image(systemName: "plus").font(.system(size: 9)); Rectangle().frame(height: 1) }.foregroundStyle(ThemeColor.line).frame(height: 16).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text("添加字幕")).accessibilityLabel(L10n.text("添加字幕"))
    }
    private func insertCaption(before cueID: UUID? = nil) {
        guard let inserted = clips.insertSegmentCaption(project.id, range: subtitleRange,
                  playhead: playback.time, before: cueID, source: model.sourceLanguage, target: model.targetLanguage) else { return }
        remember()
        playback.clearSelection()
        selectedCueID = inserted.cue.id
        playback.player.pause()
        playback.seek(inserted.cue.start)
        newCueID = inserted.cue.id
    }
    private func currentCaption(_ cue: Caption) -> Caption {
        guard let latest = clips.projects.first(where: { $0.id == project.id }) else { return cue }
        return latest.captions(for: latest.subtitleRange).first { $0.id == cue.id } ?? cue
    }
    private func cueText(_ cue: Caption, original: Bool) -> Binding<String> {
        Binding(get: {
            original ? cue.original : cue.translated
        }, set: { value in
            if textUndoCue != cue.id { remember(); textUndoCue = cue.id }
            var current = currentCaption(cue)
            if original { current.original = value } else { current.translated = value }
            _ = clips.saveSegmentCaption(project.id, rangeID: project.id, cue: current)
        })
    }
    private var styleColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 6) {
                ForEach(ClipLanguageMode.allCases) { mode in
                    Button { var s = captionStyle; s.mode = mode; applyStyle(s) } label: { Text(L10n.text(mode.title)).frame(maxWidth: .infinity) }
                        .buttonStyle(ClipActionButtonStyle(accent: captionStyle.mode == mode ? ClipTheme.violet : nil, prominent: captionStyle.mode == mode))
                }
            }
            HStack(spacing: 12) { preset("白色", style: .classic); preset("浅粉", style: .pink); preset("浅金", style: .gold) }
        }.disabled(clips.isBusy)
    }
    private func importSubtitles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 5_000_000, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw ClipError.message("请选择 5 MB 以内的 UTF-8 或 UTF-16 字幕文件。") }
            let captions = try ClipSubtitleImport.parse(text, extension: url.pathExtension, layout: .automatic, offset: 0, duration: project.media.duration)
            guard let imported = clips.importProjectCaptions(project.id, captions: captions) else { return }
            remember()
            selectedCueID = imported.first?.id
        } catch { clips.notice = error.localizedDescription }
    }
    private func exportSubtitles(_ format: SubtitleExportFormat) {
        let track = cues
        let style = project.subtitleStyle(for: subtitleRange, displaying: track)
        let content = format == .txt ? track.map { style.lines($0).map(\.0).joined(separator: "\n") }.joined(separator: "\n\n") : ClipSubtitleImport.render(track, format: format, style: style)
        guard !content.isEmpty else { return }
        SubtitleSavePanel.present(format: format, suggestedName: project.name, from: NSApp.mainWindow) { url in
            do { try content.write(to: url, atomically: true, encoding: .utf8) }
            catch { clips.notice = error.localizedDescription }
        }
    }
    private func preset(_ name: String, style: ClipSubtitleStyle) -> some View {
        Button { var s = style; s.mode = captionStyle.mode; applyStyle(s) } label: {
            VStack(spacing: 5) { Text(L10n.text("中 / 日")).interfaceFont(size: 11, weight: .semibold).foregroundStyle(Color(nsColor: .clipHex(style.chinese.color))); Text(L10n.text(name)).interfaceFont(size: 9) }.frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(captionStyle.chinese.color == style.chinese.color ? ClipTheme.violet : ThemeColor.ink.opacity(0.1)))
        }.buttonStyle(.plain)
    }
    private var proofreadSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(L10n.text("模型核对")).font(.title3.bold()); Spacer(); Button(L10n.text("完成")) { showingProofread = false } }
            Toggle(L10n.text("使用服务设置中选定的翻译模型"), isOn: $configuredProofreading).disabled(clips.isBusy)
            Text(L10n.text(configuredProofreading ? "云端核对将发送当前日语、前两句日中字幕、后一句日语和邻近上下文匹配的术语；不发送音视频。在模型与服务中选择翻译服务。" : "使用本机翻译模型，结合前后文和本地术语库，不上传字幕。")).font(.caption).foregroundStyle(ThemeColor.muted)
            Button(L10n.text("开始核对全片字幕")) {
                if confirmCloudUse(translationOnly: true, wholeVideo: true) { clips.start(ClipJob(projectID: project.id, kind: .proofread, range: subtitleRange, configuredServices: configuredProofreading), model: model) }
            }.disabled(clips.isBusy || cues.allSatisfy { $0.original.isEmpty })
            ScrollView {
                ForEach(subtitleRange.proofreadCandidates ?? []) { cue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cue.original)
                        Text(L10n.text("现有：") + (cues.first { $0.id == cue.id }?.translated ?? "")).foregroundStyle(ThemeColor.muted)
                        Text(L10n.text("建议：") + cue.translated).foregroundStyle(ClipTheme.cyan)
                        Button(L10n.text("应用这条建议")) { remember(); _ = clips.applyProofread(project.id, rangeID: project.id, cue: cue) }.disabled(clips.isBusy)
                    }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if clips.isBusy { ProgressView(); Text(L10n.text(clips.currentJob?.message ?? "处理中…")).font(.caption) }
            else if subtitleRange.proofreadCandidates?.isEmpty == true { Text(L10n.text("核对完成，没有不同的译文建议。")).font(.caption).foregroundStyle(ThemeColor.muted) }
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
    private func addRange() { guard saveWorking() else { return }; duplicate(hasRange ? active : project.wholeRange) }
    private func duplicate(_ range: ClipRange) {
        remember()
        var next = ClipRange(title: "选段 \((project.ranges.compactMap { Int($0.title.split(separator: " ").last ?? "") }.max() ?? project.ranges.count) + 1)", start: range.start, end: range.end)
        next.subtitleStyle = range.subtitleStyle
        guard clips.saveRange(project.id, range: next) else { return }
        working = next; syncTimes(); playback.select(next.start...next.end)
    }
    private func resizeRole(_ id: UUID, chinese: Double, japanese: Double) {
        remember()
        clips.update(project.id) { project in
            guard var roles = project.captionRoles, let index = roles.firstIndex(where: { $0.id == id }) else { return }
            roles[index].chinese.size = chinese
            roles[index].japanese.size = japanese
            project.captionRoles = roles
        }
    }
    private func applyStyle(_ style: ClipSubtitleStyle, recordingUndo: Bool = false) {
        let range = subtitleRange
        guard style != project.subtitleStyle(for: range, displaying: cues) else { return }
        guard style.valid else { clips.notice = "样式参数无效。"; return }
        guard clips.updateSubtitleRange(project.id, range: range, change: { $0.subtitleStyle = style }) != nil else { return }
        if recordingUndo { remember() }
    }
    private func recommend(_ maximum: Int) {
        guard saveWorking() else { return }
        let selected = hasRange ? active : nil
        if ClipHighlights.transcript(project, in: selected).isEmpty {
            guard project.media.hasAudio else { clips.notice = "请先导入字幕，再推荐高光。"; return }
            guard confirmCloudUse(translationOnly: false) else { return }
            remember()
            let scope = hasRange ? active : ClipRange(title: project.name, start: 0, end: min(60, project.media.duration))
            clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: scope, configuredServices: true, sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage, recommendationCount: maximum), model: model)
        } else { clips.start(ClipJob(projectID: project.id, kind: .recommend, range: selected, recommendationCount: maximum), model: nil) }
    }
    private func transcribe() {
        guard confirmCloudUse(translationOnly: false, wholeVideo: true) else { return }
        do {
            let key = try model.clipGenerationKey(source: model.sourceLanguage, target: model.targetLanguage)
            remember()
            clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: subtitleRange, configuredServices: true,
                                generationServiceKey: key, sourceLanguage: model.sourceLanguage, targetLanguage: model.targetLanguage), model: model)
        } catch { clips.notice = error.localizedDescription }
    }
    private func confirmCloudUse(translationOnly: Bool, wholeVideo: Bool = false) -> Bool {
        guard !translationOnly || configuredProofreading else { return true }
        let ids = translationOnly ? [model.selectedTranslationProfileID] : [model.recognitionProfile(for: model.sourceLanguage)?.id, model.selectedTranslationProfileID]
        let services = model.profiles.filter { ids.contains($0.id) && $0.kind != .local }
        guard !services.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.text("调用云端服务？")
        alert.informativeText = services.map(\.name).joined(separator: "、") + L10n.text(wholeVideo ? "将处理整个视频，可能消耗账户额度并产生费用。" : (hasRange ? "将处理当前选段，可能消耗账户额度并产生费用。" : "将处理视频的前 60 秒，可能消耗账户额度并产生费用。")) + L10n.text(services.contains { $0.purpose == .speechRecognition } ? "识别服务会收到音频；翻译服务会收到字幕文本。" : "仅发送字幕文字，不上传音视频。") + L10n.text("具体费用以服务商计费为准。")
        alert.addButton(withTitle: L10n.text("继续")); alert.addButton(withTitle: L10n.text("取消"))
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

private struct ClipFinishedNotice: View {
    let started: Date
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.simuSubReduceMotion) private var appReduceMotion

    var body: some View {
        let reduceMotion = systemReduceMotion || appReduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { frame in
            let elapsed = max(0, frame.date.timeIntervalSince(started))
            HStack(spacing: 6) {
                Text(verbatim: "Finished!").interfaceFont(size: 12, weight: .semibold)
                ZStack {
                    Circle().stroke(ThemeColor.line, lineWidth: 1.5)
                    Circle().trim(from: 0, to: 0.32)
                        .stroke(ThemeColor.primaryInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? -90 : elapsed * 180 - 90))
                }.frame(width: 12, height: 12).accessibilityHidden(true)
            }
            .foregroundStyle(ThemeColor.primaryInk)
            .opacity(reduceMotion ? 1 : min(1, max(0, (2 - elapsed) / 0.18)))
        }.accessibilityIdentifier("clips.subtitleResult")
    }
}

private struct ClipCaptionEditor: View {
    var projectID: UUID
    var range: ClipRange
    @State var cue: Caption
    var inheritedRoleID: UUID?
    @EnvironmentObject private var clips: ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("编辑字幕")).font(.title3.bold())
            HStack {
                Text(L10n.text("从这条起")).font(.caption).foregroundStyle(ThemeColor.muted)
                ClipCaptionRoleMenu(projectID: projectID, baseStyle: range.style, sample: cue, cue: $cue, inheritedRoleID: inheritedRoleID)
            }
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
        }.padding(24).frame(width: 520).onAppear {
            start = ClipTime.label(cue.start)
            end = ClipTime.label(cue.end)
        }
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
    let projectID: UUID
    let rangeID: UUID?
    let onRecommend: (Int) -> Void
    let onEdit: (ClipRange) -> Void
    let onPreview: (ClipRange) -> Void
    let onClose: () -> Void
    @EnvironmentObject private var clips: ClipStore
    @State private var countText = "5"

    private var count: Int? {
        guard let amount = Int(countText.trimmingCharacters(in: .whitespaces)), amount > 0 else { return nil }
        return amount
    }

    var body: some View {
        if let project = clips.projects.first(where: { $0.id == projectID }) {
            let candidates = project.candidates ?? []
            let job = clips.jobs.first { $0.projectID == projectID }
            let selected = project.ranges.first { $0.id == rangeID }
            let hasSource = project.media.hasAudio || !ClipHighlights.transcript(project, in: selected).isEmpty
            let ready = count != nil && !clips.isBusy && hasSource
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L10n.text("高光候选")).interfaceFont(size: 16, weight: .semibold)
                    Spacer()
                    action("checkmark", "完成", id: "clips.highlights.done", perform: onClose)
                }
                HStack(spacing: 10) {
                    Text(L10n.text("最多段数")).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
                    Spacer()
                    TextField("5", text: $countText).textFieldStyle(ClipFieldStyle()).multilineTextAlignment(.center)
                        .monospacedDigit().frame(width: 60).accessibilityLabel(L10n.text("最多段数"))
                        .accessibilityIdentifier("clips.highlights.count")
                        .onSubmit { if ready, let count { onRecommend(count) } }
                    action("sparkles", "分析并推荐", id: "clips.recommend", prominent: true) {
                        if let count { onRecommend(count) }
                    }.disabled(!ready)
                }
                if count == nil {
                    Text(L10n.text("请输入正整数。")).font(.caption).foregroundStyle(ThemeColor.muted)
                } else if !hasSource {
                    Text(L10n.text("请先导入字幕，再推荐高光。")).font(.caption).foregroundStyle(ThemeColor.muted)
                }
                if let job, job.kind == .recommend || job.recommendationCount != nil {
                    if job.state == .running {
                        ProgressView(value: job.progress).tint(ThemeColor.primary)
                        Text(L10n.text(job.message)).font(.caption).foregroundStyle(ThemeColor.muted)
                    } else if job.state == .failed {
                        Text(L10n.text(job.message)).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled)
                    }
                }
                if !candidates.isEmpty {
                    Divider().overlay(ThemeColor.line)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(candidates) { range in
                                HStack(spacing: 8) {
                                    Toggle(L10n.text("选择高光"), isOn: Binding(get: { range.selected }, set: { selected in
                                        clips.update(projectID) { current in
                                            if let i = current.candidates?.firstIndex(where: { $0.id == range.id }) {
                                                current.candidates?[i].selected = selected
                                            }
                                        }
                                    })).labelsHidden().toggleStyle(.checkbox).tint(ThemeColor.primary)
                                        .accessibilityLabel(L10n.text("选择高光") + " " + range.title)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: range.title).interfaceFont(size: 12, weight: .medium).lineLimit(1)
                                        Text(verbatim: ClipTime.label(range.start) + " – " + ClipTime.label(range.end))
                                            .font(.caption2).monospacedDigit().foregroundStyle(ThemeColor.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    action("play", "预览", id: "clips.highlights.preview", perform: { onPreview(range) })
                                    action("slider.horizontal.3", "调整", id: "clips.highlights.edit", perform: { onEdit(range) })
                                }.padding(.vertical, 4).disabled(clips.isBusy)
                            }
                        }
                    }.frame(height: min(CGFloat(candidates.count) * 45, 220))
                    HStack {
                        Spacer()
                        Button(L10n.text("添加选中片段")) { clips.addCandidates(projectID) }
                            .buttonStyle(ThemeActionButtonStyle())
                            .disabled(clips.isBusy || !candidates.contains(where: \.selected))
                    }
                }
            }.padding(18).frame(width: 330).foregroundStyle(ThemeColor.ink).background(ThemeColor.surface)
                .onExitCommand(perform: onClose)
        }
    }

    private func action(_ symbol: String, _ title: String, id: String, prominent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).interfaceFont(size: 13, weight: .semibold).frame(width: 30, height: 28)
                .foregroundStyle(prominent ? ThemeColor.surface : ThemeColor.primaryInk)
                .background(prominent ? ThemeColor.primary : ThemeColor.soft, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(L10n.text(title)).accessibilityLabel(L10n.text(title)).accessibilityIdentifier(id)
    }
}


extension View {
    func clipPanelCard() -> some View {
        self.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(ClipTheme.panel, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ThemeColor.ink.opacity(0.12)))
    }
}
