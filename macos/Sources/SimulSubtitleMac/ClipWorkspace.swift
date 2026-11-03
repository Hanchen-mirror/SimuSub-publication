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
    @State private var importing = false
    @State private var entered = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            if let project = clips.selected {
                ClipEditor(project: project, onImport: importVideo, onBack: onBack, onLibrary: { showingLibrary = true }, onRemove: { removing = true }).id(project.id)
            } else {
                importPage
            }
            if clips.currentJob != nil { jobBar }
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
            .confirmationDialog("移出当前项目？原视频和导出文件会保留。", isPresented: $removing, titleVisibility: .visible) {
                Button("移出工作台") { if let id = clips.selectedID { clips.removeProject(id) } }
                Button("取消", role: .cancel) {}
            }
            .alert("剪辑工作台", isPresented: Binding(get: { clips.notice != nil }, set: { if !$0 { clips.notice = nil } })) { Button("知道了") { clips.notice = nil } } message: { Text(clips.notice ?? "") }
            .accessibilityIdentifier("clips.workspace")
    }
    private var importPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button(action: onBack) { Label("返回工作空间", systemImage: "arrow.left") }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("clips.back")
                Text("剪辑工作台").font(.system(size: 26, weight: .semibold)).padding(.bottom, 14)
                VStack(spacing: 18) {
                    Image(systemName: "scissors").font(.system(size: 27, weight: .light)).foregroundStyle(ThemeColor.primary).frame(width: 66, height: 66).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 22))
                    Text(importing ? "正在导入…" : "把视频放到这里").font(.system(size: 23, weight: .semibold))

                    Button(action: importVideo) { Label("打开视频", systemImage: "plus") }.buttonStyle(ThemeActionButtonStyle(prominent: true)).disabled(importing || clips.isBusy).accessibilityIdentifier("clips.import")

                }.frame(maxWidth: .infinity).frame(height: 368)
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
                    HStack { Text("最近项目").font(.system(size: 15, weight: .semibold)); Spacer(); Button("录制历史") { showingLibrary = true }.accessibilityIdentifier("clips.library") }
                    if clips.projects.isEmpty { Text("暂无项目").font(.system(size: 12)).foregroundStyle(ThemeColor.muted) }
                    ForEach(clips.projects.prefix(4)) { project in
                        Divider().overlay(ThemeColor.line)
                        HStack(spacing: 14) { Image(systemName: "film").foregroundStyle(ThemeColor.primary).frame(width: 40, height: 40).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) { Text(project.name); Text("\(project.ranges.count) 个选段 · " + ClipTime.label(project.media.duration)).font(.caption).foregroundStyle(ThemeColor.muted) }
                            Spacer(); Button("继续剪辑") { clips.selectedID = project.id }.disabled(clips.isBusy)
                        }
                    }
                }.designPanel()
            }.padding(32)
        }.background(ThemeColor.background)
    }
    private var jobBar: some View {
        HStack(spacing: 12) {
            if let job = clips.currentJob ?? clips.jobs.first(where: { $0.projectID == clips.selectedID }) {
                if job.state == .running { ProgressView(value: job.progress).frame(width: 100) }
                else { Circle().fill(job.state == .completed ? .green : .orange).frame(width: 7, height: 7) }
                Text(job.message).font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                if job.state == .running { Button("暂停", action: clips.pause); Button("取消", action: clips.cancel) }
                else if [.failed, .interrupted, .paused, .cancelled].contains(job.state) { Button("按已保存设置重试") { clips.start(job, model: model) }.help("使用已保存的选段时间与字幕；内容未改动时复用成片并补齐字幕文件。") }
            } else {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(clips.selected == nil ? "等待导入视频" : "已载入视频 · 各选段独立保存").font(.caption).foregroundStyle(ThemeColor.muted)
                Spacer()
            }
        }.padding(.horizontal, 20).padding(.vertical, 10).background(ThemeColor.soft)
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("项目与录制历史").font(.title3.bold()); Spacer(); Button("完成") { showingLibrary = false } }
            List {
                Section("剪辑项目") {
                    ForEach(clips.projects) { p in Button { clips.selectedID = p.id; showingLibrary = false } label: {
                        VStack(alignment: .leading) { Text(p.name); Text("\(p.ranges.count) 个选段 · " + ClipTime.label(p.media.duration)).font(.caption).foregroundStyle(ThemeColor.muted) }
                    }.buttonStyle(.plain).disabled(clips.isBusy) }
                }
                Section("直播录制") {
                    ForEach(monitor.recordings) { recording in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(recording.creatorName + " · " + recording.state.title)
                            ForEach(Array(recording.closedMediaURLs.enumerated()), id: \.element.path) { i, url in
                                Button("导入片段 \(i + 1)") { load(url, creator: recording.creatorID, name: recording.creatorName); showingLibrary = false }.disabled(clips.isBusy)
                            }
                            if recording.closedMediaURLs.isEmpty { Text("等待录制片段保存").font(.caption).foregroundStyle(ThemeColor.muted) }
                        }
                    }
                }
            }
            Button("导入其他视频…", action: importVideo).disabled(clips.isBusy)
        }.padding(22).frame(width: 580, height: 500).background(ThemeColor.background)
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
    @State private var batch = false
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
    private var cues: [Caption] { project.captions(for: active) }
    private var sample: Caption { cues.first ?? Caption(start: 0, end: 4, original: "今日はここから始めましょう。", translated: "今天我们从这里开始。") }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    editorToolbar
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            ClipStyledPlayer(player: playback.player, captions: cues, style: draggedStyle ?? active.style,
                                mediaSize: CGSize(width: project.media.width, height: project.media.height),
                                onPosition: movingSubtitles ? { point, commit in
                                    var style = draggedStyle ?? active.style
                                    var position = style.position ?? ClipSubtitlePosition()
                                    position.x = point.x; position.y = point.y; style.position = position
                                    draggedStyle = style
                                    if commit { applyStyle(style); draggedStyle = nil }
                                } : nil)
                                .frame(height: max(300, min(465, geometry.size.height - 320)))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            HStack {
                                Button {
                                    movingSubtitles.toggle(); playback.player.pause()
                                } label: { Label(movingSubtitles ? "完成定位" : "移动字幕", systemImage: "arrow.up.and.down.and.arrow.left.and.right") }
                                    .disabled(cues.isEmpty || clips.isBusy).help("拖动视频中的字幕，位置会保存并用于导出")
                                    .accessibilityIdentifier("clips.moveSubtitles")
                                if active.style.position != nil { Button("恢复位置") { var s = active.style; s.position = nil; applyStyle(s) } }
                                Spacer()
                                Picker("倍速", selection: $playback.speed) { ForEach([0.5,1,1.5,2], id: \.self) { Text(String(format: "%.1f×", $0)).tag($0) } }.labelsHidden().frame(width: 72)
                                Button("原文件") { clips.reveal(project.media.path) }
                            }
                        }.frame(maxWidth: .infinity).accessibilityIdentifier("clips.videoPanel")
                        VStack(alignment: .leading, spacing: 20) {
                            HStack {
                                Text("字幕").font(.system(size: 16, weight: .semibold)); Spacer()
                                Button(action: importSubtitles) { Image(systemName: "square.and.arrow.up") }.help("导入字幕").accessibilityIdentifier("clips.importSubtitles")
                                Button { showingStyle = true } label: { Image(systemName: "textformat") }.help("字幕样式").accessibilityIdentifier("clips.customStyle")
                                Menu {
                                    Button("生成字幕", action: transcribe)
                                    Button("核对译文") { showingProofread = true }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
                            }.buttonStyle(.plain)
                            subtitleColumn
                        }.padding(22).frame(width: max(360, min(420, (geometry.size.width - 88) * 0.36)), height: max(350, min(515, geometry.size.height - 270)))
                            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 18)).accessibilityIdentifier("clips.inspector")
                    }
                    rangePanel
                }.padding(.horizontal, 28).padding(.vertical, 24)
            }
        }
            .onAppear { syncTimes(); playback.seek(working.start) }
            .onDisappear { playback.player.pause() }
            .onChange(of: clips.jobs.first?.state) { state in
                if let count = pendingRecommendation, let job = clips.jobs.first, job.projectID == project.id, job.kind == .transcribe, state != .running {
                    pendingRecommendation = nil
                    if state == .completed { clips.start(ClipJob(projectID: project.id, kind: .recommend, recommendationCount: count), model: nil) }
                }
            }
            .onChange(of: project.ranges.map(\.id)) { ids in
                if !ids.contains(working.id) { working = project.ranges.first ?? ClipRange(title: "选段 1", start: 0, end: min(60, project.media.duration)); syncTimes() }
            }
            .sheet(item: $editing) { cue in ClipCaptionEditor(projectID: project.id, range: active, cue: cue).appTheme() }
            .sheet(isPresented: $showingStyle) { VStack(alignment: .leading, spacing: 24) { HStack { Text("字幕样式").font(.headline); Spacer(); Button("完成") { showingStyle = false } }; styleColumn }.padding(28).frame(width: 530).background(ThemeColor.surface).appTheme() }
            .sheet(isPresented: $showingProofread) { proofreadSheet }
            .sheet(isPresented: $showingHighlights) {
                VStack {
                    HStack { Text("高光候选").font(.system(size: 14, weight: .semibold)); Spacer(); Button("完成") { showingHighlights = false } }
                    ClipHighlightsPanel(project: project, onRecommend: recommend, onEdit: { r in clips.saveRange(project.id, range: r); working = r; syncTimes(); showingHighlights = false }, onPreview: { r in working = r; syncTimes(); showingHighlights = false; playback.seek(r.start) })
                }.padding(22).frame(width: 700, height: 520).background(ThemeColor.background)
            }
            .sheet(isPresented: Binding(get: { previewing != nil }, set: { if !$0 { previewing = nil } })) {
                if let previewing { ClipVideoPreview(url: previewing, offset: project.previewStart ?? 0, hasSubtitles: project.previewHasSubtitles ?? false,
                    onSetStart: { working.start = min($0, working.end - 0.2); syncTimes(); _ = saveWorking() }, onSetEnd: { working.end = max($0, working.start + 0.2); syncTimes(); _ = saveWorking() }, onClose: { self.previewing = nil }) }
            }
            .confirmationDialog("移除这个选段？原视频和已导出文件会保留。", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
                Button("移除选段") { if let id = removeID { clips.update(project.id) { $0.ranges.removeAll { $0.id == id } } }; removeID = nil }
            }
    }
    private var editorToolbar: some View {
        HStack(spacing: 14) {
            Button { if saveWorking() { onBack() } } label: { Image(systemName: "arrow.left") }.buttonStyle(.plain).help("返回工作空间").accessibilityIdentifier("clips.back")
            Text(project.name).font(.system(size: 18, weight: .semibold)).lineLimit(1)
            Spacer()
            Button { showingHighlights = true } label: { Label("高光候选", systemImage: "sparkles") }.accessibilityIdentifier("clips.highlights")
            Menu {
                ForEach(SubtitleExportFormat.allCases) { format in Button("导出 " + format.title) { exportSubtitles(format) } }
                Divider()
                Toggle("内嵌字幕", isOn: $burn)
                Toggle("批量导出已选选段", isOn: $batch)
                Button("导出 MP4") { export(.mp4, subtitles: burn) }
                Button("导出 MP3") { export(.mp3, subtitles: false) }.disabled(!project.media.hasAudio)
            } label: { Label("导出", systemImage: "arrow.down.to.line").padding(.horizontal, 12).padding(.vertical, 10).foregroundStyle(ThemeColor.surface).background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 11)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 82, height: 40)
                .overlay { Label("导出", systemImage: "arrow.down.to.line").font(.system(size: 12)).frame(width: 82, height: 40).foregroundStyle(ThemeColor.surface).background(ThemeColor.primary, in: RoundedRectangle(cornerRadius: 11)).allowsHitTesting(false) }.accessibilityIdentifier("clips.export")
            Menu { Button("导入其他视频", action: onImport); Button("项目与录制历史", action: onLibrary); Button("移出工作台", action: onRemove) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
        }.disabled(clips.isBusy).frame(height: 44)
    }
    private var rangePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("选段").font(.system(size: 15, weight: .semibold)); Text("\(project.ranges.count)").font(.caption).foregroundStyle(ThemeColor.muted); Spacer()
                Button { addRange() } label: { Label("添加选段", systemImage: "plus") }.accessibilityIdentifier("clips.addRange")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(project.ranges) { range in
                        Button { switchRange(range) } label: { Text(range.title).font(.system(size: 12)).lineLimit(1).padding(.horizontal, 22).frame(height: 34).background(range.id == working.id ? ThemeColor.surface : .clear, in: RoundedRectangle(cornerRadius: 9)) }
                            .buttonStyle(.plain).contextMenu {
                                Toggle("加入批量导出", isOn: Binding(get: { range.selected }, set: { checked in clips.update(project.id) { p in if let i = p.ranges.firstIndex(where: { $0.id == range.id }) { p.ranges[i].selected = checked } } }))
                                Button("复制选段") { duplicate(range) }; Button("删除选段") { removeID = range.id }
                            }
                    }
                }.padding(4)
            }.background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 11))
            ClipRangeTimeline(start: $working.start, end: $working.end, duration: project.media.duration, energy: project.energy) { syncTimes(); _ = saveWorking() }.frame(height: 66)
            HStack(spacing: 16) {
                Text("名称").font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
                TextField("选段名称", text: $working.title).textFieldStyle(ClipFieldStyle()).frame(width: 190).onSubmit { _ = saveWorking() }.accessibilityIdentifier("clips.rangeTitle")
                timeField("开始", text: $startText).frame(width: 155)
                timeField("结束", text: $endText).frame(width: 155)
                Spacer(); Text(String(format: "%.2f s", working.duration)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
                Button { _ = saveWorking() } label: { Image(systemName: "checkmark") }.help("保存选段")
                Button { removeID = working.id } label: { Label("删除选段", systemImage: "xmark") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
            }
        }.designPanel().disabled(clips.isBusy).accessibilityIdentifier("clips.rangePanel")
    }
    private func timeField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(ThemeColor.muted)
            TextField("00:00:00.000", text: text).font(.system(size: 11, design: .monospaced)).textFieldStyle(ClipFieldStyle()).onSubmit { _ = saveWorking() }
        }.disabled(clips.isBusy)
    }
    private var subtitleColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(cues) { cue in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(ClipTime.label(cue.start) + " — " + ClipTime.label(cue.end)).font(.system(size: 10)).monospacedDigit().foregroundStyle(ThemeColor.muted)
                                Spacer()
                                Button { editing = cue } label: { Image(systemName: "clock") }.buttonStyle(.plain).help("编辑时间")
                                Button { clips.deleteSegmentCaption(project.id, rangeID: active.id, cueID: cue.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("删除字幕")
                            }
                            if selectedCaption?.id == cue.id {
                                TextField("日语", text: cueText(cue, original: true), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("clips.original")
                                TextField("中文", text: cueText(cue, original: false), axis: .vertical).lineLimit(1...6).textFieldStyle(.plain).font(.system(size: 13)).accessibilityIdentifier("clips.translation")
                            } else {
                                Text(cue.original).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                                Text(cue.translated).font(.system(size: 13))
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedCaption?.id == cue.id ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle()).onTapGesture { if selectedCaption?.id != cue.id { selectedCueID = cue.id; playback.seek(cue.start) } }
                            .accessibilityIdentifier("clips.cue." + cue.id.uuidString)
                    }
                    if cues.isEmpty { Text("暂无字幕").foregroundStyle(ThemeColor.muted).padding(40) }
                }
            }
            Button {
                let cue = Caption(start: max(working.start, min(playback.time, working.end - 0.2)), end: min(working.end, max(working.start, playback.time) + 3), original: "", translated: "")
                _ = clips.saveSegmentCaption(project.id, rangeID: active.id, cue: cue); selectedCueID = cue.id
            } label: { Label("添加字幕", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ThemeColor.primary)
        }.disabled(clips.isBusy)
    }
    private var selectedCaption: Caption? { cues.first { $0.id == selectedCueID } ?? cues.first }
    private func cueText(_ cue: Caption, original: Bool) -> Binding<String> {
        Binding(get: {
            let current = clips.selected?.captions(for: active).first { $0.id == cue.id } ?? cue
            return original ? current.original : current.translated
        }, set: { value in
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
                    Button { var s = active.style; s.mode = mode; applyStyle(s) } label: { Text(mode.rawValue).frame(maxWidth: .infinity) }
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
            clips.update(project.id) { p in if let i = p.ranges.firstIndex(where: { $0.id == working.id }) {
                p.ranges[i].importedCaptions = captions; p.ranges[i].captionEdits = nil; p.ranges[i].deletedCaptionIDs = nil; p.ranges[i].proofreadCandidates = nil
            } }
            selectedCueID = captions.first { $0.end > active.start && $0.start < active.end }?.id
        } catch { clips.notice = error.localizedDescription }
    }
    private func exportSubtitles(_ format: SubtitleExportFormat) {
        guard saveWorking() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = project.name + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = format == .txt ? cues.map { active.style.lines($0).map(\.0).joined(separator: "\n") }.joined(separator: "\n\n") : ClipSubtitleImport.render(cues, format: format, style: active.style)
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch { clips.notice = error.localizedDescription }
    }
    private func preset(_ name: String, style: ClipSubtitleStyle) -> some View {
        Button { var s = style; s.mode = active.style.mode; applyStyle(s) } label: {
            VStack(spacing: 5) { Text("中 / 日").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: .clipHex(style.chinese.color))); Text(name).font(.system(size: 9)) }.frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active.style.chinese.color == style.chinese.color ? ClipTheme.violet : ThemeColor.ink.opacity(0.1)))
        }.buttonStyle(.plain)
    }
    private var proofreadSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("模型核对").font(.title3.bold()); Spacer(); Button("完成") { showingProofread = false } }
            Toggle("使用服务设置中选定的翻译模型", isOn: $configured).disabled(clips.isBusy)
            Text(configured ? "云端核对将发送当前日语、前两句日中字幕、后一句日语和邻近上下文匹配的术语；不发送音视频。在模型与服务中选择翻译服务。" : "使用本机翻译模型，结合前后文和本地术语库，不上传字幕。").font(.caption).foregroundStyle(ThemeColor.muted)
            Button("开始核对当前选段") {
                if saveWorking() { if confirmCloudUse(translationOnly: true) { clips.start(ClipJob(projectID: project.id, kind: .proofread, range: active, configuredServices: configured), model: model) } }
            }.disabled(clips.isBusy || cues.allSatisfy { $0.original.isEmpty })
            ScrollView {
                ForEach(active.proofreadCandidates ?? []) { cue in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cue.original)
                        Text("现有：" + (cues.first { $0.id == cue.id }?.translated ?? "")).foregroundStyle(ThemeColor.muted)
                        Text("建议：" + cue.translated).foregroundStyle(ClipTheme.cyan)
                        Button("应用这条建议") { _ = clips.applyProofread(project.id, rangeID: working.id, cue: cue) }.disabled(clips.isBusy)
                    }.font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if clips.isBusy { ProgressView(); Text(clips.currentJob?.message ?? "处理中…").font(.caption) }
            else if active.proofreadCandidates?.isEmpty == true { Text("核对完成，没有不同的译文建议。").font(.caption).foregroundStyle(ThemeColor.muted) }
        }.padding(24).frame(width: 650, height: 540).background(ThemeColor.background)
    }
    private func syncTimes() { startText = ClipTime.label(working.start); endText = ClipTime.label(working.end) }
    @discardableResult private func saveWorking() -> Bool {
        guard let start = ClipTime.parse(startText), let end = ClipTime.parse(endText) else { clips.notice = "请输入有效的时:分:秒.毫秒。"; return false }
        working.start = start; working.end = end
        do { try working.validate(duration: project.media.duration); clips.saveRange(project.id, range: working); syncTimes(); return true } catch { clips.notice = error.localizedDescription; return false }
    }
    private func switchRange(_ range: ClipRange) { guard saveWorking() else { return }; draggedStyle = nil; movingSubtitles = false; working = range; syncTimes(); playback.seek(range.start) }
    private func addRange() { guard saveWorking() else { return }; duplicate(active) }
    private func duplicate(_ range: ClipRange) {
        var next = range; next.id = UUID(); next.title = "选段 \((project.ranges.compactMap { Int($0.title.split(separator: " ").last ?? "") }.max() ?? project.ranges.count) + 1)"; next.proofreadCandidates = nil
        clips.saveRange(project.id, range: next); working = next; syncTimes(); playback.seek(next.start)
    }
    private func applyStyle(_ style: ClipSubtitleStyle) { guard saveWorking() else { return }; clips.setStyle(project.id, rangeID: working.id, style: style) }
    private func recommend(_ maximum: Int) {
        guard saveWorking() else { return }
        if project.captions.isEmpty {
            guard project.media.hasAudio else { clips.notice = "请先导入字幕，再推荐高光。"; return }
            guard confirmCloudUse(translationOnly: false) else { return }
            pendingRecommendation = maximum
            clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: active, configuredServices: configured), model: model)
        } else { clips.start(ClipJob(projectID: project.id, kind: .recommend, recommendationCount: maximum), model: nil) }
    }
    private func transcribe() { guard saveWorking(), confirmCloudUse(translationOnly: false) else { return }; clips.start(ClipJob(projectID: project.id, kind: .transcribe, range: active, configuredServices: configured), model: model) }
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
        let ranges = batch ? selected.filter(\.selected) : selected.filter { $0.id == working.id }
        guard !ranges.isEmpty else { clips.notice = "请勾选至少一个要导出的选段。"; return }
        let panel = NSOpenPanel(); panel.title = "选择 \(kind.rawValue.uppercased()) 导出文件夹"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
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
            Text("字幕时间").font(.title3.bold())
            HStack { TextField("起点", text: $start); Text("→"); TextField("终点", text: $end) }.textFieldStyle(ClipFieldStyle())
            HStack {
                Button("删除这条字幕", role: .destructive) { clips.deleteSegmentCaption(projectID, rangeID: range.id, cueID: cue.id); dismiss() }
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
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
            HStack { Text(hasSubtitles ? "内嵌字幕成片预览" : "原画面选段预览").font(.system(size: 14, weight: .semibold)); Spacer(); Button("完成", action: onClose) }.padding(16)
            ClipNativePlayer(player: player).frame(minWidth: 640, minHeight: 360)
            HStack { Text("拖动进度条检查画面").font(.caption).foregroundStyle(ThemeColor.muted); Spacer(); Button("设为起点") { onSetStart(position) }; Button("设为终点") { onSetEnd(position) } }.padding(16)
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
        return configuration.label.font(.system(size: 12, weight: .medium))
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
                Label("高光候选", systemImage: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
                Spacer()
                Picker("数量", selection: $maximum) { Text("最多 3 段").tag(3); Text("最多 5 段").tag(5); Text("最多 8 段").tag(8) }.labelsHidden().frame(width: 110)
                Button(project.captions.isEmpty ? "分析并推荐" : "推荐高光") { onRecommend(maximum) }
                    .disabled(clips.isBusy || (project.captions.isEmpty && !project.media.hasAudio)).accessibilityIdentifier("clips.recommend")
            }
            ForEach(project.candidates ?? []) { range in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("选择高光", isOn: Binding(get: { range.selected }, set: { selected in
                        clips.update(project.id) { p in if let i = p.candidates?.firstIndex(where: { $0.id == range.id }) { p.candidates?[i].selected = selected } }
                    })).labelsHidden()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(range.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(ClipTime.label(range.start) + " – " + ClipTime.label(range.end)).font(.system(size: 10)).monospacedDigit().foregroundStyle(ThemeColor.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("预览") { onPreview(range) }
                    Button("调整") { onEdit(range) }
                }.padding(10).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 9)).disabled(clips.isBusy)
            }
            if !(project.candidates ?? []).isEmpty {
                HStack {
                    Spacer()
                    Button("添加选中片段") { clips.addCandidates(project.id) }
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
