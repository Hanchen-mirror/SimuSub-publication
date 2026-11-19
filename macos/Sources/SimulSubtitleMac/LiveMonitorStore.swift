import AppKit
import Combine
import UserNotifications

@MainActor
final class LiveMonitorStore: ObservableObject {
    @Published private(set) var creators: [WatchedCreator]
    @Published private(set) var recordings: [LiveRecording]
    @Published private(set) var settings: LiveMonitorSettings
    @Published private(set) var isMonitoring = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSearching = false
    @Published private(set) var results: [CreatorCandidate] = []
    @Published var searchError: String?
    @Published var notice: String?
    @Published private(set) var notificationStatus = "未开启系统提醒"
    let credentials: LiveCredentials
    let storage: LiveMonitorStorage
    private let service: LivePlatformServing
    private let notificationsEnabled: Bool
    private var polling: Task<Void, Never>?
    private var refreshAfterCurrent = false
    private var refreshTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var searchRequest: Task<[CreatorCandidate], Error>?
    private var jobs: [UUID: any LiveRecordingControl] = [:]
    @Published private(set) var convertingIDs: Set<UUID> = []
    private var conversionTasks: [UUID: Task<Void, Never>] = [:]
    private var pausingIDs: Set<UUID> = []
    private var recordingTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownRequested = false
    private var profileTasks: [UUID: Task<Void, Never>] = [:]
    private var nextProfileCheck: [UUID: Date] = [:]
    private var credentialSubscription: AnyCancellable?
    var onLiveEvent: ((WatchedCreator) -> Void)?

    init(storage: LiveMonitorStorage = LiveMonitorStorage(), service: LivePlatformServing = LivePlatformService(),
         credentials: LiveCredentials? = nil, notificationsEnabled: Bool = true) {
        self.storage = storage; self.service = service; self.credentials = credentials ?? LiveCredentials()
        self.notificationsEnabled = notificationsEnabled
        let (creators, a) = storage.load([WatchedCreator].self, name: "creators", fallback: [])
        let (recordings, b) = storage.load([LiveRecording].self, name: "recordings", fallback: [])
        let (settings, c) = storage.load(LiveMonitorSettings.self, name: "settings", fallback: .init())
        self.creators = creators
        self.recordings = recordings.map { value in
            var value = value
            if value.state.isActive && value.state != .paused {
                value.state = .interrupted; value.endedAt = Date()
                value.bytes = value.savedBytes
                value.message = value.bytes > 0 ? "上次录制随应用异常结束，已有文件保留。" : "上次应用结束时尚未保存录像，未生成可用文件。"
            }
            return value
        }
        self.settings = settings
        self.settings.intervalSeconds = min(900, max(15, settings.intervalSeconds))
        if settings.pollingRevision == nil {
            if settings.intervalSeconds == 180 { self.settings.intervalSeconds = 15 }
            self.settings.pollingRevision = 1
            _ = try? storage.save(self.settings, name: "settings")
        }
        self.settings.maximumRecordings = min(3, max(1, settings.maximumRecordings))
        notice = [a, b, c].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
        credentialSubscription = self.credentials.$revision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshNow() }
        }
    }

    var activeRecordings: [LiveRecording] { recordings.filter { $0.state.isActive } }
    var hasActiveRecordings: Bool { !recordingTasks.isEmpty }
    func activeRecording(_ creatorID: UUID) -> LiveRecording? { activeRecordings.first { $0.creatorID == creatorID } }
    func follows(_ candidate: CreatorCandidate) -> Bool { creators.contains { $0.identity == candidate.id } }
    func clearSearch() { searchRequest?.cancel(); searchRequest = nil; searchGeneration = UUID(); results = []; searchError = nil; isSearching = false }

    func search(_ query: String, platform: LivePlatform) async {
        searchRequest?.cancel()
        let generation = UUID(); searchGeneration = generation; isSearching = true; results = []; searchError = nil
        defer { if searchGeneration == generation { isSearching = false; searchRequest = nil } }
        do {
            await credentials.refreshBrowserSession(platform)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            let access = try credentials.context(platform)
            let service = self.service
            let request = Task { try await service.search(query, platform: platform, access: access) }
            searchRequest = request
            let found = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
            if found.isEmpty { searchError = "没有找到主播，可尝试粘贴频道或直播间链接。" }
        } catch {
            if generation == searchGeneration, !Task.isCancelled { searchError = Self.message(error) }
        }
    }

    @discardableResult func follow(_ candidate: CreatorCandidate) -> Bool {
        guard !follows(candidate), !shutdownRequested else { return false }
        guard creators.count < 50 else { notice = "本版最多关注 50 位主播，避免过于频繁地请求平台。"; return false }
        creators.append(WatchedCreator(candidate)); persistCreators()
        return true
    }
    @discardableResult func addAndMonitor(_ candidate: CreatorCandidate) -> Bool {
        guard follow(candidate), let id = creators.first(where: { $0.identity == candidate.id })?.id else { return false }
        refreshProfile(id)
        if isMonitoring { refreshNow() } else { startMonitoring() }
        return true
    }
    func moveCreator(_ id: UUID, to target: UUID) {
        guard id != target, let from = creators.firstIndex(where: { $0.id == id }),
              let to = creators.firstIndex(where: { $0.id == target }) else { return }
        let creator = creators.remove(at: from)
        creators.insert(creator, at: to); persistCreators()
    }
    func shiftCreator(_ id: UUID, by offset: Int) {
        guard let from = creators.firstIndex(where: { $0.id == id }) else { return }
        let to = min(creators.count - 1, max(0, from + offset))
        if from != to { moveCreator(id, to: creators[to].id) }
    }
    func refreshMissingProfiles() {
        for creator in creators { refreshProfile(creator.id) }
    }
    func refreshProfile(_ id: UUID) {
        guard !shutdownRequested, profileTasks[id] == nil, (nextProfileCheck[id] ?? .distantPast) < Date(),
              let creator = creators.first(where: { $0.id == id }) else { return }
        nextProfileCheck[id] = Date().addingTimeInterval(300)
        profileTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.profileTasks[id] = nil }
            do {
                let access = try self.credentials.context(creator.platform)
                let profile = try await self.service.resolve(creator.address, platform: creator.platform, access: access)
                guard !Task.isCancelled, !self.shutdownRequested, let i = self.creators.firstIndex(where: { $0.id == id }) else { return }
                if !profile.name.isEmpty { self.creators[i].name = profile.name }
                if let avatar = profile.avatarURL, URL(string: avatar)?.scheme == "https" { self.creators[i].avatarURL = avatar }
                self.nextProfileCheck[id] = Date().addingTimeInterval(86_400)
                self.persistCreators()
            } catch { /* Avatar failure does not overwrite live status or stop recording. */ }
        }
    }
    func removeCreator(_ id: UUID) async {
        profileTasks[id]?.cancel(); nextProfileCheck[id] = nil
        if let recording = activeRecording(id) { stopRecording(recording.id, reason: .creatorRemoved); await recordingTasks[recording.id]?.value }
        creators.removeAll { $0.id == id }; persistCreators()
    }
    func updateCreator(_ id: UUID, monitoring: Bool? = nil, notify: Bool? = nil, autoRecord: Bool? = nil) {
        guard let i = creators.firstIndex(where: { $0.id == id }) else { return }
        if let monitoring { creators[i].monitoring = monitoring; creators[i].nextCheckAt = nil }
        if let notify { creators[i].notify = notify }
        if let autoRecord { creators[i].autoRecord = autoRecord; creators[i].recordingRetryAt = nil }
        persistCreators()
        if autoRecord == true, isMonitoring { refreshNow() }
    }
    func updateSettings(_ update: (inout LiveMonitorSettings) -> Void) {
        var value = settings; update(&value)
        value.intervalSeconds = min(900, max(15, value.intervalSeconds))
        value.maximumRecordings = min(3, max(1, value.maximumRecordings))
        let changedInterval = settings.intervalSeconds != value.intervalSeconds
        settings = value; save(value, name: "settings")
        if changedInterval {
            for i in creators.indices { creators[i].nextCheckAt = nil }
            if isMonitoring { refreshNow() }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true; panel.prompt = "保存录制到这里"
        if panel.runModal() == .OK, let url = panel.url { updateSettings { $0.outputFolder = url.path } }
    }
    func showFolder() {
        let url = URL(fileURLWithPath: settings.outputFolder, isDirectory: true)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
        catch { notice = "无法打开保存目录，请更换文件夹。" }
    }
    func revealRecording(_ recording: LiveRecording) {
        guard FileManager.default.fileExists(atPath: recording.path) else { notice = "这个录制文件已被移动或删除。"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: recording.path)])
    }

    func startMonitoring() {
        guard !isMonitoring, !shutdownRequested else { return }
        guard !creators.isEmpty else { notice = "先搜索并关注一位主播。"; return }
        isMonitoring = true
        for i in creators.indices { creators[i].nextCheckAt = nil }
        polling = Task { [weak self] in
            while let self, self.isMonitoring, !Task.isCancelled {
                await self.refresh(force: false)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
    func pauseMonitoring() {
        isMonitoring = false; polling?.cancel(); polling = nil
        if hasActiveRecordings { notice = "已暂停开播检查；正在进行的录制继续，可单独停止。" }
    }
    func refreshNow() {
        guard !shutdownRequested else { return }
        if isRefreshing { refreshAfterCurrent = true; return }
        refreshTask = Task { [weak self] in await self?.refresh(force: true) }
    }
    func refresh(force: Bool) async {
        guard !isRefreshing, !shutdownRequested else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshAfterCurrent { refreshAfterCurrent = false; refreshNow() }
        }
        let ids = creators.filter { $0.monitoring && (force || ($0.nextCheckAt ?? .distantPast) <= Date()) }.map(\.id)
        // Bound concurrent checks; one slow platform must not block the other cards.
        await withTaskGroup(of: Void.self) { group in
            var iterator = ids.makeIterator()
            for _ in 0..<3 {
                if let id = iterator.next() { group.addTask { await self.refreshCreator(id) } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, !shutdownRequested else { group.cancelAll(); break }
                if let id = iterator.next() { group.addTask { await self.refreshCreator(id) } }
            }
        }
    }
    private func refreshCreator(_ id: UUID) async {
        guard !Task.isCancelled, !shutdownRequested,
              let creator = creators.first(where: { $0.id == id }) else { return }
            do {
                let access = try credentials.context(creator.platform)
                let snapshot = try await service.status(creator, access: access)
                guard !Task.isCancelled, !shutdownRequested else { return }
                if snapshot.state == .offline { await service.invalidateRecordingInput(creator) }
                let event = applySnapshot(snapshot, to: id)
                if event, let current = creators.first(where: { $0.id == id }), current.notify {
                    onLiveEvent?(current)
                    await deliverNotification(current)
                }
                if let current = creators.first(where: { $0.id == id }) {
                    if current.stableState == .offline, let recording = activeRecording(id) { stopRecording(recording.id, suppress: false, reason: .broadcasterOffline) }
                    if isMonitoring, current.autoRecord, current.snapshot.state == .live,
                       current.acceptedSessionID != current.suppressedRecordingSession,
                       (current.recordingRetryAt ?? .distantPast) < Date(), activeRecording(id) == nil,
                       activeRecordings.count < settings.maximumRecordings {
                        startRecording(id, automatic: true)
                    }
                }
            } catch {
                guard !Task.isCancelled, let i = creators.firstIndex(where: { $0.id == id }) else { return }
                creators[i].failureCount += 1
                creators[i].lastError = Self.message(error)
                let backoff = min(120.0, Double(min(30, settings.intervalSeconds)) * pow(2, Double(min(3, creators[i].failureCount))))
                creators[i].nextCheckAt = Date().addingTimeInterval(backoff)
                persistCreators()
            }
    }

    /// Unknown/error responses never end a broadcast. Two explicit offline
    /// observations are required; one accepted session emits at most one event.
    @discardableResult func applySnapshot(_ snapshot: LiveSnapshot, to id: UUID) -> Bool {
        guard let i = creators.firstIndex(where: { $0.id == id }) else { return false }
        var creator = creators[i]
        let previous = creator.snapshot
        creator.failureCount = 0; creator.lastError = nil
        creator.nextCheckAt = Date().addingTimeInterval(Double(settings.intervalSeconds))
        if snapshot.state == .unknown { creators[i] = creator; persistCreators(); return false }
        var event = false
        if snapshot.state == .live {
            let changedID = snapshot.sessionID != nil && previous.sessionID != nil && snapshot.sessionID != previous.sessionID
            if creator.stableState != .live || creator.acceptedSessionID == nil || changedID {
                creator.acceptedSessionID = (snapshot.sessionID ?? creator.address) + ":" + UUID().uuidString
                creator.recordingRetryAt = nil
            }
            creator.stableState = .live; creator.offlineConfirmations = 0
            if creator.lastNotifiedSession != creator.acceptedSessionID {
                creator.lastNotifiedSession = creator.acceptedSessionID; event = true
            }
        } else if snapshot.state == .offline {
            creator.offlineConfirmations += 1
            if creator.stableState == .live && creator.offlineConfirmations == 1 {
                creator.nextCheckAt = Date().addingTimeInterval(5)
            }
            if creator.offlineConfirmations >= 2 || creator.stableState != .live { creator.stableState = .offline }
        } else { creator.offlineConfirmations = 0; creator.stableState = .upcoming }
        creator.snapshot = snapshot
        creators[i] = creator; persistCreators()
        return event
    }

    func startRecording(_ creatorID: UUID, automatic: Bool = false) {
        guard !shutdownRequested, let creator = creators.first(where: { $0.id == creatorID }), activeRecording(creatorID) == nil else { return }
        guard activeRecordings.count < settings.maximumRecordings else { notice = "已达到同时录制上限，可在录制设置调整。"; return }
        do {
            let output = try LiveRecordingEngine.outputURL(creator: creator, settings: settings)
            let folder = output.deletingPathExtension().appendingPathExtension("segments")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let recording = LiveRecording(creatorID: creator.id, platform: creator.platform, creatorName: creator.name,
                                          title: creator.snapshot.title, broadcastStartedAt: creator.snapshot.startedAt, path: folder.appendingPathComponent("attempt01-000000." + output.pathExtension).path,
                                          message: "正在连接直播，尚未开始写入录像。", segmentFolder: folder.path)
            recordings.insert(recording, at: 0); persistRecordings()
            recordingTasks[recording.id] = Task { [weak self] in
                guard let self else { return }
                await self.runRecording(recording, creator: creator, output: output)
            }
        } catch {
            notice = Self.message(error)
            if automatic { setRecordingCooldown(creatorID) }
        }
    }
    private func runRecording(_ recording: LiveRecording, creator: WatchedCreator, output: URL) async {
        let id = recording.id
        let deadline = Date().addingTimeInterval(12 * 3_600)
        let quality = settings.quality
        let folder = URL(fileURLWithPath: recording.segmentFolder!)
        let attemptBase = (recording.mediaURLs.compactMap { url -> Int? in
            let name = url.lastPathComponent
            guard name.hasPrefix("attempt") else { return nil }
            return Int(name.dropFirst(7).prefix { $0.isNumber })
        }.max() ?? 0)
        let sizeTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                guard let self else { break }
                self.updateRecording(id) { $0.bytes = $0.savedBytes }
                do { try LiveRecordingEngine.checkSpace(folder, minimum: 250_000_000) }
                catch { self.notice = "磁盘空间不足，正在停止并保存录制。"; self.stopRecording(id, reason: .lowDisk) }
            }
        }
        defer { sizeTask.cancel(); jobs[id] = nil; recordingTasks[id] = nil; persistRecordings() }
        var finalError: Error?
        var cleanEnd = false
        var twitchHadAdvertisement = false
        var attempts = 0
        for attempt in 1...4 {
            do {
                try Task.checkCancellation()
                guard !shutdownRequested, recordings.first(where: { $0.id == id })?.state != .stopping else { break }
                if attempt > 1 {
                    let access = try credentials.context(creator.platform)
                    let snapshot = try await service.status(creator, access: access)
                    applySnapshot(snapshot, to: creator.id)
                    if snapshot.state == .offline { throw LiveExtractionError.offline }
                    if snapshot.state == .upcoming { throw LiveExtractionError.upcoming }
                    updateRecording(id) { $0.state = .preparing; $0.message = (finalError.map { Self.message($0) } ?? "连接中断。") + " 正在重连（\(attempt - 1)/3）。" }
                    try await Task.sleep(nanoseconds: UInt64([0, 2, 5, 15][attempt - 1]) * 1_000_000_000)
                }
                var access = try credentials.context(creator.platform)
                access.recordingQuality = quality
                attempts = attempt
                let current = creators.first(where: { $0.id == creator.id }) ?? creator
                let input = try await service.recordingInput(current, access: access)
                try Task.checkCancellation()
                guard !shutdownRequested, recordings.first(where: { $0.id == id })?.state != .stopping else { break }
                let pattern = folder.appendingPathComponent(String(format: "attempt%02d-%%06d.", attemptBase + attempt) + output.pathExtension)
                let progressURL = folder.appendingPathComponent(String(format: "attempt%02d.progress", attemptBase + attempt))
                let result: LiveToolOutput
                if let capture = input.browserCapture {
                    let job = BrowserCaptureJob(); jobs[id] = job
                    defer { if jobs[id] === job { jobs[id] = nil } }
                    updateRecording(id) { $0.title = input.title; $0.state = .preparing; $0.message = "已连接浏览器，正在等待直播画面。" }
                    result = try await withTaskCancellationHandler {
                        try await job.run(capture, folder: folder, prefix: String(format: "attempt%02d-", attemptBase + attempt),
                                          container: output.pathExtension, maximumSeconds: max(0, deadline.timeIntervalSinceNow)) { [weak self] file in
                            guard let self, self.jobs[id] === job else { return }
                            self.updateRecording(id) {
                                $0.path = file.path
                                if $0.state == .preparing { $0.state = .recording; $0.message = "正在保存浏览器直播画面与声音。" }
                                $0.bytes = $0.savedBytes
                            }
                        }
                    } onCancel: { job.cancel() }
                } else if input.twitchHLS {
                    let job = TwitchRecordingJob(); jobs[id] = job
                    defer { if jobs[id] === job { jobs[id] = nil } }
                    updateRecording(id) { $0.title = input.title; $0.state = .preparing; $0.message = "正在检查 Twitch 直播内容。" }
                    result = try await withTaskCancellationHandler {
                        try await job.run(input, output: pattern, maximumSeconds: max(0, deadline.timeIntervalSinceNow)) { [weak self] state in
                            guard let self, self.jobs[id] === job,
                                  self.recordings.first(where: { $0.id == id })?.state != .stopping else { return }
                            if state == .advertisement { twitchHadAdvertisement = true }
                            self.updateRecording(id) {
                                $0.state = state == .recording ? .recording : .preparing
                                $0.message = state.message; $0.bytes = $0.savedBytes
                            }
                        }
                    } onCancel: { job.cancel() }
                } else {
                let arguments = try LiveRecordingEngine.arguments(input: input, output: pattern, segmentSeconds: 300, progressURL: progressURL)
                let job = LiveToolProcess(); jobs[id] = job
                defer { if jobs[id] === job { jobs[id] = nil } }
                let progress = LiveRecordingProgress()
                let firstFrameDeadline = Date().addingTimeInterval(20)
                updateRecording(id) { $0.title = input.title; $0.state = .preparing; $0.message = "直播地址已解析，正在连接并等待画面。" }
                let progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        if progress.poll(progressURL) {
                            guard let self, self.jobs[id] === job,
                                  self.recordings.first(where: { $0.id == id })?.state == .preparing else { return }
                            self.updateRecording(id) { $0.state = .recording; $0.bytes = $0.savedBytes; $0.message = "已收到直播画面，正在写入录像。" }
                            return
                        }
                        if Date() >= firstFrameDeadline { job.cancel(); return }
                        do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    }
                }
                defer { progressTask.cancel(); try? FileManager.default.removeItem(at: progressURL) }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw LiveMonitorError.unavailable("本场已达到 12 小时，请重新开始录制。") }
                do {
                    result = try await withTaskCancellationHandler {
                        try await job.run("ffmpeg", arguments: arguments, timeout: remaining)
                    } onCancel: { job.cancel() }
                } catch {
                    if !Task.isCancelled, !progress.hasVideo, Date() >= firstFrameDeadline {
                        throw LiveMonitorError.unavailable("20 秒内未收到直播画面，正在切换线路。")
                    }
                    throw error
                }
                }
                if result.status == 0 {
                    if recordings.first(where: { $0.id == id })?.state != .stopping, !shutdownRequested,
                       creator.stableState == .live {
                        updateRecording(id) { $0.state = .preparing; $0.message = "正在确认直播是否结束…" }
                        let snapshot = try await service.status(creator, access: access)
                        try Task.checkCancellation()
                        if recordings.first(where: { $0.id == id })?.state == .stopping { cleanEnd = true; break }
                        if snapshot.state != .offline { throw LiveMonitorError.unavailable("直播仍在进行，正在重新连接直播流。") }
                    }
                    cleanEnd = true; break
                }
                throw LiveMonitorError.unavailable(LiveRecordingEngine.failureMessage(result.error))
            } catch let ended as LiveExtractionError {
                await service.invalidateRecordingInput(creator)
                let state: LiveState = ended == .offline ? .offline : .upcoming
                applySnapshot(.init(state: state), to: creator.id)
                if ended == .offline { applySnapshot(.init(state: .offline), to: creator.id) }
                updateRecording(id) { $0.state = .stopping; $0.stopReason = .broadcasterOffline }
                finalError = ended
                break
            } catch {
                await service.invalidateRecordingInput(creator)
                finalError = error
                if Task.isCancelled || shutdownRequested || recordings.first(where: { $0.id == id })?.state == .stopping || Date() >= deadline { break }
            }
        }
        let stopped = recordings.first(where: { $0.id == id })?.state == .stopping
        updateRecording(id) {
            $0.bytes = $0.savedBytes; $0.endedAt = Date()
            if pausingIDs.contains(id) && !shutdownRequested {
                $0.state = .paused; $0.pausedAt = Date(); $0.endedAt = nil; $0.message = "录制已暂停，已收到的片段保存；继续时写入新片段。"
            } else if stopped {
                $0.state = $0.bytes > 0 ? .completed : .cancelled
                let reason = $0.stopReason?.explanation ?? "录制已停止"
                $0.message = reason + ($0.bytes > 0 ? "；已保存的录像保留。" : "；尚未收到可保存的内容，未生成录像。")
            } else if cleanEnd {
                $0.state = $0.bytes > 0 ? .completed : .failed
                $0.message = $0.bytes > 0 ? "直播流已结束，录像已保存。" : "直播流结束前未收到可保存的内容，未生成录像。"
            } else {
                $0.state = $0.bytes > 0 ? .interrupted : (Task.isCancelled ? .cancelled : .failed)
                let cause = finalError.map { Self.message($0) } ?? "录制任务意外结束。"
                $0.message = cause + (attempts > 1 ? " 已重试 \(attempts - 1) 次，仍未恢复。" : "")
                    + ($0.bytes > 0 ? " 已有录像保留。" : " 未生成录像。")
            }
        }
        if twitchHadAdvertisement {
            updateRecording(id) { $0.message = ($0.message ?? "") + " Twitch 广告期间未取得主播内容，缺口见录像目录的 twitch.jsonl 记录。" }
        }
        pausingIDs.remove(id)
        if recordings.first(where: { $0.id == id })?.state == .paused { return }
        if let finished = recordings.first(where: { $0.id == id }), finished.state == .failed || finished.state == .interrupted {
            notice = finished.message
        }
        if !cleanEnd && !stopped { setRecordingCooldown(creator.id) }
        else if let i = creators.firstIndex(where: { $0.id == creator.id }) {
            creators[i].recordingRetryAt = Date().addingTimeInterval(Double(settings.intervalSeconds)); persistCreators()
        }
    }
    func stopRecording(_ id: UUID, suppress: Bool = true, reason: LiveRecordingStopReason = .user) {
        guard let recording = recordings.first(where: { $0.id == id }), recording.state.isActive, recording.state != .stopping else { return }
        if recording.state == .paused {
            pausingIDs.remove(id)
            updateRecording(id) { $0.state = $0.savedBytes > 0 ? .completed : .cancelled; $0.endedAt = $0.pausedAt ?? Date(); $0.pausedAt = nil; $0.message = "已停止，录制片段保留。" }
            if suppress, let i = creators.firstIndex(where: { $0.id == recording.creatorID }) { creators[i].suppressedRecordingSession = creators[i].acceptedSessionID; persistCreators() }
            return
        }
        if suppress, let i = creators.firstIndex(where: { $0.id == recording.creatorID }) {
            creators[i].suppressedRecordingSession = creators[i].acceptedSessionID; persistCreators()
        }
        updateRecording(id) { $0.state = .stopping; $0.stopReason = reason; $0.message = reason.explanation + "，正在结束任务。" }
        // A process may already be opening the stream while the UI still says
        // connecting. Flush it normally; only cancel metadata/backoff tasks.
        if let job = jobs[id] { job.requestStop() }
        else { recordingTasks[id]?.cancel() }
    }
    func pauseRecording(_ id: UUID) {
        guard recordings.first(where: { $0.id == id })?.state == .recording else { return }
        pausingIDs.insert(id); stopRecording(id)
    }
    func resumeRecording(_ id: UUID) {
        guard !shutdownRequested, let recording = recordings.first(where: { $0.id == id }), recording.state == .paused,
              recordingTasks[id] == nil, let creator = creators.first(where: { $0.id == recording.creatorID }), let folder = recording.segmentFolder else { return }
        let paused = recording.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        updateRecording(id) { $0.pausedSeconds = ($0.pausedSeconds ?? 0) + paused; $0.pausedAt = nil; $0.state = .preparing; $0.message = "正在继续录制…" }
        let output = URL(fileURLWithPath: folder).deletingPathExtension().appendingPathExtension(URL(fileURLWithPath: recording.path).pathExtension)
        recordingTasks[id] = Task { [weak self] in guard let self else { return }; await self.runRecording(self.recordings.first { $0.id == id } ?? recording, creator: creator, output: output) }
    }
    func discardRecording(_ id: UUID) async {
        guard let recording = recordings.first(where: { $0.id == id }) else { return }
        pausingIDs.remove(id); stopRecording(id); await recordingTasks[id]?.value
        do {
            let url = URL(fileURLWithPath: recording.segmentFolder ?? recording.path)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            recordings.removeAll { $0.id == id }; persistRecordings()
        } catch { notice = "未能移到废纸篓：" + Self.message(error) }
    }
    func convertRecording(_ id: UUID) {
        guard !convertingIDs.contains(id) else { return }
        convertingIDs.insert(id)
        conversionTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.convertingIDs.remove(id); self.conversionTasks[id] = nil }
            self.pausingIDs.remove(id); self.stopRecording(id); await self.recordingTasks[id]?.value
            guard let recording = self.recordings.first(where: { $0.id == id }), !recording.closedMediaURLs.isEmpty else { self.notice = "还没有已保存的录像片段。"; return }
            do {
                let folder = URL(fileURLWithPath: recording.segmentFolder ?? URL(fileURLWithPath: recording.path).deletingLastPathComponent().path).appendingPathComponent("converted")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for source in recording.closedMediaURLs {
                    try Task.checkCancellation()
                    let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(6)) + ".mp4")
                    let partial = folder.appendingPathComponent(".simusub-" + UUID().uuidString + ".mp4")
                    defer { try? FileManager.default.removeItem(at: partial) }
                    let result = try await LiveTools.run("ffmpeg", arguments: ["-nostdin", "-v", "error", "-n", "-protocol_whitelist", "file,crypto", "-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-c:a", "aac", "-movflags", "+faststart", partial.path], timeout: 3600)
                    guard result.status == 0 else { throw ClipError.message("转换 MP4 未完成，原录像保留。可从工作台导入后转码导出。") }
                    _ = try await ClipMediaEngine.inspect(partial)
                    try FileManager.default.moveItem(at: partial, to: output)
                }
                self.notice = "MP4 转换完成，原录像保留。"
                NSWorkspace.shared.open(folder)
            } catch { self.notice = Self.message(error) }
        }
    }
    func shutdown() async {
        shutdownRequested = true
        let conversions = Array(conversionTasks.values); conversions.forEach { $0.cancel() }
        let poll = polling, refresh = refreshTask, search = searchRequest
        let profiles = Array(profileTasks.values)
        profiles.forEach { $0.cancel() }
        pauseMonitoring(); refresh?.cancel(); clearSearch()
        let tasks = Array(recordingTasks.values)
        for recording in activeRecordings { stopRecording(recording.id, suppress: false, reason: .applicationExit) }
        for task in tasks { await task.value }
        for task in conversions { await task.value }
        await poll?.value; await refresh?.value; _ = try? await search?.value
        for task in profiles { await task.value }
    }
    private func setRecordingCooldown(_ id: UUID) {
        if let i = creators.firstIndex(where: { $0.id == id }) {
            creators[i].recordingRetryAt = Date().addingTimeInterval(600); persistCreators()
        }
    }
    private func updateRecording(_ id: UUID, update: (inout LiveRecording) -> Void) {
        if let i = recordings.firstIndex(where: { $0.id == id }) { update(&recordings[i]); persistRecordings() }
    }
    private func save<T: Encodable>(_ value: T, name: String) {
        do { try storage.save(value, name: name) } catch { notice = Self.message(error) }
    }
    private func persistCreators() { save(creators, name: "creators") }
    private func persistRecordings() { save(recordings, name: "recordings") }
    static func message(_ error: Error) -> String {
        if error is CancellationError { return "操作已取消。" }
        if let error = error as? LiveMonitorError { return error.localizedDescription }
        if error is URLError { return "无法连接平台，请检查网络后稍后刷新。" }
        return "操作未完成，请检查网络、会话或保存目录后重试。"
    }
    func requestNotifications() async {
        guard notificationsEnabled else { return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
            notificationStatus = allowed ? "已开启系统提醒（静音）" : "系统提醒未允许，开播状态仍在应用内显示"
        } catch { notificationStatus = "暂时无法开启系统提醒，开播状态仍在应用内显示" }
    }
    private func deliverNotification(_ creator: WatchedCreator) async {
        guard notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(creator.name) 开播了"
        content.body = "\(creator.platform.title) · \(creator.snapshot.title)"
        content.sound = nil
        try? await center.add(UNNotificationRequest(identifier: "simusub-live-" + creator.id.uuidString, content: content, trigger: nil))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
