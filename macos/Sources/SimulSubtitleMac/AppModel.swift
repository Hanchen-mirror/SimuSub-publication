import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .live
    @Published var isSubtitleOnly = false
    @Published var subtitleDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet { defaults.set(subtitleDisplayMode.rawValue, forKey: "subtitleDisplayMode.v101") }
    }
    @Published var isSubtitlePinned = true {
        didSet { defaults.set(isSubtitlePinned, forKey: "subtitlePinned.v1") }
    }
    @Published var singleSubtitleLanguage: SingleSubtitleLanguage = .translation {
        didSet { defaults.set(singleSubtitleLanguage.rawValue, forKey: "singleSubtitleLanguage.v1") }
    }
    @Published var isCapturing = false
    @Published var isStarting = false
    @Published var isStopping = false
    @Published private(set) var isSubtitlePaused = false
    @Published var isProcessingFile = false
    @Published var status = "正在准备本地日中引擎"
    @Published var errorMessage: String?
    @Published var selectedAppName: String?
    @Published var selectedAppBundleID: String?
    @Published var availableApps: [CaptureApplication] = []
    @Published var isChoosingApplication = false
    @Published var isLoadingApplications = false
    @Published var isDownloadingModels = false
    @Published var isImportingModels = false
    @Published var downloadProgress: Double = 0
    @Published var downloadStatus = ""
    @Published var asrInstalled = false
    @Published var translationInstalled = false
    @Published var savedCredentialIDs: Set<UUID> = []
    @Published var captions: [Caption] = []
    @Published var stablePrefixesEnabled = true {
        didSet { defaults.set(stablePrefixesEnabled, forKey: "speech.stablePrefixes.v123") }
    }
    @Published var asrHotwordsEnabled = true {
        didSet { defaults.set(asrHotwordsEnabled, forKey: "speech.hotwords.v123"); cachedRecognizer = nil }
    }
    @Published private(set) var asrHotwordStatus = "术语库将在本地识别启动时校验"
    @Published var suppressBackgroundMusic = true {
        didSet { defaults.set(suppressBackgroundMusic, forKey: "speech.musicSuppression.v104") }
    }
    @Published private(set) var isClearingCaptions = false
    @Published private(set) var capturedChunkCount = 0
    @Published private(set) var capturedSampleCount = 0
    @Published private(set) var capturedPeak: Float = 0
    @Published private(set) var firstOriginalLatency: TimeInterval?
    @Published private(set) var firstTranslationLatency: TimeInterval?
    @Published var selectedASRProfileID: UUID? {
        didSet { defaults.set(selectedASRProfileID?.uuidString, forKey: "selectedASRProfileID.v2") }
    }
    @Published var selectedTranslationProfileID: UUID? {
        didSet { defaults.set(selectedTranslationProfileID?.uuidString, forKey: "selectedTranslationProfileID.v2") }
    }
    @Published var profiles: [ServiceProfile] = [
        ServiceProfile(name: "本地日语识别", kind: .local, purpose: .speechRecognition, model: "ReazonSpeech ja"),
        ServiceProfile(name: "本地翻译", kind: .local, purpose: .translation, model: "Index-Translate-2B"),
        ServiceProfile(name: "OpenAI 转写", kind: .openAICompatible, purpose: .speechRecognition, baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        ServiceProfile(name: "OpenAI 翻译", kind: .openAICompatible, purpose: .translation, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        .deepSeek
    ] { didSet { persistProfiles() } }

    let permissions = CapturePermissionCenter()
    @Published var errorSection: AppSection = .services

    private let defaults: UserDefaults
    private let keyStore = SecureCredentialStore()
    private let modelStore: LocalModelStore
    private var captureEngine: AudioCaptureEngine?
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var selectionRequestID = UUID()
    private var pendingStartAfterSelection = false
    private var speechRecognizer: SpeechRecognizing?
    private var textTranslator: TextTranslating?
    private var pipelineTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var translationQueue: CaptionRevisionQueue<TranslationSegment>?
    private var downloadTask: Task<Void, Never>?
    private var speechQueue: CaptionRevisionQueue<CapturedAudioSegment>?
    private var captionGeneration = UUID()
    private var captionRevisions: [UUID: Int] = [:]
    private var revisionGuards: [UUID: ASRRevisionGuard] = [:]
    private var prefixConfirmations: [UUID: StablePrefixConfirmation] = [:]
    private var prefixTranslations: [UUID: (source: String, chinese: String)] = [:]
    private var sessionFirstCaptionIndex = 0
    private var sessionProfile: ServiceProfile?
    private var sessionASRProfile: ServiceProfile?
    private var sessionBase: Double = 0
    private var sessionStart = Date()
    private static let profilesKey = "serviceProfiles.v2"

    var isBusy: Bool { isCapturing || isStarting || isStopping || isProcessingFile }
    var readinessIssues: [String] {
        [selectedASRProfileID, selectedTranslationProfileID].compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id }) else { return "请选择处理服务" }
            if profile.kind == .local {
                let installed = profile.purpose == .speechRecognition ? asrInstalled : translationInstalled
                return installed ? nil : "\(profile.name)尚未安装"
            }
            if (try? profile.validatedBaseURL()) == nil { return "\(profile.name)的服务地址无效" }
            if profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "\(profile.name)需要填写模型名称" }
            return savedCredentialIDs.contains(profile.id) ? nil : "\(profile.name)需要保存 API Key"
        }
    }

    init(defaults: UserDefaults = .standard, modelStore: LocalModelStore = LocalModelStore(),
         recognizer: SpeechRecognizing? = nil, translator: TextTranslating? = nil) {
        self.defaults = defaults
        self.modelStore = modelStore
        speechRecognizer = recognizer
        textTranslator = translator
        stablePrefixesEnabled = defaults.object(forKey: "speech.stablePrefixes.v123") as? Bool ?? true
        asrHotwordsEnabled = defaults.object(forKey: "speech.hotwords.v123") as? Bool ?? true
        suppressBackgroundMusic = defaults.object(forKey: "speech.musicSuppression.v104") as? Bool ?? true
        subtitleDisplayMode = defaults.string(forKey: "subtitleDisplayMode.v101")
            .flatMap(SubtitleDisplayMode.init(rawValue:)) ?? .bilingual
        if defaults.data(forKey: Self.profilesKey) == nil, let old = defaults.data(forKey: "serviceProfiles.v1") {
            defaults.set(old, forKey: Self.profilesKey)
        }
        if defaults === UserDefaults.standard, defaults.data(forKey: Self.profilesKey) == nil {
            // Prefer the most recent app's configuration; keep profile IDs for Keychain access.
            for domain in ["com.mirror.simusub", "com.mirror.simulsubtitle.mac", "io.github.korenkrita.simulsubtitle"] {
                guard let legacy = defaults.persistentDomain(forName: domain),
                      let data = (legacy[Self.profilesKey] ?? legacy["serviceProfiles.v1"]) as? Data,
                      let saved = try? JSONDecoder().decode([ServiceProfile].self, from: data),
                      !saved.isEmpty else { continue }
                for key in [Self.profilesKey, "selectedASRProfileID.v2", "selectedTranslationProfileID.v2",
                            "subtitlePinned.v1", "singleSubtitleLanguage.v1"] {
                    if let value = legacy[key] { defaults.set(value, forKey: key) }
                }
                break
            }
        }
        isSubtitlePinned = defaults.object(forKey: "subtitlePinned.v1") as? Bool ?? true
        singleSubtitleLanguage = defaults.string(forKey: "singleSubtitleLanguage.v1")
            .flatMap(SingleSubtitleLanguage.init(rawValue:)) ?? .translation
        if let data = defaults.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([ServiceProfile].self, from: data), !saved.isEmpty {
            profiles = saved.map { profile in
                var value = profile
                value.sourceLanguage = "日语"
                value.targetLanguage = "中文"
                if value.kind == .local && value.purpose == .speechRecognition { value.name = "本地日语识别"; value.model = "ReazonSpeech ja" }
                return value
            }
        }
        if let data = defaults.data(forKey: "vtuber.glossary.v122"), let saved = try? JSONDecoder().decode([VTuberTerm].self, from: data) { glossary = saved }
        // Migrate only the retired official IDs, retaining profile UUID and Keychain account.
        for i in profiles.indices where profiles[i].isDeepSeek && ["deepseek-chat", "deepseek-reasoner"].contains(profiles[i].model) {
            profiles[i].model = "deepseek-flash"
        }
        let savedASR = defaults.string(forKey: "selectedASRProfileID.v2").flatMap(UUID.init(uuidString:))
        let savedMT = defaults.string(forKey: "selectedTranslationProfileID.v2").flatMap(UUID.init(uuidString:))
        selectedASRProfileID = profiles.first(where: { $0.id == savedASR && $0.purpose == .speechRecognition })?.id
            ?? profiles.first(where: { $0.purpose == .speechRecognition })?.id
        selectedTranslationProfileID = profiles.first(where: { $0.id == savedMT && $0.purpose == .translation })?.id
            ?? profiles.first(where: { $0.purpose == .translation })?.id
        refreshModels()
        savedCredentialIDs = Set(profiles.filter { keyStore.contains(account: $0.id.uuidString) }.map(\.id))
        persistProfiles()
        if readinessIssues.isEmpty { status = "准备就绪 · 选择音频来源开始字幕" }
    }

    func binding(for id: UUID) -> Binding<ServiceProfile>? {
        guard let initial = profiles.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.profiles.first(where: { $0.id == id }) ?? initial }, set: { updated in
            guard let index = self.profiles.firstIndex(where: { $0.id == id }) else { return }
            self.profiles[index] = updated
        })
    }

    func report(_ error: Error, prefix: String) {
        errorSection = error is CapturePermissionError ? .permissions : .services
        if error is CapturePermissionError { section = .permissions }
        let message = "\(prefix)：\(error.localizedDescription)"
        status = message
        errorMessage = message
    }

    func startCapture() {
        guard !isBusy else { return }
        if !readinessIssues.isEmpty {
            errorSection = .services
            errorMessage = readinessIssues.joined(separator: "\n") + "\n本地引擎自动准备完成后即可使用；第三方接口请到高级设置完善。"
            section = .services
            return
        }
        guard let selectedAppBundleID else {
            errorSection = .permissions
            errorMessage = "请先选择要采集声音的应用。"
            return
        }
        isStarting = true
        capturedChunkCount = 0
        capturedSampleCount = 0
        capturedPeak = 0
        firstOriginalLatency = nil
        firstTranslationLatency = nil
        status = "正在加载服务…"
        isSubtitlePaused = false
        startupTask = Task { [self] in
            let capture = AudioCaptureEngine()
            defer { startupTask = nil }
            do {
                status = "正在检查录音权限…"
                try await permissions.authorizeScreen()
                try Task.checkCancellation()
                try await prepareServices()
                try Task.checkCancellation()
                let translations = CaptionRevisionQueue<TranslationSegment>()
                translationQueue = translations
                translationTask = Task { [weak self] in
                    for await _ in translations.wakeups {
                        while let item = translations.take() { await self?.translateCaption(item) }
                    }
                }
                let generation = UUID()
                captionGeneration = generation
                let stream = CaptionRevisionQueue<CapturedAudioSegment>()
                speechQueue = stream
                capture.processingOptions = SubtitleProcessingOptions(suppressMusic: suppressBackgroundMusic, stableCadence: stablePrefixesEnabled)
                capture.onSegment = { [weak self] segment in
                    let peak = segment.audio.samples.reduce(Float.zero) { max($0, abs($1)) }
                    let outcome = stream.offer(segment)
                    Task { @MainActor in
                        guard let self, self.captionGeneration == segment.generation else { return }
                        self.capturedChunkCount += 1
                        self.capturedSampleCount += segment.audio.samples.count
                        self.capturedPeak = max(self.capturedPeak, peak)
                        if case .overflow = outcome { self.handleProcessingOverload() }
                    }
                }
                capture.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.report(error, prefix: "音频采集已中断")
                        self?.stopCapture()
                    }
                }
                status = "正在请求音频权限并启动采集…"
                sessionStart = Date()
                sessionBase = captions.last?.end ?? 0
                sessionFirstCaptionIndex = captions.count
                captionRevisions.removeAll(); revisionGuards.removeAll(); prefixConfirmations.removeAll(); prefixTranslations.removeAll()
                try await capture.start(selectedBundleID: selectedAppBundleID, generation: generation)
                try Task.checkCancellation()
                captureEngine = capture
                isCapturing = true
                isStarting = false
                status = "正在监听 · 人声检测已启用，停顿后校订字幕"
                pipelineTask = Task { [weak self] in
                    for await _ in stream.wakeups {
                        while let segment = stream.take() {
                            guard !Task.isCancelled else { return }
                            let audio = segment.audio
                            await self?.process(audio.samples, start: (self?.sessionBase ?? 0) + max(0, audio.timestamp.timeIntervalSince(self?.sessionStart ?? audio.timestamp)),
                                queueTranslation: true, id: audio.id, revision: audio.revision, isFinal: audio.isFinal,
                                generation: segment.generation)
                        }
                    }
                }
            } catch {
                await capture.stop()
                speechQueue?.finish()
                speechQueue = nil
                translationQueue?.finish()
                await translationTask?.value
                translationQueue = nil
                translationTask = nil
                speechRecognizer = nil
                textTranslator = nil
                isStarting = false
                if !Task.isCancelled && !(error is CancellationError) { report(error, prefix: "无法开始字幕") }
            }
        }
    }

    func stopCapture() {
        guard isCapturing, !isStopping else { return }
        isStopping = true
        status = "正在完成最后一段字幕…"
        stopTask = Task {
            defer { stopTask = nil }
            await captureEngine?.stop()
            captureEngine = nil
            speechQueue?.finish()
            await pipelineTask?.value
            speechQueue = nil
            pipelineTask = nil
            translationQueue?.finish()
            await translationTask?.value
            translationQueue = nil
            translationTask = nil
            speechRecognizer = nil
            textTranslator = nil
            isCapturing = false
            isStopping = false
            status = "已停止 · 本次共 \(captions.count) 条字幕"
        }
    }

    enum SubtitlePlaybackIntent { case pause, resume, chooseApplication, prepareEngine }

    var canClearCaptions: Bool { !captions.isEmpty && !isStarting && !isStopping && !isProcessingFile && !isClearingCaptions }

    /// Called after destructive confirmation. Invalidate work before and after
    /// async inference, so old results cannot repopulate the cleared history.
    func clearCaptions() async {
        guard canClearCaptions else { return }
        isClearingCaptions = true
        defer { isClearingCaptions = false }
        let generation = UUID()
        captionGeneration = generation
        speechQueue?.discardPending()
        translationQueue?.discardPending()
        captions.removeAll()
        captionRevisions.removeAll(); revisionGuards.removeAll(); prefixConfirmations.removeAll(); prefixTranslations.removeAll()
        sessionFirstCaptionIndex = 0
        status = "字幕已清空"
        if let captureEngine, isCapturing {
            do {
                try await captureEngine.discardBufferedAudio(generation: generation)
                if isCapturing && !isStopping { status = "字幕已清空 · 继续监听 \(selectedAppName ?? "所选应用")" }
            } catch {
                report(error, prefix: "字幕已清空，但人声处理组件重启失败")
                stopCapture()
            }
        }
    }

    var subtitlePlaybackIntent: SubtitlePlaybackIntent {
        if isCapturing { return .pause }
        if !readinessIssues.isEmpty { return .prepareEngine }
        return selectedAppBundleID == nil ? .chooseApplication : .resume
    }

    func toggleSubtitlePlayback() {
        guard !isStarting, !isStopping, !isLoadingApplications, !isProcessingFile, !isClearingCaptions else { return }
        switch subtitlePlaybackIntent {
        case .pause:
            isSubtitlePaused = true
            stopCapture()
        case .prepareEngine:
            ensureLocalModels()
            if !isDownloadingModels { errorSection = .services; errorMessage = readinessIssues.joined(separator: "\n") }
        case .resume: startCapture()
        case .chooseApplication: selectApplication()
        }
    }

    /// Closing the subtitle window cancels startup as well as active capture.
    func finishSubtitleSession() async {
        cancelApplicationSelection()
        startupTask?.cancel()
        await startupTask?.value
        stopCapture()
        await stopTask?.value
        isSubtitlePaused = false
    }

    var subtitleStatus: String {
        if isDownloadingModels && !readinessIssues.isEmpty { return "正在准备本地引擎 · \(Int(downloadProgress * 100))%" }
        if isStarting { return "正在启动同传…" }
        if isLoadingApplications { return "正在读取应用列表…" }
        if isStopping { return "正在暂停…" }
        if isSubtitlePaused { return "已暂停 · 点击播放继续监听" }
        if isCapturing { return "正在监听 \(selectedAppName ?? "应用") · 等待日语语音…" }
        if !readinessIssues.isEmpty { return "点击播放，重新准备本地引擎" }
        return selectedAppBundleID == nil ? "点击播放，选择要监听的应用" : "点击播放，继续监听 \(selectedAppName ?? "应用")"
    }

    func selectApplication() {
        guard !isLoadingApplications, !isBusy else { return }
        isLoadingApplications = true
        let requestID = UUID()
        selectionRequestID = requestID
        Task {
            defer { if selectionRequestID == requestID { isLoadingApplications = false } }
            do {
                try await permissions.authorizeScreen()
                let apps = try await AudioCaptureEngine.availableApplications()
                guard selectionRequestID == requestID else { return }
                availableApps = apps
                isChoosingApplication = true
            } catch {
                guard selectionRequestID == requestID else { return }
                errorSection = .permissions
                section = .permissions
                report(error, prefix: "无法选择应用音频")
            }
        }
    }

    func chooseApplication(_ app: CaptureApplication) {
        selectedAppBundleID = app.bundleIdentifier
        selectedAppName = app.name
        pendingStartAfterSelection = isSubtitleOnly
        isChoosingApplication = false
    }

    func applicationPickerDidDismiss() {
        guard pendingStartAfterSelection else { return }
        pendingStartAfterSelection = false
        startCapture()
    }

    func cancelApplicationSelection() {
        selectionRequestID = UUID()
        pendingStartAfterSelection = false
        isLoadingApplications = false
        isChoosingApplication = false
    }

    func refreshModels() {
        asrInstalled = modelStore.isASRInstalled
        translationInstalled = modelStore.isTranslationInstalled
    }

    func ensureLocalModels() {
        guard !isDownloadingModels, !isBusy else { return }
        refreshModels()
        let needsASR = profiles.first { $0.id == selectedASRProfileID }?.kind == .local
        let needsMT = profiles.first { $0.id == selectedTranslationProfileID }?.kind == .local
        let pending: [(ServicePurpose, Double)] = [
            (.speechRecognition, needsASR && !asrInstalled ? Double(modelStore.asrDownloadBytes) : 0),
            (.translation, needsMT && !translationInstalled ? Double(modelStore.translationDownloadBytes) : 0)
        ].filter { $0.1 > 0 }
        guard !pending.isEmpty else { return }
        let total = pending.reduce(0.0) { $0 + $1.1 }
        let initiallyInstalled = 0.0
        isDownloadingModels = true
        downloadProgress = initiallyInstalled / total
        downloadStatus = "正在自动准备本地日中引擎…"
        status = downloadStatus
        downloadTask = Task { [self] in
            defer { isDownloadingModels = false; refreshModels(); downloadTask = nil }
            var completed = initiallyInstalled
            do {
                for (purpose, bytes) in pending {
                    let before = completed
                    let progress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
                        Task { @MainActor in
                            guard let self, self.isDownloadingModels else { return }
                            self.downloadProgress = (before + fraction * bytes) / total
                            let engineName = purpose == .speechRecognition ? "日语识别" : "中文翻译"
                            let phase = message.contains("校验") ? "正在校验" : "正在准备"
                            self.downloadStatus = "\(phase)\(engineName) · \(Int(self.downloadProgress * 100))%"
                        }
                    }
                    if purpose == .speechRecognition { try await modelStore.downloadASR(progress: progress) }
                    else { try await modelStore.downloadTranslation(progress: progress) }
                    completed += bytes
                    downloadProgress = completed / total
                    refreshModels()
                }
                downloadStatus = "本地日中引擎已就绪 · 已通过校验"
                status = "选择 Safari 等应用开始日中同传"
            } catch {
                downloadStatus = Task.isCancelled ? "本地引擎准备已暂停" : "自动准备失败：\(error.localizedDescription)"
                status = downloadStatus
            }
        }
    }

    func downloadModels(for purpose: ServicePurpose) {
        guard !isDownloadingModels else { return }
        isDownloadingModels = true
        downloadProgress = 0
        downloadStatus = "连接模型下载地址…"
        downloadTask = Task { [self] in
            defer { isDownloadingModels = false; refreshModels(); downloadTask = nil }
            do {
                let progress: @Sendable (Double, String) -> Void = { [weak self] value, text in
                    Task { @MainActor in
                        guard let self, self.isDownloadingModels else { return }
                        self.downloadProgress = value; self.downloadStatus = text
                    }
                }
                if purpose == .speechRecognition { try await modelStore.downloadASR(progress: progress) }
                else { try await modelStore.downloadTranslation(progress: progress) }
                downloadStatus = "下载完成，模型已通过 SHA-256 校验"
                status = downloadStatus
            } catch {
                if Task.isCancelled { downloadStatus = "下载已取消" }
                else { downloadStatus = "下载失败：\(error.localizedDescription)"; report(error, prefix: "模型下载失败") }
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    func importModels() {
        guard !isBusy, !isDownloadingModels else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择包含 asr/ 和 mt/ 的模型文件夹（与原项目 models 目录结构一致）。"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isDownloadingModels = true
                self.isImportingModels = true
                self.downloadStatus = "正在校验并导入模型…"
                defer { self.isDownloadingModels = false; self.isImportingModels = false; self.refreshModels() }
                do { try await self.modelStore.importModels(from: url); self.downloadStatus = "模型导入完成" }
                catch { self.report(error, prefix: "模型导入失败") }
            }
        }
    }

    func testConnection(for profile: ServiceProfile) async -> String {
        do {
            let key = try credential(for: profile)
            if profile.purpose == .translation {
                let result = try await OpenAICompatibleTranslator(profile: profile, apiKey: key)
                    .translate("こんにちは", from: "Japanese", to: "中文")
                return "翻译成功：\(result)"
            }
            let url = try profile.validatedBaseURL().appending(path: "models")
            var request = URLRequest(url: url, timeoutInterval: TimeInterval(profile.timeoutSeconds))
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            return "鉴权成功；请导入一段音频验证转写模型"
        } catch { return "测试失败：\(error.localizedDescription)" }
    }

    func saveAPIKey(_ key: String, for profile: ServiceProfile) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.missingAPIKey(profile.name) }
        try keyStore.save(trimmed, account: profile.id.uuidString)
        savedCredentialIDs.insert(profile.id)
    }

    func addProfile(_ purpose: ServicePurpose) {
        let profile = ServiceProfile(name: purpose == .speechRecognition ? "自定义转写" : "自定义翻译", kind: .openAICompatible,
                                     purpose: purpose, model: purpose == .speechRecognition ? "whisper-1" : "")
        profiles.append(profile)
    }

    func removeProfile(_ id: UUID) {
        guard !isBusy, let profile = profiles.first(where: { $0.id == id }), profile.kind != .local else { return }
        profiles.removeAll { $0.id == id }
        if selectedASRProfileID == id { selectedASRProfileID = profiles.first(where: { $0.purpose == .speechRecognition })?.id }
        if selectedTranslationProfileID == id { selectedTranslationProfileID = profiles.first(where: { $0.purpose == .translation })?.id }
        // The Keychain entry is retained so removing a profile cannot destroy a saved secret.
    }

    private func credential(for profile: ServiceProfile) throws -> String {
        guard let key = try keyStore.read(account: profile.id.uuidString), !key.isEmpty else { throw ServiceError.missingAPIKey(profile.name) }
        return key
    }

    @Published var glossary: [VTuberTerm] = VTuberGlossary.defaults
    private var cachedRecognizer: ReazonSpeechRecognizer?
    private var cachedRecognizerWords: [String] = []
    private var cachedTranslator: LocalLlamaTranslator?

    func saveGlossary(_ text: String) throws {
        let parsed = try VTuberGlossary.parse(text)
        let data = try JSONEncoder().encode(parsed)
        defaults.set(data, forKey: "vtuber.glossary.v122")
        glossary = parsed
        cachedRecognizer = nil
    }
    func addDeepSeekProfile() {
        guard !profiles.contains(where: { $0.isDeepSeek && $0.purpose == .translation }) else { return }
        profiles.append(.deepSeek)
        persistProfiles()
    }
    private func localRecognizer() async throws -> ReazonSpeechRecognizer {
        let words = asrHotwordsEnabled ? glossary.map(\.japanese) : []
        if let cachedRecognizer, cachedRecognizerWords == words { return cachedRecognizer }
        guard modelStore.isASRInstalled else { throw ServiceError.modelNotInstalled("日语识别") }
        let store = modelStore
        let engine = try await Task.detached(priority: .utility) { try ReazonSpeechRecognizer(store: store, hotwords: words) }.value
        asrHotwordStatus = "识别热词已载入 \(engine.hotwordPlan.accepted.count) 条" + (engine.hotwordPlan.rejected.isEmpty ? "" : "；不支持：" + engine.hotwordPlan.rejected.joined(separator: "、"))
        try Task.checkCancellation()
        cachedRecognizer = engine
        cachedRecognizerWords = words
        return engine
    }
    private func translator(for profile: ServiceProfile) async throws -> any TextTranslating {
        let engine: any TextTranslating
        if profile.kind == .local {
            guard modelStore.isTranslationInstalled else { throw ServiceError.modelNotInstalled("本地翻译") }
            if let cachedTranslator { engine = cachedTranslator }
            else {
                let path = modelStore.translationModelPath
                let loaded = try await Task.detached(priority: .utility) { try LocalLlamaTranslator(modelPath: path) }.value
                try Task.checkCancellation()
                cachedTranslator = loaded; engine = loaded
            }
        } else {
            _ = try profile.validatedBaseURL()
            engine = OpenAICompatibleTranslator(profile: profile, apiKey: try credential(for: profile))
        }
        return GlossaryTranslator(base: engine, terms: glossary)
    }
    func makeProofreadTranslator(configured: Bool) async throws -> any TextTranslating {
        guard !isBusy else { throw ClipError.message("请先停止实时字幕，再进行字幕核对。") }
        let profile = configured ? profiles.first { $0.id == selectedTranslationProfileID }
            : profiles.first { $0.kind == .local && $0.purpose == .translation }
        guard let profile, profile.isEnabled else { throw ClipError.message("请在服务设置中启用翻译模型。") }
        return try await translator(for: profile)
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    /// Reuse local engines across jobs; native inference is serialized and realtime
    /// capture cannot run concurrently with batch work. Local is the default.
    func makeClipServices(configured: Bool) async throws -> ClipServices {
        guard !isBusy else { throw ClipError.message("请先停止实时字幕或文件处理，再生成切片字幕。") }
        let asr = configured ? profiles.first(where: { $0.id == selectedASRProfileID }) : profiles.first(where: { $0.purpose == .speechRecognition && $0.kind == .local })
        let mt = configured ? profiles.first(where: { $0.id == selectedTranslationProfileID }) : profiles.first(where: { $0.purpose == .translation && $0.kind == .local })
        guard var asr, var mt, asr.isEnabled, mt.isEnabled else { throw ClipError.message("请在服务设置中启用日语识别和中文翻译。") }
        asr.sourceLanguage = "日语"; mt.targetLanguage = "中文"
        let recognizer: any SpeechRecognizing
        let translator: any TextTranslating
        if asr.kind == .local {
            guard modelStore.isASRInstalled else { throw ServiceError.modelNotInstalled("日语识别") }
            recognizer = try await localRecognizer()
        } else {
            _ = try asr.validatedBaseURL()
            recognizer = OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: try credential(for: asr))
        }
        try Task.checkCancellation()
        translator = try await self.translator(for: mt)
        try Task.checkCancellation()
        return ClipServices(recognizer: recognizer, translator: translator)
    }

    private func prepareServices() async throws {
        guard var asr = profiles.first(where: { $0.id == selectedASRProfileID }),
              var mt = profiles.first(where: { $0.id == selectedTranslationProfileID }) else { throw ServiceError.invalidResponse }
        asr.sourceLanguage = "日语"
        mt.targetLanguage = "中文"
        sessionProfile = mt
        sessionASRProfile = asr
        if asr.kind == .local {
            guard modelStore.isASRInstalled else { throw ServiceError.modelNotInstalled("日语识别") }
            speechRecognizer = try await localRecognizer()
        } else {
            _ = try asr.validatedBaseURL()
            speechRecognizer = OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: try credential(for: asr))
        }
        textTranslator = try await translator(for: mt)
    }

    func process(_ samples: [Float], start: Double, queueTranslation: Bool = false,
                 id: UUID = UUID(), revision: Int = 1, isFinal: Bool = true, generation: UUID? = nil) async {
        let generation = generation ?? captionGeneration
        guard generation == captionGeneration else { return }
        guard let speechRecognizer, textTranslator != nil, !samples.isEmpty else { return }
        // Silent chunks do not generate hallucinated text or billable cloud requests.
        guard samples.contains(where: { abs($0) > 0.003 }) else { status = "正在监听，等待声音…"; return }
        do {
            status = "正在识别…"
            guard revision > (captionRevisions[id] ?? 0) else { return }
            var revisionGuard = revisionGuards[id] ?? ASRRevisionGuard()
            let recognition = try await speechRecognizer.recognizeDetailed(samples: samples)
            guard generation == captionGeneration else { return }
            guard revision > (captionRevisions[id] ?? 0) else { return }
            let end = start + Double(samples.count) / 16_000
            let reconciliation = revisionGuard.reconcile(recognition, start: start, end: end)
            let protected = revisionGuard.protectRollback(reconciliation.text.trimmingCharacters(in: .whitespacesAndNewlines), start: start, end: end)
            revisionGuards[id] = isFinal ? nil : revisionGuard
            let original = protected.text
            if original.isEmpty {
                if isFinal {
                    captionRevisions[id] = revision; prefixConfirmations[id] = nil; prefixTranslations[id] = nil
                    if let index = captions.firstIndex(where: { $0.id == id }) {
                        captions[index].recognitionNotice = "整句识别为空，已保留上一版日语；待核对，不作为定稿导出。"
                        captions[index].confirmedPrefix = ""
                        captions[index].pendingOriginal = ""; captions[index].recognitionNeedsReview = true
                        captions[index].translated = "译文未完成：整句识别为空，已保留日语草稿"
                    }
                }
                status = "正在监听，等待说话…"
                return
            }
            captionRevisions[id] = revision
            if let index = captions.firstIndex(where: { $0.id == id }) {
                let previous = captions[index].original
                if previous != original && !previous.isEmpty {
                    captions[index].originalRevisions.append(previous)
                }
                if reconciliation.restored { captions[index].originalRevisions.append("本次识别候选：" + recognition.text) }
                captions[index].recognitionNotice = reconciliation.restored
                    ? "已恢复连续识别一致、且音频时间戳支持的遗漏前段。原始候选保留在修订记录中。"
                    : previous.count - original.count >= 6
                    ? "识别结果比上一版缩短，旧文字已保留在日语修订记录中，可检查是否遗漏。" : ""
                captions[index].pendingOriginal = protected.pending
                captions[index].recognitionNeedsReview = isFinal && protected.pending != nil
                if protected.pending != nil {
                    captions[index].recognitionNotice = isFinal ? "已拦截日语大幅回退：保留原文，新结果待核对。" : "检测到日语回退，暂时保留原文，等待后续识别。"
                }
                captions[index].original = original
                captions[index].start = start
                captions[index].end = end
                captions[index].isDraft = true
                if isFinal || !original.hasPrefix(captions[index].confirmedPrefix) { captions[index].confirmedPrefix = "" }
            } else {
                captions.append(Caption(id: id, start: start, end: end, original: original, translated: "", isDraft: true))
            }
            if protected.pending != nil {
                if let index = captions.firstIndex(where: { $0.id == id }) {
                    captions[index].translated = "译文未完成：日语识别回退，已保留原文"
                }
                if isFinal { prefixConfirmations[id] = nil; prefixTranslations[id] = nil }
                status = isFinal ? "日语出现大幅回退，请在字幕记录核对候选" : "日语回退保护中，等待后续识别"
                return
            }
            if queueTranslation, firstOriginalLatency == nil { firstOriginalLatency = Date().timeIntervalSince(sessionStart) }
            // A changing Japanese draft is useful, but translating each revision
            // repeats work and makes finalized Chinese wait behind obsolete drafts.
            guard isFinal else {
                if stablePrefixesEnabled {
                    var confirmation = prefixConfirmations[id] ?? StablePrefixConfirmation()
                    let prefix = confirmation.observe(original, samples: samples.count)
                    prefixConfirmations[id] = confirmation
                    if let prefix, let i = captions.firstIndex(where: { $0.id == id }) { captions[i].confirmedPrefix = prefix }
                    if let prefix, textTranslator?.requiresFullUtterance == false {
                        let item = TranslationSegment(id: id, revision: revision, isFinal: false,
                            original: prefix, source: "Japanese", target: "中文", live: queueTranslation, generation: generation)
                        if queueTranslation {
                            if case .some(.overflow) = translationQueue?.offer(item) { handleProcessingOverload() }
                        } else { await translateCaption(item) }
                    }
                    if let saved = prefixTranslations[id], !original.hasPrefix(saved.source) {
                        prefixTranslations[id] = nil
                        if let i = captions.firstIndex(where: { $0.id == id }) { captions[i].translated = "" }
                    }
                }
                status = textTranslator?.requiresFullUtterance == true ? "日语前段确认中 · 本地中文等待整句以保留语义" : "日语草稿 · 稳定分句可提前翻译，后文继续确认"
                return
            }
            if let index = captions.firstIndex(where: { $0.id == id }) {
                if let saved = prefixTranslations[id], original.hasPrefix(saved.source) { captions[index].translated = saved.chinese + " …" }
                else { captions[index].translated = "正在翻译…" }
            }
            let item = TranslationSegment(id: id, revision: revision, isFinal: isFinal,
                original: original, source: "Japanese", target: "中文", live: queueTranslation, generation: generation)
            if queueTranslation {
                if case .some(.overflow) = translationQueue?.offer(item) { handleProcessingOverload() }
                status = isFinal ? "正在用完整语音校订字幕…" : "说话中 · 字幕草稿会在停顿后校订"
            } else {
                await translateCaption(item)
            }
        } catch {
            guard generation == captionGeneration else { return }
            if isFinal {
                revisionGuards[id] = nil
                captionRevisions[id] = revision
                prefixConfirmations[id] = nil; prefixTranslations[id] = nil
                if let index = captions.firstIndex(where: { $0.id == id }) {
                    captions[index].translated = "译文未完成：整句识别失败"
                    captions[index].recognitionNotice = "整句识别失败，已保留日语草稿与修订记录。"
                }
            }
            status = "识别失败：\(error.localizedDescription)"
        }
    }

    private func translateCaption(_ item: TranslationSegment) async {
        guard let textTranslator else { return }
        guard captions.first(where: { $0.id == item.id })?.pendingOriginal == nil else { return }
        // A pending newer source revision makes this work obsolete. Final revisions
        // are queued separately and cannot be overwritten by a stale draft result.
        guard item.generation == captionGeneration else { return }
        if item.isFinal { guard captionRevisions[item.id] == item.revision else { return } }
        else { guard captions.contains(where: { $0.id == item.id && $0.isDraft && $0.original.hasPrefix(item.original) }) else { return } }
        do {
            let currentStart = captions.first { $0.id == item.id }?.start ?? 0
            let previous = captions.dropFirst(sessionFirstCaptionIndex).filter {
                $0.id != item.id && !$0.isDraft && $0.end <= currentStart + 0.001
            }.sorted { $0.start < $1.start }
            var context = SubtitleTranslationContext(previous: previous.suffix(2).map {
                .init(original: $0.original, translated: SubtitleDocument.completedTranslation($0) ?? "")
            }, isFinal: true)
            context.isStablePrefix = !item.isFinal
            let reusable = item.isFinal ? prefixTranslations[item.id].flatMap { item.original.hasPrefix($0.source) ? $0 : nil } : nil
            let source = reusable.map { String(item.original.dropFirst($0.source.count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? item.original
            if let reusable { context.previous.append(.init(original: reusable.source, translated: reusable.chinese)) }
            let tail = source.isEmpty ? "" : try await textTranslator.translate(source, from: item.source, to: item.target, context: context)
            if !source.isEmpty && tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ServiceError.emptyResponse }
            let translated = [reusable?.chinese ?? "", tail].filter { !$0.isEmpty }.joined(separator: "\n")
            guard item.generation == captionGeneration else { return }
            if item.isFinal { guard captionRevisions[item.id] == item.revision else { return } }
            else { guard captions.contains(where: { $0.id == item.id && $0.isDraft && $0.original.hasPrefix(item.original) }) else { return } }
            guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.emptyResponse }
            guard captions.first(where: { $0.id == item.id })?.pendingOriginal == nil else { return }
            if let index = captions.firstIndex(where: { $0.id == item.id }) {
                captions[index].translated = translated + (item.isFinal ? "" : " …")
                captions[index].isDraft = !item.isFinal
                if !item.isFinal { prefixTranslations[item.id] = (item.original, translated) }
                else { prefixTranslations[item.id] = nil; prefixConfirmations[item.id] = nil }
            }
            if item.live, firstTranslationLatency == nil { firstTranslationLatency = Date().timeIntervalSince(sessionStart) }
            status = item.isFinal ? "整句字幕已校订 · \(captions.count) 条" : "字幕草稿 · 说话结束后会自动校订"
        } catch {
            guard item.generation == captionGeneration, captionRevisions[item.id] == item.revision else { return }
            if !item.isFinal { status = "提前翻译未完成，将在定稿后重试"; return }
            prefixConfirmations[item.id] = nil; prefixTranslations[item.id] = nil
            if let index = captions.firstIndex(where: { $0.id == item.id }) { captions[index].translated = "翻译失败：\(error.localizedDescription)" }
            status = "已保留原文，翻译失败：\(error.localizedDescription)"
        }
    }

    func resolveRecognition(_ id: UUID, useCandidate: Bool) async {
        guard let snapshot = captions.first(where: { $0.id == id }), snapshot.recognitionNeedsReview,
              let candidate = snapshot.pendingOriginal else { return }
        guard !useCandidate || !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = captionGeneration
        let revision = captionRevisions[id] ?? 0
        do {
            if textTranslator == nil { try await prepareServices() }
            guard generation == captionGeneration, revision == captionRevisions[id],
                  let index = captions.firstIndex(where: { $0.id == id }) else { return }
            let chosen = useCandidate ? candidate : snapshot.original
            captions[index].originalRevisions.append("回退候选：" + candidate)
            if useCandidate { captions[index].originalRevisions.append(snapshot.original) }
            captions[index].original = chosen
            captions[index].pendingOriginal = nil; captions[index].recognitionNeedsReview = false
            captions[index].recognitionNotice = "已由用户核对日语原文"
            captions[index].translated = "正在翻译…"
            captionRevisions[id] = revision + 1
            await translateCaption(.init(id: id, revision: revision + 1, isFinal: true, original: chosen,
                source: "Japanese", target: "中文", live: false, generation: generation))
            if generation == captionGeneration, captionRevisions[id] == revision + 1,
               let failedIndex = captions.firstIndex(where: { $0.id == id }), captions[failedIndex].isDraft {
                captions[failedIndex].pendingOriginal = chosen
                captions[failedIndex].recognitionNeedsReview = true
                captions[failedIndex].recognitionNotice = "已保存核对后的日语，翻译未完成；可点击保留原文并翻译重试。"
            }
        } catch { errorMessage = "核对后翻译未启动：" + error.localizedDescription }
    }

    private func handleProcessingOverload() {
        stopCapture()
        errorSection = .services
        errorMessage = "当前处理速度跟不上直播，已停止采集并保留待处理片段；队列满时的当前片段可能未完成。请检查所选服务或稍后重试。"
    }

    nonisolated static func removingOverlap(_ text: String, previous: String) -> String {
        let left = Array(previous), right = Array(text)
        guard right.count > 3 else { return text }
        for count in stride(from: min(left.count, right.count - 1, 80), through: 3, by: -1) {
            guard left.suffix(count).elementsEqual(right.prefix(count)) else { continue }
            let prefix = String(right.prefix(count))
            let hasJapanese = prefix.containsJapaneseScript
            guard hasJapanese || (count >= 8 && (right[count].isWhitespace || right[count - 1].isWhitespace)) else { continue }
            return String(right.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    func importAudio() {
        guard !isBusy else { return }
        if !readinessIssues.isEmpty { section = .services; errorMessage = readinessIssues.joined(separator: "\n"); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "导入日语音频；本地人声处理后，按说话停顿分段并翻译。"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, !self.isBusy else { return }
                self.isProcessingFile = true
                defer { self.isProcessingFile = false; self.speechRecognizer = nil; self.textTranslator = nil }
                do {
                    try await self.prepareServices()
                    let samples = try await Task.detached { try AudioFileReader.read(url) }.value
                    let base = self.captions.last?.end ?? 0
                    self.sessionFirstCaptionIndex = self.captions.count
                    let options = SubtitleProcessingOptions(suppressMusic: self.suppressBackgroundMusic, showDrafts: false)
                    let segments = try await Task.detached { () -> [AudioSegment] in
                        let processor = try SpeechAudioFrontend(options: options)
                        var segments: [AudioSegment] = []
                        processor.begin(at: Date(timeIntervalSince1970: 0))
                        processor.onSegment = { segments.append($0) }
                        for offset in stride(from: 0, to: samples.count, by: 1_600) {
                            processor.accept(Array(samples[offset..<min(offset + 1_600, samples.count)]))
                        }
                        processor.finish()
                        return segments
                    }.value
                    for segment in segments {
                        await self.process(segment.samples, start: base + segment.timestamp.timeIntervalSince1970,
                            id: segment.id, revision: segment.revision)
                    }
                    self.status = "音频处理完成 · \(self.captions.count) 条字幕"
                } catch { self.report(error, prefix: "音频处理失败") }
            }
        }
    }

    func exportCaptions(format: SubtitleExportFormat = .srt) {
        guard !captions.isEmpty else { return }
        // Snapshot both the text and language choice before opening the save dialog.
        let text = SubtitleDocument.render(captions, format: format, mode: subtitleDisplayMode)
        guard !text.isEmpty else {
            errorMessage = "暂时没有已定稿的译文。说话结束并校订后即可导出；临时草稿不会写入文档。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 \(format.title) 字幕"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SimuSub.\(format.rawValue)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.status = "\(format.title) 字幕已导出"
            } catch { self.report(error, prefix: "字幕导出失败") }
        }
    }

    static func srt(_ captions: [Caption]) -> String {
        SubtitleDocument.render(captions, format: .srt, mode: .bilingual)
    }

}

private struct TranslationSegment: CaptionRevision {
    let id: UUID
    let revision: Int
    let isFinal: Bool
    let original: String
    let source: String
    let target: String
    let live: Bool
    let generation: UUID
}
