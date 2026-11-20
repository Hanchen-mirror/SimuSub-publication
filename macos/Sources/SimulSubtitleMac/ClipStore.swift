import AppKit

@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var projects: [ClipProject]
    @Published private(set) var jobs: [ClipJob]
    @Published var selectedID: UUID?
    @Published var notice: String?
    private let storage: LiveMonitorStorage
    private let writeSubtitle: (String, URL) throws -> Void
    private var task: Task<Void, Never>?
    private var pauseRequested = false
    private var lastProgressSave = Date.distantPast
    var isBusy: Bool { task != nil }
    var currentJob: ClipJob? { jobs.first { $0.state == .running } }
    var selected: ClipProject? { projects.first { $0.id == selectedID } }
    var root: URL { storage.root }
    static var diagnosticRoot: URL? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--clip-demo"), args.count > i + 1 { return URL(fileURLWithPath: args[i + 1]) }
        return AppLaunchOptions.isDiagnostic ? FileManager.default.temporaryDirectory.appendingPathComponent("simusub-clip-checks-" + UUID().uuidString) : nil
    }
    init(root: URL? = nil, writeSubtitle: @escaping (String, URL) throws -> Void = { text, url in
        try text.write(to: url, atomically: true, encoding: .utf8)
    }) {
        self.writeSubtitle = writeSubtitle
        storage = LiveMonitorStorage(root: root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SimuSub/Clips"))
        let (projects, p) = storage.load([ClipProject].self, name: "projects", fallback: [])
        let (jobs, j) = storage.load([ClipJob].self, name: "jobs", fallback: [])
        self.projects = projects
        self.jobs = jobs.map { var value = $0; if value.state == .running { value.state = .interrupted; value.message = "上次任务未完成，已完成的字幕与成片保留，可重试。" }; return value }
        // Only remove exact temporary paths registered by our own jobs. Never
        // scan or delete unrelated user videos in an export folder.
        for job in jobs where job.state == .running {
            for path in job.temporaryPaths ?? [] {
                let url = URL(fileURLWithPath: path)
                if url.lastPathComponent.range(of: #"^\.simusub-(cut-)?[A-F0-9-]{36}\.(mp4|mp3)$"#, options: .regularExpression) != nil, ["mp4", "mp3"].contains(url.pathExtension),
                   url.deletingLastPathComponent().standardizedFileURL == job.outputFolder.map({ URL(fileURLWithPath: $0).standardizedFileURL }) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        selectedID = projects.first?.id
        notice = [p, j].compactMap { $0 }.joined(separator: "\n"); if notice == "" { notice = nil }
    }
    @discardableResult func importVideo(_ url: URL, creatorID: UUID? = nil, name: String? = nil, outputGrouping: [String]? = nil) async throws -> UUID {
        let media = try await ClipMediaEngine.inspect(url)
        if let match = projects.first(where: { $0.media == media }) { selectedID = match.id; return match.id }
        let project = ClipProject(name: name ?? url.deletingPathExtension().lastPathComponent, creatorID: creatorID, outputGrouping: outputGrouping, media: media)
        projects.insert(project, at: 0); selectedID = project.id; persist()
        let posters = root.appendingPathComponent("Posters")
        try? FileManager.default.createDirectory(at: posters, withIntermediateDirectories: true)
        let poster = posters.appendingPathComponent(project.id.uuidString + ".png")
        if (try? await ClipMediaEngine.poster(media: media, output: poster)) != nil { update(project.id) { $0.posterPath = poster.path } }
        return project.id
    }
    func update(_ id: UUID, _ change: (inout ClipProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let oldRanges = projects[index].ranges
        let oldRoles = projects[index].captionRoles
        let oldCaptions = projects[index].captions
        let oldPreview = projects[index].previewPath
        change(&projects[index])
        if projects[index].captions != oldCaptions || projects[index].ranges != oldRanges || projects[index].captionRoles != oldRoles {
            removePreview(oldPreview); projects[index].previewPath = nil
        }
        projects[index].updatedAt = Date(); persist()
    }
    @discardableResult func saveRange(_ id: UUID, range: ClipRange) -> Bool {
        guard let p = projects.first(where: { $0.id == id }) else { return false }
        do {
            try range.validate(duration: p.media.duration)
            update(id) { p in
                if let i = p.ranges.firstIndex(where: { $0.id == range.id }) {
                    p.ranges[i].start = range.start; p.ranges[i].end = range.end
                    p.ranges[i].title = range.title
                }
                else { p.ranges.append(range) }
                p.candidates?.removeAll { $0.id == range.id }
            }
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    func removeProject(_ id: UUID) {
        guard !isBusy else { return }
        guard let project = projects.first(where: { $0.id == id }) else { return }
        removePreview(project.previewPath)
        try? FileManager.default.removeItem(at: ClipPlaybackSource.cachedURL(for: project.media))
        projects.removeAll { $0.id == id }; jobs.removeAll { $0.projectID == id }
        if selectedID == id { selectedID = projects.first?.id }; persist()
    }
    func saveSegmentCaption(_ id: UUID, rangeID: UUID, cue: Caption) -> Bool {
        guard let p = projects.first(where: { $0.id == id }), let range = p.ranges.first(where: { $0.id == rangeID }),
              cue.start.isFinite, cue.end.isFinite, cue.start >= range.start, cue.end <= range.end + 0.001, cue.end > cue.start,
              cue.original.count <= 1000, cue.translated.count <= 1000 else { notice = "字幕时间应在当前选段内，单条文字不超过 1000 字。"; return false }
        guard !p.captions(for: range).contains(where: { $0.id != cue.id && $0.start < cue.end - 0.001 && $0.end > cue.start + 0.001 }) else { notice = "字幕时间与另一条重叠，请先调整边界。"; return false }
        update(id) { p in
            guard let i = p.ranges.firstIndex(where: { $0.id == rangeID }) else { return }
            var edits = p.ranges[i].captionEdits ?? []; edits.removeAll { $0.id == cue.id }; edits.append(cue)
            p.ranges[i].captionEdits = edits; p.ranges[i].deletedCaptionIDs?.removeAll { $0 == cue.id }
        }
        return true
    }
    @discardableResult func applyProofread(_ id: UUID, rangeID: UUID, cue: Caption) -> Bool {
        var revised = cue
        if let project = projects.first(where: { $0.id == id }),
           let range = project.ranges.first(where: { $0.id == rangeID }),
           let current = project.captions(for: range).first(where: { $0.id == cue.id }) {
            revised.clipRoleID = current.clipRoleID
            revised.clipUsesDefault = current.clipUsesDefault
        }
        guard saveSegmentCaption(id, rangeID: rangeID, cue: revised) else { return false }
        update(id) { p in if let i = p.ranges.firstIndex(where: { $0.id == rangeID }) {
            p.ranges[i].proofreadCandidates?.removeAll { $0.id == cue.id }
        } }
        return true
    }
    func deleteSegmentCaption(_ id: UUID, rangeID: UUID, cueID: UUID) {
        update(id) { p in if let i = p.ranges.firstIndex(where: { $0.id == rangeID }) {
            let visible = p.captions(for: p.ranges[i])
            if let index = visible.firstIndex(where: { $0.id == cueID }),
               visible[index].clipRoleID != nil || visible[index].clipUsesDefault == true,
               visible.indices.contains(index + 1) {
                var next = visible[index + 1]
                if next.clipRoleID == nil && next.clipUsesDefault != true {
                    next.assignClipRole(visible[index].clipRoleID)
                    var edits = p.ranges[i].captionEdits ?? []
                    edits.removeAll { $0.id == next.id }
                    edits.append(next)
                    p.ranges[i].captionEdits = edits
                }
            }
            var deleted = p.ranges[i].deletedCaptionIDs ?? []; deleted.append(cueID); p.ranges[i].deletedCaptionIDs = deleted
            p.ranges[i].captionEdits?.removeAll { $0.id == cueID }
        } }
    }
    func setStyle(_ id: UUID, rangeID: UUID, style: ClipSubtitleStyle, all: Bool = false) {
        guard style.valid else { notice = "样式参数无效。"; return }
        update(id) { p in for i in p.ranges.indices where all || p.ranges[i].id == rangeID { p.ranges[i].subtitleStyle = style } }
    }
    func saveCaption(_ id: UUID, cue: Caption) {
        guard let p = projects.first(where: { $0.id == id }), cue.start.isFinite, cue.end.isFinite,
              cue.start >= 0, cue.end <= p.media.duration + 0.05, cue.end > cue.start,
              cue.original.count <= 1000, cue.translated.count <= 1000 else { notice = "字幕时间应在视频内，单条文字不超过 1000 字。"; return }
        let other = p.captions.filter { $0.id != cue.id }
        guard !other.contains(where: { $0.start < cue.end - 0.001 && $0.end > cue.start + 0.001 }) else { notice = "字幕时间与另一条重叠，请先调整边界。"; return }
        mergeCaption(id, cue: cue)
    }
    private func mergeCaption(_ id: UUID, cue: Caption) {
        update(id) { project in
            if let i = project.captions.firstIndex(where: { $0.id == cue.id }) { project.captions[i] = cue }
            else { project.captions.append(cue) }
            project.captions.sort { $0.start < $1.start }
        }
    }
    func start(_ job: ClipJob, model: AppModel?, services: ClipServices? = nil) {
        guard task == nil else { notice = "请等待当前任务完成，或先取消。"; return }
        guard let project = projects.first(where: { $0.id == job.projectID }) else { return }
        pauseRequested = false
        var pending = job
        if job.kind == .transcribe {
            pending.sourceLanguage = job.sourceLanguage ?? services?.sourceLanguage ?? project.captions.first?.sourceLanguage ?? model?.sourceLanguage ?? .japanese
            pending.targetLanguage = job.targetLanguage ?? services?.targetLanguage ?? project.captions.first?.targetLanguage ?? model?.targetLanguage ?? .simplifiedChinese
        }
        if job.kind == .export, !jobs.contains(where: { $0.id == job.id }), let base = job.outputFolder,
           let grouping = project.outputGrouping, grouping.count == 2,
           grouping.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) {
            pending.outputFolder = grouping.reduce(URL(fileURLWithPath: base)) { $0.appendingPathComponent($1, isDirectory: true) }.path
        }
        // Retry uses saved current ranges, with one consistent project snapshot.
        // Receipts are retained only when their content fingerprint still matches.
        let retry = jobs.contains { $0.id == job.id }
        if job.kind == .export && !retry {
            let requested = Set(job.ranges.map(\.id))
            pending.ranges = project.ranges.filter { requested.contains($0.id) && $0.selected }
            guard !pending.ranges.isEmpty else { notice = "请勾选至少一个要导出的选段。"; return }
        }
        if retry {
            if job.kind == .export {
                guard job.ranges.allSatisfy({ old in project.ranges.contains { $0.id == old.id } }) else {
                    notice = "原任务中的选段已移除，请重新选择选段导出。"; return
                }
                pending.ranges = job.ranges.compactMap { old in project.ranges.first { $0.id == old.id } }
            } else if let range = job.range, let saved = project.ranges.first(where: { $0.id == range.id }) {
                pending.range = saved
            }
        }
        notice = nil
        var identities = Set<UUID>()
        pending.ranges = pending.ranges.filter { identities.insert($0.id).inserted }
        pending.id = UUID(); pending.state = .running; pending.progress = 0; pending.message = "正在准备…"
        let job = pending; jobs.insert(job, at: 0); persist()
        let jobID = job.id
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil; self.persist() }
            do {
                try Task.checkCancellation(); try project.media.validateFile()
                switch job.kind {
                case .recommend:
                    let count = job.recommendationCount ?? 5
                    let result = await Task.detached(priority: .utility) { ClipHighlights.recommend(project, maximum: count) }.value
                    try Task.checkCancellation()
                    self.update(project.id) { $0.candidates = result.candidates; $0.highlightsNote = result.note }
                    guard !result.candidates.isEmpty else { throw ClipError.message(result.note) }
                case .preview:
                    guard let range = job.range else { throw ClipError.message("请先选择预览范围。") }
                    try range.validate(duration: project.media.duration)
                    let folder = self.root.appendingPathComponent("Previews")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent(UUID().uuidString + ".mp4")
                    let savedRange = project.ranges.first { $0.id == range.id } ?? range
                    let cues = ClipTime.captions(project.styledCaptions(for: savedRange), within: range)
                    let burn = job.burnSubtitles && savedRange.style.complete(cues)
                    let raw = folder.appendingPathComponent(UUID().uuidString + ".mp4")
                    defer { try? FileManager.default.removeItem(at: raw) }
                    do {
                        try await ClipMediaEngine.cut(media: project.media, range: range, output: burn ? raw : url)
                        if job.burnSubtitles && !savedRange.style.complete(cues) { throw ClipError.message("当前语言模式的字幕尚未补全，请先识别、导入或编辑字幕。") }
                        if burn { try await ClipMediaEngine.burn(input: raw, output: url, captions: cues, style: savedRange.style, roles: project.captionRoles ?? []) }
                        try Task.checkCancellation()
                        guard let current = self.projects.first(where: { $0.id == project.id }),
                              current.ranges == project.ranges, current.captions == project.captions,
                              current.captionRoles == project.captionRoles else {
                            throw ClipError.message("字幕或样式已改变，请重新生成预览。")
                        }
                        self.removePreview(current.previewPath)
                        self.update(project.id) { $0.previewPath = url.path; $0.previewStart = range.start; $0.previewEnd = range.end; $0.previewHasSubtitles = burn; $0.previewRangeID = range.id }
                    } catch { try? FileManager.default.removeItem(at: url); throw error }
                case .transcribe:
                    guard let range = job.range else { throw ClipError.message("请先选择识别范围。") }
                    let pendingRanges = project.unrecognizedRanges(in: range)
                    if pendingRanges.isEmpty { break }
                    let engines: ClipServices
                    if let services { engines = services }
                    else if let model { engines = try await model.makeClipServices(configured: job.configuredServices, source: job.sourceLanguage, target: job.targetLanguage) }
                    else { throw ClipError.message("识别与翻译引擎尚未准备。") }
                    for pendingRange in pendingRanges {
                    try await ClipSpeechPipeline.transcribe(media: project.media, range: pendingRange, services: engines, existing: self.projects.first { $0.id == project.id }?.captions ?? project.captions,
                        progress: { value, message in await self.progress(jobID, value: value, message: message) },
                        onCue: { cue in await self.mergeCaption(project.id, cue: cue) },
                        onEnergy: { energy in await self.update(project.id) { p in
                            let positions = Set(energy.map { Int(($0.start * 1000).rounded()) })
                            p.energy.removeAll { positions.contains(Int(($0.start * 1000).rounded())) }; p.energy.append(contentsOf: energy); p.energy.sort { $0.start < $1.start }
                        } })
                    self.update(project.id) { $0.analysisCoverage.append(pendingRange.start...pendingRange.end) }
                    }
                case .proofread:
                    guard let range = job.range else { throw ClipError.message("请选择要核对的选段。") }
                    let translator: any TextTranslating
                    if let services { translator = services.translator }
                    else if let model { translator = try await model.makeProofreadTranslator(configured: job.configuredServices) }
                    else { throw ClipError.message("核对模型尚未准备。") }
                    let cues = project.captions(for: range).filter { !$0.original.isEmpty && !$0.isDraft }.sorted { $0.start < $1.start }
                    guard !cues.isEmpty else { throw ClipError.message("请先添加原文字幕，再使用模型核对。") }
                    var proposals: [Caption] = []
                    for (index, original) in cues.enumerated() {
                        try Task.checkCancellation()
                        var cue = original; cue.start = max(range.start, cue.start); cue.end = min(range.end, cue.end)
                        let context = SubtitleTranslationContext(
                            previous: cues[..<index].suffix(2).map { .init(original: $0.original, translated: SubtitleDocument.completedTranslation($0) ?? "") },
                            following: cues.dropFirst(index + 1).prefix(1).map(\.original))
                        cue.translated = try await translator.translate(cue.original, from: cue.sourceLanguage.name, to: cue.targetLanguage.name, context: context)
                        try Task.checkCancellation()
                        if SubtitleDocument.completedTranslation(cue) != nil && cue.translated != original.translated { proposals.append(cue) }
                        // Persist completed suggestions so a network interruption does not discard review work.
                        self.update(project.id) { p in if let i = p.ranges.firstIndex(where: { $0.id == range.id }) { p.ranges[i].proofreadCandidates = proposals } }
                        self.progress(jobID, value: Double(index + 1) / Double(cues.count), message: "正在结合上下文核对字幕 \(index + 1)/\(cues.count)")
                    }
                case .export:
                    try await self.export(job, project: project)

                }
                self.updateJob(jobID) {
                    $0.state = .completed; $0.progress = 1
                    switch job.kind {
                    case .recommend: $0.message = "候选已准备，勾选后加入选段，再预览与导出。"
                    case .preview: $0.message = "预览已准备，可检查画面并设置起止点。"
                    case .transcribe: $0.message = "字幕处理已完成，可编辑后导出；未检测到的语音可手动补充。"
                    case .export: $0.message = job.exportKind == .mp3 ? "MP3 已分别保存，原视频保留。" : "MP4 已保存，所有可生成的字幕文件已核验。原视频保留。"
                    case .proofread: $0.message = "模型核对完成，请比较建议后应用；原字幕尚未改动。"
                    }
                }
            } catch {
                self.updateJob(jobID) {
                    $0.state = Task.isCancelled ? (self.pauseRequested ? .paused : .cancelled) : .failed
                    $0.message = Task.isCancelled ? (self.pauseRequested ? "已暂停，继续时复用完成的字幕与成片。" : "已取消，完成的字幕与成片保留。") : ClipFailure.message(error, operation: "当前任务")
                }
            }
        }
    }
    private func recordReceipt(_ receipt: ClipExportReceipt, jobID: UUID) {
        updateJob(jobID) { job in
            var receipts = job.exportReceipts ?? []
            receipts.removeAll { $0.rangeID == receipt.rangeID }; receipts.append(receipt)
            job.exportReceipts = receipts
        }
    }
    private func export(_ job: ClipJob, project: ClipProject) async throws {
        guard let folderPath = job.outputFolder else { throw ClipError.message("请选择导出文件夹。") }
        let folder = URL(fileURLWithPath: folderPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard !job.ranges.isEmpty else { throw ClipError.message("请勾选至少一个切片。") }
        // Preflight every segment before creating any output.
        for range in job.ranges {
            try range.validate(duration: project.media.duration)
            if job.exportKind != .mp3 && job.burnSubtitles {
                guard project.hasBurnableCaptions(for: range) else {
                    throw ClipError.message("“" + range.title + "”的" + range.style.mode.rawValue + "字幕未补全，请先识别、导入或编辑；也可关闭内嵌字幕再导出。［CLIP-SUBTITLES］")
                }
            }
        }
        updateJob(job.id) { $0.completedRanges = [] }
        for (index, range) in job.ranges.enumerated() {
            try Task.checkCancellation()
            let cues = ClipTime.captions(project.styledCaptions(for: range), within: range)
            let fingerprint = try ClipExportReceipt.fingerprint(media: project.media, range: range, cues: cues, job: job, roles: project.captionRoles ?? [])
            var receipt = job.exportReceipts?.first { $0.rangeID == range.id && $0.fingerprint == fingerprint && $0.mediaExists }
            let isMP3 = job.exportKind == .mp3
            var stage = isMP3 ? "导出 MP3" : "裁切视频"
            do {
                if receipt == nil {
                    let name = LiveRecordingEngine.safeName(range.title)
                    let target = folder.appendingPathComponent(name.isEmpty ? "切片" : name).appendingPathExtension(String(UUID().uuidString.prefix(8)))
                    let ext = isMP3 ? "mp3" : "mp4"
                    let partial = folder.appendingPathComponent(".simusub-" + UUID().uuidString + "." + ext)
                    let intermediate = folder.appendingPathComponent(".simusub-cut-" + UUID().uuidString + ".mp4")
                    updateJob(job.id) { $0.temporaryPaths = [partial.path, intermediate.path] }
                    defer { try? FileManager.default.removeItem(at: partial); try? FileManager.default.removeItem(at: intermediate) }
                    progress(job.id, value: Double(index) / Double(job.ranges.count), message: "正在导出 \(index + 1)/\(job.ranges.count)：" + range.title)
                    if isMP3 {
                        try await ClipMP3.export(media: project.media, range: range, output: partial)
                    } else {
                        try await ClipMediaEngine.cut(media: project.media, range: range, output: job.burnSubtitles ? intermediate : partial)
                        if job.burnSubtitles {
                            stage = "烧录字幕"
                            try await ClipMediaEngine.burn(input: intermediate, output: partial, captions: cues, style: range.style, roles: project.captionRoles ?? [], progress: { value in
                                await self.progress(job.id, value: (Double(index) + 0.35 + value * 0.65) / Double(job.ranges.count), message: "正在烧录字幕：" + range.title)
                            })
                        }
                        stage = "校验成片"
                        let result = try await ClipMediaEngine.inspect(partial)
                        guard abs(result.duration - range.duration) < 0.75 else { throw ClipError.message("导出时长校验未通过，原视频保留，请重试。［CLIP-DURATION］") }
                    }
                    try Task.checkCancellation()
                    stage = "保存成片"
                    let final = target.appendingPathExtension(ext)
                    try FileManager.default.moveItem(at: partial, to: final)
                    update(project.id) { $0.exports.insert(final.path, at: 0) }
                    receipt = ClipExportReceipt(rangeID: range.id, fingerprint: fingerprint, mediaPath: final.path, mediaBytes: LiveRecordingEngine.fileSize(final.path))
                    recordReceipt(receipt!, jobID: job.id)
                }
                guard var saved = receipt else { throw ClipError.message("成片记录缺失，请重新导出。") }
                if !isMP3 {
                    let target = URL(fileURLWithPath: saved.mediaPath).deletingPathExtension()
                    for format in [SubtitleExportFormat.srt, .vtt] {
                        try Task.checkCancellation()
                        let text = ClipSubtitleImport.render(cues, format: format, style: range.style)
                        guard !text.isEmpty else { continue }
                        stage = "保存 " + format.rawValue.uppercased() + " 字幕"
                        let url = target.appendingPathExtension(format.rawValue)
                        if (try? String(contentsOf: url, encoding: .utf8)) != text { try writeSubtitle(text, url) }
                        guard (try? String(contentsOf: url, encoding: .utf8)) == text else {
                            throw ClipError.message("字幕文件写入后校验失败，请重试。［CLIP-SIDECAR］")
                        }
                        if !saved.completedSidecars.contains(format.rawValue) { saved.completedSidecars.append(format.rawValue) }
                        recordReceipt(saved, jobID: job.id)
                    }
                }
                updateJob(job.id) { $0.completedRanges?.append(range.id); $0.temporaryPaths = [] }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let prefix = receipt != nil && !isMP3 ? "“" + range.title + "”的视频已保存，字幕文件尚未全部完成。点击重试会补写缺失文件。" : "“" + range.title + "”："
                throw ClipError.message(prefix + ClipFailure.message(error, operation: stage))
            }
        }
    }
    func cancel() { pauseRequested = false; task?.cancel() }
    func pause() {
        pauseRequested = true
        if let id = currentJob?.id { updateJob(id) { $0.message = "正在暂停，等待当前识别或编码结束…" } }
        task?.cancel()
    }
    func shutdown() async { task?.cancel(); await task?.value }
    func progress(_ id: UUID, value: Double, message: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].progress = min(1, max(0, value)); jobs[i].message = message
        if Date().timeIntervalSince(lastProgressSave) >= 2 { lastProgressSave = Date(); persist() }
    }
    func addCandidates(_ id: UUID) {
        update(id) { p in
            let selected = (p.candidates ?? []).filter(\.selected)
            let ids = Set(p.ranges.map(\.id))
            let existing = p.ranges
            let additions = selected.filter { item in
                !ids.contains(item.id) && !existing.contains { abs($0.start - item.start) < 0.05 && abs($0.end - item.end) < 0.05 }
            }
            p.ranges.append(contentsOf: additions)
            let added = Set(selected.map(\.id))
            p.candidates?.removeAll { added.contains($0.id) }
        }
    }
    private func updateJob(_ id: UUID, _ change: (inout ClipJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[i]); persist() }
    }
    func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { notice = "文件已被移动或删除，项目草稿仍保留。"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    private func removePreview(_ path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if url.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("Previews").standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
    private func persist() {
        do { try storage.save(projects, name: "projects"); try storage.save(Array(jobs.prefix(100)), name: "jobs") }
        catch { notice = error.localizedDescription }
    }
}
