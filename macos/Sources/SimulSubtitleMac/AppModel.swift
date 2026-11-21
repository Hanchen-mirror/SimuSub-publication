import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .live
    @Published var isSubtitleOnly = false
    @Published private(set) var sourceLanguage: SubtitleLanguage = .japanese
    @Published private(set) var targetLanguage: SubtitleLanguage = .simplifiedChinese

    func setSourceLanguage(_ language: SubtitleLanguage) {
        guard !isBusy else { return }
        if language == targetLanguage { targetLanguage = sourceLanguage }
        sourceLanguage = language
        persistLanguages()
    }
    func setTargetLanguage(_ language: SubtitleLanguage) {
        guard !isBusy else { return }
        if language == sourceLanguage { sourceLanguage = targetLanguage }
        targetLanguage = language
        persistLanguages()
    }
    func swapLanguages() {
        guard !isBusy else { return }
        let oldSource = sourceLanguage
        sourceLanguage = targetLanguage; targetLanguage = oldSource
        persistLanguages()
    }
    private var pendingLanguageChange: UUID?
    var canChangeSubtitleLanguages: Bool {
        pendingLanguageChange == nil && !isStarting && !isStopping && !isLoadingApplications
            && !isChoosingApplication && !isProcessingFile && !isClearingCaptions
            && !modelsAreDownloading && subtitlePreparationBytes == nil
    }

    var liveTranslationTarget: SubtitleLanguage? { originalOnly ? nil : targetLanguage }

    func applySubtitleLanguages(source: SubtitleLanguage, target: SubtitleLanguage?) async {
        guard canChangeSubtitleLanguages, source != target,
              source != sourceLanguage || target != liveTranslationTarget else { return }
        let mode: SubtitleDisplayMode = target == nil ? .original : (originalOnly ? .bilingual : subtitleDisplayMode)
        // Toggling translation does not interrupt the audio stream or reset ASR.
        if source == sourceLanguage, target == nil || originalOnly {
            if let target {
                targetLanguage = target
                defaults.set(target.rawValue, forKey: "subtitle.targetLanguage.v141")
            }
            subtitleDisplayMode = mode
            return
        }
        if target == nil { subtitleDisplayMode = .original }
        let resume = isCapturing
        if resume {
            // Finalize the old language's audio and queued translations before changing its engines.
            let request = UUID()
            pendingLanguageChange = request
            stopCapture()
            await stopTask?.value
            guard pendingLanguageChange == request else { return }
            pendingLanguageChange = nil
        }
        guard canBeginSubtitleCapture else { return }
        targetLanguage = target ?? (source == targetLanguage ? sourceLanguage : targetLanguage)
        sourceLanguage = source
        subtitleDisplayMode = mode
        persistLanguages()
        if resume { startCapture(showSubtitles: isSubtitleOnly) }
    }
    private var cachedRoutingIndex: LocalLlamaTranslator?

    private func persistLanguages() {
        preferSelectedLanguageRecognizer()
        defaults.set(sourceLanguage.rawValue, forKey: "subtitle.sourceLanguage.v141")
        defaults.set(targetLanguage.rawValue, forKey: "subtitle.targetLanguage.v141")
        speechRecognizer = nil; textTranslator = nil
    }
    static let recognitionLanguages: [SubtitleLanguage] = [.japanese, .english, .simplifiedChinese]

    func recognitionChoices(for language: SubtitleLanguage) -> [ServiceProfile] {
        profiles.filter { profile in
            guard profile.purpose == .speechRecognition, profile.isEnabled else { return false }
            if profile.kind != .local { return savedCredentialIDs.contains(profile.id) }
            return supportsRecognition(profile, language: language) && localProfileInstalled(profile)
        }
    }

    /// An explicit choice may use any implemented multilingual engine. Automatic routing
    /// still selects the official language model and never silently switches to the cloud.
    func supportsRecognition(_ profile: ServiceProfile, language: SubtitleLanguage) -> Bool {
        guard profile.kind == .local, profile.purpose == .speechRecognition else { return false }
        guard let id = profile.localModelID else { return language == .japanese && profile.localModelPath == nil }
        if id == "gemma4-e4b" { return true }
        guard let definition = LocalModelDefinition.catalog.first(where: { $0.id == id }) else { return false }
        return ["whisper", "senseVoice", "qwen3ASR"].contains(definition.engine)
    }

    private func isOfficialRecognizer(_ profile: ServiceProfile, for language: SubtitleLanguage) -> Bool {
        guard profile.kind == .local, profile.purpose == .speechRecognition, profile.localModelPath == nil else { return false }
        switch language {
        case .japanese: return profile.localModelID == nil
        case .english: return profile.localModelID == "whisper-base"
        case .simplifiedChinese, .traditionalChinese: return profile.localModelID == "sensevoice"
        }
    }
    var translationChoices: [ServiceProfile] {
        profiles.filter { profile in
            guard profile.purpose == .translation, profile.isEnabled else { return false }
            if profile.kind != .local { return savedCredentialIDs.contains(profile.id) }
            return localProfileInstalled(profile)
        }
    }
    private func automaticRecognition(for language: SubtitleLanguage) -> ServiceProfile? {
        profiles.first { $0.isEnabled && isOfficialRecognizer($0, for: language) }
    }

    func recognitionProfile(for language: SubtitleLanguage) -> ServiceProfile? {
        let override = recognitionOverrides[language.asrCode]
        return recognitionChoices(for: language).first { $0.id == override }
            ?? automaticRecognition(for: language)
    }

    func hasRecognitionOverride(for language: SubtitleLanguage) -> Bool {
        recognitionChoices(for: language).contains { $0.id == recognitionOverrides[language.asrCode] }
    }

    func chooseRecognition(_ id: UUID?, for language: SubtitleLanguage) {
        guard !isBusy, id == nil || recognitionChoices(for: language).contains(where: { $0.id == id }) else { return }
        recognitionOverrides[language.asrCode] = id
        persistRecognitionOverrides()
        if language.asrCode == sourceLanguage.asrCode {
            preferSelectedLanguageRecognizer()
            speechRecognizer = nil
        }
    }

    func toggleCloudRecognition(_ id: UUID, for language: SubtitleLanguage) {
        guard !isBusy, profiles.contains(where: { $0.id == id && $0.kind != .local && $0.purpose == .speechRecognition }) else { return }
        chooseRecognition(recognitionOverrides[language.asrCode] == id ? nil : id, for: language)
    }

    private var defaultLocalTranslation: ServiceProfile? {
        profiles.first { $0.kind == .local && $0.purpose == .translation && $0.isEnabled && $0.localModelID == nil && $0.localModelPath == nil }
            ?? translationChoices.first { $0.kind == .local }
    }

    func toggleCloudTranslation(_ id: UUID) {
        guard !isBusy, profiles.contains(where: { $0.id == id && $0.kind != .local && $0.purpose == .translation }) else { return }
        if selectedTranslationProfileID == id {
            selectedTranslationProfileID = defaultLocalTranslation?.id
        } else if translationChoices.contains(where: { $0.id == id }) {
            selectedTranslationProfileID = id
        }
    }

    private func persistRecognitionOverrides() {
        defaults.set(recognitionOverrides.mapValues(\.uuidString), forKey: Self.recognitionOverridesKey)
    }

    private func preferSelectedLanguageRecognizer() {
        // Keep the v1.44 language-specific recognition route independent of MT.
        let id = recognitionProfile(for: sourceLanguage)?.id
        if id != selectedASRProfileID {
            isChoosingAutomaticRecognition = true
            selectedASRProfileID = id
            isChoosingAutomaticRecognition = false
        }
    }
    var recognitionLanguageIssue: String? {
        guard sourceLanguage != .japanese,
              let profile = profiles.first(where: { $0.id == selectedASRProfileID }), profile.kind == .local,
              profile.localModelID == nil else { return nil }
        return "请选择多语言识别模型或接口"
    }
    @Published var subtitleDisplayMode: SubtitleDisplayMode = .bilingual {
        didSet {
            defaults.set(subtitleDisplayMode.rawValue, forKey: "subtitleDisplayMode.v101")
            if subtitleDisplayMode == .original, oldValue != .original {
                cancelTranslationPreview()
                activeFinalTranslation?.cancel()
                translationQueue?.discardPending()
                prefixTranslations.removeAll()
                prefixConfirmations.removeAll()
                for i in captions.indices where captions[i].isDraft && revisionGuards[captions[i].id] == nil {
                    captions[i].translated = ""; captions[i].isDraft = false
                }
            }
        }
    }
    var originalOnly: Bool { subtitleDisplayMode == .original }
    func toggleBilingualDisplay() {
        subtitleDisplayMode = subtitleDisplayMode == .bilingual ? .original : .bilingual
    }
    @Published var isSubtitlePinned = true {
        didSet { defaults.set(isSubtitlePinned, forKey: "subtitlePinned.v1") }
    }
    @Published var isCapturing = false
    @Published var isStarting = false
    @Published var isStopping = false
    @Published private(set) var isSubtitlePaused = false
    @Published var isProcessingFile = false
    @Published var status = "正在准备本地字幕引擎"
    @Published var errorMessage: String?
    @Published var selectedAppName: String? = "Mac 声音"
    @Published var selectedAppBundleID: String? = AudioCaptureEngine.systemAudioID
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
    private(set) var refinedEnglishVocalCues = 0
    var englishVocalLoopCounts: [String: Int] { englishVocalRecognition.loopCounts }
    @Published private(set) var capturedChunkCount = 0
    @Published private(set) var capturedSampleCount = 0
    @Published private(set) var capturedPeak: Float = 0
    @Published private(set) var firstOriginalLatency: TimeInterval?
    @Published private(set) var firstTranslationLatency: TimeInterval?
    private(set) var firstPreviewTranslationLatency: TimeInterval?
    private(set) var firstFinalTranslationLatency: TimeInterval?
    @Published var selectedASRProfileID: UUID? {
        didSet {
            if !isChoosingAutomaticRecognition {
                recognitionOverrides[sourceLanguage.asrCode] = selectedASRProfileID
                persistRecognitionOverrides()
                defaults.set(hasRecognitionOverride(for: sourceLanguage), forKey: Self.explicitRecognitionKey)
            }
            defaults.set(selectedASRProfileID?.uuidString, forKey: "selectedASRProfileID.v2")
            refreshModels()
        }
    }
    @Published var selectedTranslationProfileID: UUID? {
        didSet { defaults.set(selectedTranslationProfileID?.uuidString, forKey: "selectedTranslationProfileID.v2"); refreshModels() }
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
    private let modelDownloadsAllowed: Bool
    private let keyStore = SecureCredentialStore()
    let modelStore: LocalModelStore
    let localModels: LocalModelLibrary
    @Published private(set) var onboardingCompleted = false

    func completeOnboarding() {
        onboardingCompleted = true
        defaults.set(true, forKey: "onboarding.completed.v131")
    }
    private var captureEngine: AudioCaptureEngine?
    private var startupTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var selectionRequestID = UUID()
    private var pendingStartAfterSelection = false
    private var shouldStartAfterPicking = false
    @Published private(set) var recognitionOverrides: [String: UUID] = [:]
    private var isChoosingAutomaticRecognition = false
    private var speechRecognizer: SpeechRecognizing?
    private var textTranslator: TextTranslating?
    private var pipelineTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var activeFinalTranslation: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: TranslationSegment?
    private var translatingFinal = false
    private var stoppingForBacklog = false
    private var translationQueue: CaptionRevisionQueue<TranslationSegment>?
    private var downloadTask: Task<Void, Never>?
    private var speechQueue: CaptionRevisionQueue<CapturedAudioSegment>?
    private let englishVocalRecognition = EnglishVocalRecognition()
    private var captionGeneration = UUID() { didSet { englishVocalRecognition.reset() } }
    private var captionRevisions: [UUID: Int] = [:]
    private var revisionGuards: [UUID: ASRRevisionGuard] = [:]
    private var phraseIDs: [UUID: [UUID]] = [:]
    private var japaneseFinalTail: (window: UUID, cue: UUID, generation: UUID, app: String?)?
    var onJapaneseHypothesis: ((UUID, Double, Double, Bool, RecognizedSpeech, String) -> Void)?
    private var gemmaDraftPolicy = GemmaDraftPolicy()
    private var prefixConfirmations: [UUID: StablePrefixConfirmation] = [:]
    private var prefixTranslations: [UUID: (source: String, chinese: String)] = [:]
    private var sessionFirstCaptionIndex = 0
    private var sessionProfile: ServiceProfile?
    private var sessionASRProfile: ServiceProfile?
    private var sessionBase: Double = 0
    private var sessionStart = Date()
    private static let profilesKey = "serviceProfiles.v2"
    private static let recognitionOverridesKey = "subtitle.recognitionByLanguage.v144"
    private static let explicitRecognitionKey = "subtitle.explicitRecognition.v143"
    private static let permissionResumeKey = "subtitle.pendingPermissionSource.v143"

    private enum SubtitleModelDownload: Sendable {
        case builtIn(ServicePurpose), catalog(LocalModelDefinition)
    }
    private struct SubtitlePreparation: Sendable {
        let downloads: [(model: SubtitleModelDownload, bytes: Int64)]
        let showSubtitles: Bool
        var bytes: Int64 { downloads.reduce(0) { $0 + $1.bytes } }
    }
    private var subtitlePreparation: SubtitlePreparation?
    @Published private(set) var subtitlePreparationBytes: Int64?
    @Published private(set) var subtitlePreparationError: String?
    @Published private(set) var subtitleNeedsPermission = false
    @Published private(set) var subtitleStartError: String?
    private var waitingForPermissionSettings = false

    private var catalogDownloadObservation: AnyCancellable?
    var modelsAreDownloading: Bool { isDownloadingModels || localModels.downloadingID != nil }
    var canBeginSubtitleCapture: Bool { !isBusy && !modelsAreDownloading }
    var isBusy: Bool { isCapturing || isStarting || isStopping || isProcessingFile || subtitlePreparationBytes != nil }
    var serviceSelectionLockReason: String? {
        if subtitlePreparationBytes != nil { return "正在准备本地字幕" }
        if isStopping { return "正在完成最后一段字幕，完成后可切换模型。" }
        if isStarting { return "同传正在启动，停止后可切换模型。" }
        if isProcessingFile { return "正在处理音频，完成后可切换模型。" }
        if isCapturing { return "同传运行中，停止后可切换模型。" }
        return nil
    }
    var readinessIssues: [String] {
        let issues: [String] = (originalOnly ? [selectedASRProfileID] : [selectedASRProfileID, selectedTranslationProfileID]).compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id }) else { return "请选择处理服务" }
            if profile.kind == .local {
                let installed = profile.localModelID == nil && profile.localModelPath == nil
                    ? (profile.purpose == .speechRecognition ? asrInstalled : translationInstalled) : localProfileInstalled(profile)
                return installed ? nil : "\(profile.name)尚未安装"
            }
            if (try? profile.validatedBaseURL()) == nil { return "\(profile.name)的服务地址无效" }
            if profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "\(profile.name)需要填写模型名称" }
            return savedCredentialIDs.contains(profile.id) ? nil : "\(profile.name)需要保存 API Key"
        }
        return (recognitionLanguageIssue.map { [$0] } ?? []) + issues
    }

    init(defaults: UserDefaults = .standard, modelStore: LocalModelStore = LocalModelStore(),
         recognizer: SpeechRecognizing? = nil, translator: TextTranslating? = nil,
         modelDownloadsAllowed: Bool = !AppLaunchOptions.isDiagnostic) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.modelDownloadsAllowed = modelDownloadsAllowed
        self.localModels = LocalModelLibrary(defaults: defaults, defaultRoot: modelStore.root, downloadsAllowed: modelDownloadsAllowed)
        let interfaceLanguage = AppLocalization.preferredLanguage(defaults: defaults)
        sourceLanguage = defaults.string(forKey: "subtitle.sourceLanguage.v141").flatMap(SubtitleLanguage.init(rawValue:))
            ?? (interfaceLanguage == .japanese ? .english : .japanese)
        targetLanguage = defaults.string(forKey: "subtitle.targetLanguage.v141").flatMap(SubtitleLanguage.init(rawValue:)) ?? interfaceLanguage
        if let pendingSource = defaults.dictionary(forKey: Self.permissionResumeKey) as? [String: String] {
            selectedAppBundleID = pendingSource["id"]
            selectedAppName = pendingSource["name"]
            subtitleNeedsPermission = true
        }
        onboardingCompleted = defaults.bool(forKey: "onboarding.completed.v131")
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
        if defaults === UserDefaults.standard, defaults.data(forKey: Self.profilesKey) == nil,
           Bundle.main.bundleIdentifier != PermissionRecovery.localCandidateBundleID {
            // Prefer the most recent app's configuration; keep profile IDs for Keychain access.
            for domain in ["com.mirror.simusub", "com.mirror.simulsubtitle.mac", "io.github.korenkrita.simulsubtitle"] {
                guard let legacy = defaults.persistentDomain(forName: domain),
                      let data = (legacy[Self.profilesKey] ?? legacy["serviceProfiles.v1"]) as? Data,
                      let saved = try? JSONDecoder().decode([ServiceProfile].self, from: data),
                      !saved.isEmpty else { continue }
                for key in [Self.profilesKey, "selectedASRProfileID.v2", "selectedTranslationProfileID.v2",
                            "subtitlePinned.v1"] {
                    if let value = legacy[key] { defaults.set(value, forKey: key) }
                }
                break
            }
        }
        isSubtitlePinned = defaults.object(forKey: "subtitlePinned.v1") as? Bool ?? true
        if let data = defaults.data(forKey: Self.profilesKey),
           let saved = try? JSONDecoder().decode([ServiceProfile].self, from: data), !saved.isEmpty {
            profiles = saved.map { profile in
                var value = profile
                if value.kind == .local && value.purpose == .speechRecognition && value.localModelID == nil { value.name = "本地日语识别"; value.model = "ReazonSpeech ja" }
                return value
            }
        }
        if let data = defaults.data(forKey: "vtuber.glossary.v122"), let saved = try? JSONDecoder().decode([VTuberTerm].self, from: data) { glossary = saved }
        // Migrate only the retired official IDs, retaining profile UUID and Keychain account.
        for i in profiles.indices where profiles[i].isDeepSeek && ["deepseek-chat", "deepseek-reasoner"].contains(profiles[i].model) {
            profiles[i].model = "deepseek-flash"
        }
        for definition in LocalModelDefinition.catalog where !profiles.contains(where: { $0.localModelID == definition.id && $0.purpose == definition.purpose }) {
            profiles.append(ServiceProfile(name: definition.name, kind: .local, purpose: definition.purpose,
                model: definition.name, localModelID: definition.id))
        }
        if !profiles.contains(where: { $0.localModelID == "gemma4-e4b" && $0.purpose == .speechRecognition }) {
            profiles.append(ServiceProfile(name: "Gemma 4 E4B", kind: .local, purpose: .speechRecognition,
                model: "Gemma 4 E4B", localModelID: "gemma4-e4b"))
        }
        // Load availability before migrating a legacy explicit remote ASR route.
        savedCredentialIDs = Set(profiles.filter { keyStore.contains(account: $0.id.uuidString) }.map(\.id))
        let savedASR = defaults.string(forKey: "selectedASRProfileID.v2").flatMap(UUID.init(uuidString:))
        let savedMT = defaults.string(forKey: "selectedTranslationProfileID.v2").flatMap(UUID.init(uuidString:))
        let savedRecognition = profiles.first { $0.id == savedASR && $0.purpose == .speechRecognition }
        if let overrides = defaults.dictionary(forKey: Self.recognitionOverridesKey) as? [String: String] {
            recognitionOverrides = overrides.compactMapValues(UUID.init(uuidString:)).filter { _, id in
                profiles.contains { $0.id == id && $0.purpose == .speechRecognition && $0.isEnabled }
            }
        } else if let savedRecognition, savedRecognition.isEnabled,
                  defaults.object(forKey: Self.explicitRecognitionKey) as? Bool
                    ?? (savedRecognition.kind != .local || savedRecognition.localModelID != nil) {
            for language in Self.recognitionLanguages where recognitionChoices(for: language).contains(where: { $0.id == savedRecognition.id }) {
                recognitionOverrides[language.asrCode] = savedRecognition.id
            }
        }
        persistRecognitionOverrides()
        isChoosingAutomaticRecognition = true
        selectedASRProfileID = savedRecognition?.id
            ?? profiles.first(where: { $0.purpose == .speechRecognition })?.id
        isChoosingAutomaticRecognition = false
        selectedTranslationProfileID = profiles.first(where: { $0.id == savedMT && $0.purpose == .translation })?.id
            ?? defaultLocalTranslation?.id
        if defaults.bool(forKey: "subtitle.gemmaUnified.v145"), !defaults.bool(forKey: "subtitle.splitLanguage.v146") {
            // Undo the experimental forced route once. Keep unrelated explicit
            // services and all models/settings; later MT selections persist.
            recognitionOverrides = recognitionOverrides.filter { _, id in
                profiles.first { $0.id == id }?.localModelID?.hasPrefix("gemma4-") != true
            }
            persistRecognitionOverrides()
            if profiles.first(where: { $0.id == selectedTranslationProfileID })?.localModelID?.hasPrefix("gemma4-") == true {
                selectedTranslationProfileID = profiles.first { $0.kind == .local && $0.purpose == .translation && $0.isEnabled && $0.model == "Index-Translate-2B" }?.id
            }
            defaults.set(true, forKey: "subtitle.splitLanguage.v146")
        }
        // Explicit installed imports remain selected across launches. Only fall back
        // when that local selection is disabled or no longer available.
        if let selected = profiles.first(where: { $0.id == selectedTranslationProfileID }), selected.kind == .local,
           !selected.isEnabled || ((selected.localModelID != nil || selected.localModelPath != nil) && !localProfileInstalled(selected)) {
            selectedTranslationProfileID = defaultLocalTranslation?.id
        }
        preferSelectedLanguageRecognizer()
        refreshModels()
        persistProfiles()
        catalogDownloadObservation = localModels.$downloadingID.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        localModels.onChange = { [weak self] in
            guard let self else { return }
            if !self.isBusy { self.preferSelectedLanguageRecognizer() }
            self.refreshModels()
            self.objectWillChange.send()
        }
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

    func setSubtitleSource(id: String?, name: String?) {
        guard !isBusy else { return }
        if id != selectedAppBundleID { cancelSubtitlePermissionResume() }
        selectedAppBundleID = id
        selectedAppName = name
        subtitleStartError = nil
    }

    private func markSubtitlePermissionPending(sourceID: String?, startAfterPicking: Bool = false) {
        guard !AppLaunchOptions.isDiagnostic else { return }
        subtitleNeedsPermission = true
        var pendingSource = ["startAfterPicking": startAfterPicking ? "yes" : "no"]
        if let sourceID {
            pendingSource["id"] = sourceID
            pendingSource["name"] = selectedAppName
        }
        defaults.set(pendingSource, forKey: Self.permissionResumeKey)
        isSubtitleOnly = false
    }

    func cancelSubtitlePermissionResume() {
        waitingForPermissionSettings = false
        subtitleNeedsPermission = false
        defaults.removeObject(forKey: Self.permissionResumeKey)
    }

    func openSubtitlePermissionSettings() {
        waitingForPermissionSettings = true
        permissions.openSettings()
    }

    func retrySubtitlePermission() {
        guard subtitleNeedsPermission, !isBusy, !isLoadingApplications else { return }
        waitingForPermissionSettings = false
        let pendingSource = defaults.dictionary(forKey: Self.permissionResumeKey) as? [String: String]
        if let sourceID = pendingSource?["id"], sourceID == selectedAppBundleID {
            startCapture(showSubtitles: true)
        } else {
            selectApplication(startAfterSelection: pendingSource?["startAfterPicking"] == "yes")
        }
    }

    func resumeSubtitleAfterAuthorization(onLaunch: Bool = false) {
        guard !AppLaunchOptions.isDiagnostic, subtitleNeedsPermission, !isBusy,
              onLaunch || waitingForPermissionSettings else { return }
        retrySubtitlePermission()
    }

    private func subtitleModelDownloads() throws -> [(model: SubtitleModelDownload, bytes: Int64)] {
        if let issue = recognitionLanguageIssue { throw ClipError.message(issue) }
        var seenCatalogIDs = Set<String>()
        var result: [(model: SubtitleModelDownload, bytes: Int64)] = try (originalOnly ? [selectedASRProfileID] : [selectedASRProfileID, selectedTranslationProfileID]).compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id && $0.isEnabled }) else {
                throw ClipError.message("请选择处理服务")
            }
            if profile.kind != .local {
                _ = try profile.validatedBaseURL()
                _ = try credential(for: profile)
                return nil
            }
            if let path = profile.localModelPath {
                guard FileManager.default.isReadableFile(atPath: path) else { throw ServiceError.modelNotInstalled(profile.name) }
                return nil
            }
            if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }) {
                guard seenCatalogIDs.insert(definition.id).inserted else { return nil }
                let missing = try localModels.missingDownloadBytes(for: definition)
                return missing == 0 ? nil : (.catalog(definition), missing)
            }
            let missing = try modelStore.missingDownloadBytes(for: profile.purpose)
            return missing == 0 ? nil : (.builtIn(profile.purpose), missing)
        }
        if !originalOnly && profiles.first(where: { $0.id == selectedTranslationProfileID })?.localModelID == "hy-mt" {
            let missing = try modelStore.missingDownloadBytes(for: .translation)
            if missing > 0 { result.append((.builtIn(.translation), missing)) }
        }
        if profiles.first(where: { $0.id == selectedASRProfileID })?.localModelID == "qwen3-asr" {
            for id in ["sensevoice", "whisper-base"] {
                guard let definition = LocalModelDefinition.catalog.first(where: { $0.id == id }) else { throw ServiceError.modelFilesMissing }
                let missing = try localModels.missingDownloadBytes(for: definition)
                if missing > 0 { result.append((.catalog(definition), missing)) }
            }
            let missing = try modelStore.missingDownloadBytes(for: .speechRecognition)
            if missing > 0 { result.append((.builtIn(.speechRecognition), missing)) }
        }
        return result
    }

    func subtitleModelDownloadBytes() throws -> Int64 {
        try subtitleModelDownloads().reduce(0) { $0 + $1.bytes }
    }

    func cancelSubtitlePreparation() {
        if subtitlePreparation != nil { downloadTask?.cancel() }
        clearSubtitlePreparation()
    }

    private func clearSubtitlePreparation() {
        subtitlePreparation = nil
        subtitlePreparationBytes = nil
        subtitlePreparationError = nil
    }

    func prepareSubtitleModels() {
        guard modelDownloadsAllowed, let preparation = subtitlePreparation,
              !isDownloadingModels, localModels.downloadingID == nil else { return }
        isDownloadingModels = true
        subtitlePreparationError = nil
        downloadProgress = 0
        downloadTask = Task { [self] in
            defer { isDownloadingModels = false; downloadTask = nil; refreshModels() }
            var completed: Int64 = 0
            do {
                for (model, bytes) in preparation.downloads {
                    try Task.checkCancellation()
                    let before = completed
                    let update: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
                        guard let self, self.subtitlePreparation != nil, self.isDownloadingModels else { return }
                        let value = (Double(before) + fraction * Double(bytes)) / Double(preparation.bytes)
                        self.downloadProgress = max(self.downloadProgress, value)
                    }
                    switch model {
                    case .catalog(let definition): try await localModels.install(definition, onProgress: update)
                    case .builtIn(let purpose):
                        let progress: LocalModelStore.Progress = { fraction, _ in Task { @MainActor in update(fraction) } }
                        if purpose == .speechRecognition { try await modelStore.downloadASR(progress: progress) }
                        else { try await modelStore.downloadTranslation(progress: progress) }
                    }
                    completed += bytes
                    update(1)
                }
                try Task.checkCancellation()
                clearSubtitlePreparation()
                isDownloadingModels = false
                startCapture(showSubtitles: preparation.showSubtitles)
            } catch is CancellationError {
                clearSubtitlePreparation()
            } catch {
                if Task.isCancelled { clearSubtitlePreparation(); return }
                guard subtitlePreparation != nil else { return }
                subtitlePreparationError = error.localizedDescription
                if let remaining = try? subtitleModelDownloads(), !remaining.isEmpty {
                    let retry = SubtitlePreparation(downloads: remaining, showSubtitles: preparation.showSubtitles)
                    subtitlePreparation = retry
                    subtitlePreparationBytes = retry.bytes
                }
            }
        }
    }

    func startCapture(showSubtitles: Bool = false) {
        guard canBeginSubtitleCapture else { return }
        guard let selectedAppBundleID else {
            subtitleStartError = "请先选择要采集声音的应用。"
            return
        }
        subtitleStartError = nil
        preferSelectedLanguageRecognizer()
        isStarting = true
        refinedEnglishVocalCues = 0
        englishVocalRecognition.resetLoopCounts()
        capturedChunkCount = 0
        capturedSampleCount = 0
        capturedPeak = 0
        firstOriginalLatency = nil
        firstTranslationLatency = nil
        firstPreviewTranslationLatency = nil
        firstFinalTranslationLatency = nil
        stoppingForBacklog = false
        status = "正在启动同传…"
        isSubtitlePaused = false
        startupTask = Task { [self] in
            let capture = AudioCaptureEngine()
            defer { startupTask = nil }
            do {
                let missing = try subtitleModelDownloads()
                status = "正在检查录音权限…"
                try await permissions.authorizeScreen()
                try Task.checkCancellation()
                if subtitleNeedsPermission { cancelSubtitlePermissionResume() }
                if !missing.isEmpty {
                    let preparation = SubtitlePreparation(downloads: missing, showSubtitles: showSubtitles)
                    subtitlePreparation = preparation
                    subtitlePreparationBytes = preparation.bytes
                    isStarting = false
                    return
                }
                status = "正在加载服务…"
                try await prepareServices()
                try Task.checkCancellation()
                startLiveTranslationWorker()
                let generation = UUID()
                captionGeneration = generation
                let stream = CaptionRevisionQueue<CapturedAudioSegment>()
                speechQueue = stream
                capture.processingOptions = SubtitleProcessingOptions(suppressMusic: suppressBackgroundMusic, stableCadence: stablePrefixesEnabled,
                    liveEnglishToChinese: sourceLanguage == .english && targetLanguage.isChinese && !originalOnly,
                    japanesePhraseBoundaries: sourceLanguage == .japanese && !(speechRecognizer is ReazonSpeechRecognizer))
                capture.onSegment = { [weak self] segment in
                    let peak = segment.audio.samples.reduce(Float.zero) { max($0, abs($1)) }
                    _ = stream.offerPreservingFinal(segment) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.captionGeneration == segment.generation else { return }
                            self.handleProcessingOverload()
                        }
                    }
                    Task { @MainActor in
                        guard let self, self.captionGeneration == segment.generation else { return }
                        self.capturedChunkCount += 1
                        self.capturedSampleCount += segment.audio.samples.count
                        self.capturedPeak = max(self.capturedPeak, peak)
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
                captionRevisions.removeAll(); revisionGuards.removeAll(); phraseIDs.removeAll(); prefixConfirmations.removeAll(); prefixTranslations.removeAll()
                gemmaDraftPolicy = GemmaDraftPolicy()
                status = "正在启动音频采集…"
                pipelineTask = Task { [weak self] in
                    for await _ in stream.wakeups {
                        while let segment = stream.take() {
                            guard !Task.isCancelled else { return }
                            let audio = segment.audio
                            await self?.process(audio.samples, start: (self?.sessionBase ?? 0) + max(0, audio.timestamp.timeIntervalSince(self?.sessionStart ?? audio.timestamp)),
                                queueTranslation: true, id: audio.id, revision: audio.revision, isFinal: audio.isFinal,
                                generation: segment.generation, quietRecognitionTail: audio.quietRecognitionTail,
                                continuesForcedWindow: audio.continuesForcedWindow)
                        }
                    }
                }
                try await capture.start(selectedBundleID: selectedAppBundleID, generation: generation)
                try Task.checkCancellation()
                captureEngine = capture
                isCapturing = true
                isStarting = false
                if showSubtitles { isSubtitleOnly = true }
                status = "正在监听 · 人声检测已启用，停顿后校订字幕"
                if stoppingForBacklog { stopCapture() }
            } catch {
                await capture.stop()
                speechQueue?.finish()
                await pipelineTask?.value
                pipelineTask = nil
                speechQueue = nil
                await finishLiveTranslationWorker()
                englishVocalRecognition.reset()
                speechRecognizer = nil
                textTranslator = nil
                isStarting = false
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if showSubtitles, error is CapturePermissionError {
                    markSubtitlePermissionPending(sourceID: selectedAppBundleID)
                } else if isSubtitleOnly {
                    report(error, prefix: "无法开始字幕")
                } else {
                    subtitleStartError = error.localizedDescription
                }
            }
        }
    }

    func stopCapture() {
        guard isCapturing, !isStopping else { return }
        isStopping = true
        cancelTranslationPreview()
        status = "正在完成最后一段字幕…"
        stopTask = Task {
            defer { stopTask = nil }
            await captureEngine?.stop()
            captureEngine = nil
            speechQueue?.finish()
            await pipelineTask?.value
            speechQueue = nil
            pipelineTask = nil
            await finishLiveTranslationWorker()
            englishVocalRecognition.reset()
            speechRecognizer = nil
            textTranslator = nil
            isCapturing = false
            isStopping = false
            status = "已停止 · 本次共 \(captions.count) 条字幕"
        }
    }

    enum SubtitlePlaybackIntent { case pause, resume, chooseApplication }

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
        cancelTranslationPreview()
        translationQueue?.discardPending()
        captions.removeAll()
        captionRevisions.removeAll(); revisionGuards.removeAll(); phraseIDs.removeAll(); prefixConfirmations.removeAll(); prefixTranslations.removeAll()
        gemmaDraftPolicy = GemmaDraftPolicy()
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
        return selectedAppBundleID == nil ? .chooseApplication : .resume
    }

    func toggleSubtitlePlayback() {
        guard !isStarting, !isStopping, !isLoadingApplications, !isProcessingFile, !isClearingCaptions else { return }
        if !isCapturing, let issue = recognitionLanguageIssue {
            errorSection = .services; errorMessage = issue; return
        }
        switch subtitlePlaybackIntent {
        case .pause:
            isSubtitlePaused = true
            stopCapture()
        case .resume: startCapture(showSubtitles: true)
        case .chooseApplication: selectApplication()
        }
    }

    /// Closing the subtitle window cancels startup as well as active capture.
    func finishSubtitleSession() async {
        pendingLanguageChange = nil
        cancelApplicationSelection()
        cancelSubtitlePreparation()
        startupTask?.cancel()
        await startupTask?.value
        stopCapture()
        await stopTask?.value
        isSubtitlePaused = false
    }

    /// Release Metal contexts before process-level backend teardown.
    func shutdownLocalEngines() async {
        await finishSubtitleSession()
        clearLocalEngines()
    }

    private func clearLocalEngines() {
        speechRecognizer = nil
        textTranslator = nil
        cachedRecognizer = nil
        cachedMultilingualRecognizer = nil
        cachedMultilingualKey = nil
        cachedTranslator = nil
        cachedTranslatorPath = nil
        cachedRoutingIndex = nil
    }

    var subtitleStatus: String {
        if let subtitleStartError { return subtitleStartError }
        if isDownloadingModels && !readinessIssues.isEmpty { return "正在准备本地引擎 · \(Int(downloadProgress * 100))%" }
        if isStarting { return "正在启动同传…" }
        if isLoadingApplications { return "正在读取应用列表…" }
        if isStopping { return "正在暂停…" }
        if isSubtitlePaused { return "已暂停 · 点击播放继续监听" }
        if isCapturing { return "正在监听 \(selectedAppName ?? "应用") · 等待语音…" }
        if recognitionLanguageIssue != nil { return "请选择多语言识别接口" }
        if !readinessIssues.isEmpty { return "点击播放，重新准备本地引擎" }
        return selectedAppBundleID == nil ? "点击播放，选择要监听的应用" : "点击播放，继续监听 \(selectedAppName ?? "应用")"
    }

    func selectApplication(startAfterSelection: Bool = false) {
        guard !isLoadingApplications, !isBusy else { return }
        shouldStartAfterPicking = isSubtitleOnly || startAfterSelection
        isLoadingApplications = true
        let requestID = UUID()
        selectionRequestID = requestID
        Task {
            defer { if selectionRequestID == requestID { isLoadingApplications = false } }
            do {
                try await permissions.authorizeScreen()
                let apps = try await AudioCaptureEngine.availableApplications()
                guard selectionRequestID == requestID else { return }
                if subtitleNeedsPermission { cancelSubtitlePermissionResume() }
                availableApps = apps
                isChoosingApplication = true
            } catch {
                guard selectionRequestID == requestID else { return }
                if error is CapturePermissionError, !AppLaunchOptions.isDiagnostic {
                    markSubtitlePermissionPending(sourceID: nil, startAfterPicking: shouldStartAfterPicking)
                } else {
                    report(error, prefix: "无法选择应用音频")
                }
            }
        }
    }

    func chooseApplication(_ app: CaptureApplication) {
        setSubtitleSource(id: app.bundleIdentifier, name: app.name)
        pendingStartAfterSelection = shouldStartAfterPicking
        isChoosingApplication = false
    }

    func applicationPickerDidDismiss() {
        guard pendingStartAfterSelection else { return }
        pendingStartAfterSelection = false
        startCapture(showSubtitles: true)
    }

    func cancelApplicationSelection() {
        selectionRequestID = UUID()
        pendingStartAfterSelection = false
        shouldStartAfterPicking = false
        isLoadingApplications = false
        isChoosingApplication = false
    }

    func refreshModels() {
        asrInstalled = profiles.first(where: { $0.id == selectedASRProfileID }).map(localProfileInstalled) ?? false
        translationInstalled = profiles.first(where: { $0.id == selectedTranslationProfileID }).map(localProfileInstalled) ?? false
    }

    func ensureLocalModels() {
        guard modelDownloadsAllowed, !isDownloadingModels, !isBusy else { return }
        if let profile = profiles.first(where: { $0.id == selectedTranslationProfileID }),
           let path = profile.localModelPath, !FileManager.default.isReadableFile(atPath: path) {
            errorMessage = "导入的模型文件不可读取，请重新选择模型。"; return
        }
        if let profile = profiles.first(where: { $0.id == selectedASRProfileID && $0.kind == .local }),
           let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }), !localModels.isUsable(definition) {
            localModels.download(definition); return
        }
        if let profile = profiles.first(where: { $0.id == selectedTranslationProfileID && $0.kind == .local }),
           let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }), !localModels.isUsable(definition) {
            localModels.download(definition); return
        }
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
        downloadStatus = "正在自动准备本地字幕引擎…"
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
                downloadStatus = "本地字幕引擎已就绪 · 已通过校验"
                status = "选择 Safari 等应用开始字幕同传"
            } catch {
                downloadStatus = Task.isCancelled ? "本地引擎准备已暂停" : "自动准备失败：\(error.localizedDescription)"
                status = downloadStatus
            }
        }
    }

    func downloadModels(for purpose: ServicePurpose) {
        guard modelDownloadsAllowed, !isDownloadingModels, !isBusy else { return }
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

    func cancelDownload() { downloadTask?.cancel(); localModels.cancel() }

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

    func testConnection(for profile: ServiceProfile, draftKey: String = "") async -> String {
        do {
            let entered = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = entered.isEmpty ? try credential(for: profile) : entered
            if profile.purpose == .translation {
                let result = try await OpenAICompatibleTranslator(profile: profile, apiKey: key)
                    .translate(sourceLanguage.preview, from: sourceLanguage.name, to: targetLanguage.name)
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

    /// Test the selected model's actual API, rather than accepting a /models response.
    func checkSetupConnection(for profile: ServiceProfile) async throws {
        let key = try credential(for: profile)
        if profile.purpose == .translation {
            _ = try await OpenAICompatibleTranslator(profile: profile, apiKey: key)
                .translate(sourceLanguage.preview, from: sourceLanguage.name, to: targetLanguage.name)
        } else {
            // A synthetic silent WAV checks authentication, model and transcription endpoint.
            _ = try await OpenAICompatibleSpeechRecognizer(profile: profile, apiKey: key)
                .recognize(samples: [Float](repeating: 0, count: 16_000))
        }
    }

    func saveAPIKey(_ key: String, for profile: ServiceProfile) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceError.missingAPIKey(profile.name) }
        try keyStore.save(trimmed, account: profile.id.uuidString)
        savedCredentialIDs.insert(profile.id)
    }

    @discardableResult func addProfile(_ purpose: ServicePurpose) -> UUID {
        let profile = ServiceProfile(name: purpose == .speechRecognition ? "自定义转写" : "自定义翻译", kind: .openAICompatible,
                                     purpose: purpose, model: purpose == .speechRecognition ? "whisper-1" : "")
        profiles.append(profile)
        return profile.id
    }

    func removeProfile(_ id: UUID) {
        guard !isBusy, let profile = profiles.first(where: { $0.id == id }), (profile.kind != .local || profile.localModelPath != nil) else { return }
        profiles.removeAll { $0.id == id }
        if profile.purpose == .speechRecognition {
            recognitionOverrides = recognitionOverrides.filter { $0.value != id }
            persistRecognitionOverrides()
            preferSelectedLanguageRecognizer()
        }
        if selectedTranslationProfileID == id {
            selectedTranslationProfileID = profiles.first { $0.purpose == .translation && $0.kind == .local && $0.isEnabled && $0.localModelID == nil && $0.localModelPath == nil }?.id
                ?? translationChoices.first?.id
        }
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
    private var cachedTranslatorPath: String?
    private var cachedMultilingualRecognizer: (any SpeechRecognizing)?
    private var cachedMultilingualKey: String?

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
    private func localJapaneseRecognizer() async throws -> ReazonSpeechRecognizer {
        let words = asrHotwordsEnabled ? glossary.map(\.japanese) : []
        if let cachedRecognizer, cachedRecognizerWords == words { return cachedRecognizer }
        guard try await modelStore.verifyInstalled(for: .speechRecognition) else { throw ServiceError.modelNotInstalled("日语识别") }
        let store = modelStore
        let engine = try await Task.detached(priority: .utility) { try ReazonSpeechRecognizer(store: store, hotwords: words) }.value
        asrHotwordStatus = "识别热词已载入 \(engine.hotwordPlan.accepted.count) 条" + (engine.hotwordPlan.rejected.isEmpty ? "" : "；不支持：" + engine.hotwordPlan.rejected.joined(separator: "、"))
        try Task.checkCancellation()
        cachedRecognizer = engine
        cachedRecognizerWords = words
        return engine
    }
    private func translator(for profile: ServiceProfile, reviewClip: Bool = false) async throws -> any TextTranslating {
        let engine: any TextTranslating
        if profile.kind == .local {
            guard localProfileInstalled(profile) else { throw ServiceError.modelNotInstalled(profile.name) }
            if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }) { try await localModels.verifyReady(definition) }
            let path = localTranslationPath(profile)
            let local: LocalLlamaTranslator
            if let cachedTranslator, cachedTranslatorPath == path { local = cachedTranslator }
            else {
                let automatic = path != modelStore.translationModelPath
                if !automatic {
                    guard try await modelStore.verifyInstalled(for: .translation) else {
                        throw ServiceError.modelNotInstalled(profile.name)
                    }
                }
                let loaded = try await Task.detached(priority: .utility) { try LocalLlamaTranslator(modelPath: path, useModelTemplate: automatic, compactPrompt: profile.localModelID == "hy-mt", gemma4Prompt: profile.localModelID?.hasPrefix("gemma4-") == true) }.value
                try Task.checkCancellation()
                cachedTranslator = loaded; cachedTranslatorPath = path; local = loaded
            }
            if profile.localModelID == "hy-mt" {
                if cachedRoutingIndex == nil {
                    guard try await modelStore.verifyInstalled(for: .translation) else { throw ServiceError.modelNotInstalled("Index-Translate") }
                    let indexPath = modelStore.translationModelPath
                    cachedRoutingIndex = try await Task.detached(priority: .utility) { try LocalLlamaTranslator(modelPath: indexPath) }.value
                }
                engine = PromptedLocalTranslator(base: LocalSubtitleTranslator(index: cachedRoutingIndex!, hunyuan: local), instructions: profile.effectiveTranslationPrompt)
            } else {
                let reviewed: any TextTranslating = reviewClip && path == modelStore.translationModelPath
                    ? ClipJapaneseTranslationReview(base: local) : local
                engine = PromptedLocalTranslator(base: reviewed, instructions: profile.effectiveTranslationPrompt)
            }
        } else {
            _ = try profile.validatedBaseURL()
            engine = OpenAICompatibleTranslator(profile: profile, apiKey: try credential(for: profile))
        }
        return LanguageAwareTranslator(base: GlossaryTranslator(base: engine, terms: glossary))
    }
    func makeProofreadTranslator(configured: Bool) async throws -> any TextTranslating {
        guard !isBusy else { throw ClipError.message("请先停止实时字幕，再进行字幕核对。") }
        let profile = configured ? profiles.first { $0.id == selectedTranslationProfileID }
            : (profiles.first { $0.id == selectedTranslationProfileID && $0.kind == .local }
                ?? profiles.first { $0.kind == .local && $0.purpose == .translation })
        guard let profile, profile.isEnabled else { throw ClipError.message("请在服务设置中启用翻译模型。") }
        return try await translator(for: profile, reviewClip: true)
    }

    func modelFolder(for profile: ServiceProfile) -> URL {
        if let file = profile.localModelPath { return URL(fileURLWithPath: file).deletingLastPathComponent() }
        if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }) {
            return localModels.folder(for: definition)
        }
        return profile.purpose == .speechRecognition ? modelStore.managedSpeechFiles.folder :
            URL(fileURLWithPath: modelStore.translationModelPath).deletingLastPathComponent()
    }

    enum LocalModelRemoval {
        case files(ManagedModelFiles), importedFolder(LocalModelDefinition), importedProfile
        var isReference: Bool {
            if case .files = self { return false }
            return true
        }
    }

    func removal(for profile: ServiceProfile) -> LocalModelRemoval? {
        guard profile.kind == .local else { return nil }
        if profile.localModelPath != nil { return .importedProfile }
        let files: ManagedModelFiles
        if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }) {
            if localModels.isImported(definition) { return .importedFolder(definition) }
            files = ManagedModelFiles(folder: localModels.folder(for: definition), filenames: definition.files.map(\.name))
        } else {
            // The built-in translation model is a shared, read-only installation.
            guard profile.purpose == .speechRecognition, profile.localModelID == nil else { return nil }
            files = modelStore.managedSpeechFiles
        }
        return files.hasFiles ? .files(files) : nil
    }

    func removeLocalModel(_ profile: ServiceProfile) {
        guard !isBusy, !isDownloadingModels, localModels.downloadingID == nil,
              let removal = removal(for: profile) else { return }
        do {
            switch removal {
            case .files(let files): try files.moveToTrash()
            case .importedFolder(let definition): localModels.unlink(definition)
            case .importedProfile: removeProfile(profile.id)
            }
            clearLocalEngines()
            preferSelectedLanguageRecognizer()
            refreshModels()
            localModels.message = removal.isReference ? "已移除模型引用" : "模型文件已移到废纸篓"
        } catch {
            refreshModels()
            localModels.message = error.localizedDescription
        }
    }

    func localProfileInstalled(_ profile: ServiceProfile) -> Bool {
        if let path = profile.localModelPath { return FileManager.default.isReadableFile(atPath: path) }
        if let id = profile.localModelID, let definition = LocalModelDefinition.catalog.first(where: { $0.id == id }) {
            return localModels.isUsable(definition)
        }
        return profile.purpose == .speechRecognition ? modelStore.isASRInstalled : modelStore.isTranslationInstalled
    }
    func localTranslationPath(_ profile: ServiceProfile) -> String {
        if let path = profile.localModelPath { return path }
        if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }), let file = definition.files.first {
            return localModels.folder(for: definition).appendingPathComponent(file.name).path
        }
        return modelStore.translationModelPath
    }
    private func localRecognizer(for profile: ServiceProfile, language: SubtitleLanguage, automatic: Bool = false) async throws -> any SpeechRecognizing {
        guard let id = profile.localModelID, let definition = LocalModelDefinition.catalog.first(where: { $0.id == id }) else {
            guard language == .japanese else { throw ClipError.message("请选择多语言识别模型或接口") }
            return try await localJapaneseRecognizer()
        }
        return try await localCatalogRecognizer(definition, language: language, automatic: automatic)
    }

    private func localCatalogRecognizer(_ definition: LocalModelDefinition, language: SubtitleLanguage,
                                        automatic: Bool = false) async throws -> any SpeechRecognizing {
        guard localModels.isUsable(definition) else { throw ServiceError.modelNotInstalled(definition.name) }
        let id = definition.id
        let folder = localModels.folder(for: definition)
        if id == "gemma4-e4b" {
            let key = id + "|" + folder.path
            if let cachedMultilingualRecognizer, cachedMultilingualKey == key { return cachedMultilingualRecognizer }
            try await localModels.verifyReady(definition)
            let path = folder.appendingPathComponent("gemma-4-E4B_q4_0-it.gguf").path
            let local: LocalLlamaTranslator
            if let cachedTranslator, cachedTranslatorPath == path { local = cachedTranslator }
            else {
                local = try await Task.detached(priority: .utility) {
                    try LocalLlamaTranslator(modelPath: path, gemma4Prompt: true)
                }.value
                cachedTranslator = local; cachedTranslatorPath = path
            }
            let projection = try await Task.detached(priority: .utility) {
                try GemmaAudioProjector.prepare(source: folder.appendingPathComponent("gemma-4-E4B-it-mmproj.gguf"),
                    sourceSHA256: "7498a37cb619e55f2fcf87eb931f56e99389ed6d432e4c5c66110694c0d65578",
                    derivedSHA256: "7abbe8f5114c003ddf6c5f927b10b90c1ef90130ece2968b07b3616208ebb101",
                    compatibleDerivedSHA256: "17a814ae1def73feaa3a30168289193bb232d17a65c2917ab29afc2a5eb73e1b")
            }.value
            try Task.checkCancellation()
            let speech = GemmaSpeechRecognizer(engine: local, projectionPath: projection.path)
            cachedMultilingualRecognizer = speech; cachedMultilingualKey = key
            return speech
        }
        let dependencies = LocalModelDefinition.catalog.filter { ["sensevoice", "whisper-base", "qwen3-asr"].contains($0.id) }
        let folders = Dictionary(uniqueKeysWithValues: dependencies.map { ($0.id, localModels.folder(for: $0)) })
        let key = id + "|" + folder.path + "|" + (automatic ? "auto|" + dependencies.map { folders[$0.id]!.path }.joined(separator: "|") : language.rawValue)
        if let cachedMultilingualRecognizer, cachedMultilingualKey == key { return cachedMultilingualRecognizer }
        try await localModels.verifyReady(definition)
        let loaded: any SpeechRecognizing
        if automatic && id == "qwen3-asr" {
            for item in dependencies { try await localModels.verifyReady(item) }
            guard try await modelStore.verifyInstalled(for: .speechRecognition) else { throw ServiceError.modelFilesMissing }
            let store = modelStore
            loaded = try await Task.detached(priority: .utility) { try AutomaticSpeechRecognizer(store: store, folders: folders) }.value
        } else {
            loaded = try await Task.detached(priority: .utility) { try MultilingualSpeechRecognizer(model: definition, folder: folder, language: automatic ? nil : language) }.value
        }
        try Task.checkCancellation()
        cachedMultilingualRecognizer = loaded; cachedMultilingualKey = key
        return loaded
    }
    func chooseTranslationModel() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false; panel.title = L10n.text("导入翻译模型")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isImportingModels = true; defer { isImportingModels = false }
            do { _ = try await useTranslationModel(at: url) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    @discardableResult
    func useTranslationModel(at url: URL) async throws -> UUID {
        guard !isBusy else { throw ClipError.message("请先停止同传，再导入模型。") }
        try await Task.detached { try LocalModelLibrary.validateGGUF(url) }.value
        guard !isBusy else { throw ClipError.message("请先停止同传，再导入模型。") }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == URL(fileURLWithPath: modelStore.translationModelPath).resolvingSymlinksInPath().path,
           let original = profiles.first(where: { $0.kind == .local && $0.purpose == .translation && $0.localModelID == nil && $0.localModelPath == nil }) {
            guard try await modelStore.verifyInstalled(for: .translation) else { throw ServiceError.modelNotInstalled(original.name) }
            guard !isBusy else { throw ClipError.message("请先停止同传，再导入模型。") }
            selectedTranslationProfileID = original.id; refreshModels(); return original.id
        }
        if let existing = profiles.first(where: { $0.kind == .local && $0.purpose == .translation && localProfileInstalled($0)
            && URL(fileURLWithPath: localTranslationPath($0)).resolvingSymlinksInPath().path == path }) {
            selectedTranslationProfileID = existing.id; refreshModels(); return existing.id
        }
        let profile = ServiceProfile(name: url.deletingPathExtension().lastPathComponent, kind: .local, purpose: .translation,
            model: url.lastPathComponent, localModelPath: path)
        profiles.append(profile); selectedTranslationProfileID = profile.id; refreshModels(); return profile.id
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.profilesKey)
    }

    /// Reuse local engines across jobs; native inference is serialized and realtime
    /// capture cannot run concurrently with batch work. Local is the default.
    private func clipVerifierDefinition(for profile: ServiceProfile, language: SubtitleLanguage) -> LocalModelDefinition? {
        guard language == .japanese, profile.kind == .local, profile.localModelID == nil,
              !hasRecognitionOverride(for: language),
              let model = LocalModelDefinition.catalog.first(where: { $0.id == "sensevoice" }),
              localModels.isUsable(model) else { return nil }
        return model
    }

    func clipGenerationKey(source: SubtitleLanguage, target: SubtitleLanguage) throws -> String {
        guard let asr = recognitionProfile(for: source),
              let mt = profiles.first(where: { $0.id == selectedTranslationProfileID && $0.purpose == .translation && $0.isEnabled }) else {
            throw ClipError.message("请在模型与服务中选择识别和翻译服务。")
        }
        // Only the digest is saved in a project. Profile changes, including a new
        // model at the same endpoint, invalidate a previously generated range.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode([asr, mt])
        data.append(contentsOf: try encoder.encode([source, target]))
        data.append(contentsOf: try encoder.encode(glossary))
        data.append(asrHotwordsEnabled ? 1 : 0)
        data.append(contentsOf: "clip-audio-presentation-time-v2".utf8)
        if source == .japanese && asr.kind == .openAICompatible {
            data.append(contentsOf: "clip-cloud-ja-speech-coverage-v1".utf8)
        }
        if source == .japanese, asr.kind == .local, asr.localModelID == nil {
            data.append(contentsOf: "clip-ja-gap-verification-v6".utf8)
            if let verifier = clipVerifierDefinition(for: asr, language: source) {
                data.append(contentsOf: try encoder.encode(verifier.files.map(\.sha256)))
            }
        }
        if source == .japanese, target.isChinese, mt.kind == .local, localTranslationPath(mt) == modelStore.translationModelPath {
            data.append(contentsOf: "clip-ja-zh-translation-review-v1".utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func makeClipServices(configured: Bool, source: SubtitleLanguage? = nil, target: SubtitleLanguage? = nil) async throws -> ClipServices {
        let source = source ?? sourceLanguage, target = target ?? targetLanguage
        guard !isBusy else { throw ClipError.message("请先停止实时字幕或文件处理，再生成切片字幕。") }
        let chosen = recognitionProfile(for: source)
        let localASR = chosen.flatMap { profile in
            recognitionChoices(for: source).contains { $0.id == profile.id && $0.kind == .local } ? profile : nil
        } ?? automaticRecognition(for: source)
        let asr = configured ? chosen : localASR
        let mt = configured ? profiles.first(where: { $0.id == selectedTranslationProfileID })
            : (profiles.first { $0.id == selectedTranslationProfileID && $0.kind == .local }
                ?? profiles.first { $0.purpose == .translation && $0.kind == .local })
        guard var asr, var mt, asr.isEnabled, mt.isEnabled else { throw ClipError.message("请在模型与服务中启用所选语言的识别与翻译服务。") }
        asr.sourceLanguage = source.name; mt.sourceLanguage = source.name; mt.targetLanguage = target.name
        let recognizer: any SpeechRecognizing
        let translator: any TextTranslating
        if asr.kind == .local {
            recognizer = try await localRecognizer(for: asr, language: source)
        } else {
            _ = try asr.validatedBaseURL()
            recognizer = OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: try credential(for: asr))
        }
        try Task.checkCancellation()
        translator = try await self.translator(for: mt, reviewClip: true)
        try Task.checkCancellation()
        var verifier: (any SpeechRecognizing)?
        if let definition = clipVerifierDefinition(for: asr, language: source) {
            verifier = try await localCatalogRecognizer(definition, language: .japanese)
        }
        return ClipServices(recognizer: recognizer, translator: translator, japaneseClipVerifier: verifier, sourceLanguage: source, targetLanguage: target)
    }

    var usesSharedGemmaForLiveSubtitles: Bool {
        guard let recognizer = speechRecognizer as? GemmaSpeechRecognizer, let cachedTranslator else { return false }
        return recognizer.engine === cachedTranslator && cachedRoutingIndex == nil
    }
    func makeSubtitleServices() async throws -> ClipServices {
        guard !isBusy else { throw ClipError.message("请先停止同传。") }
        try await prepareServices()
        guard let speechRecognizer else { throw ServiceError.invalidResponse }
        return ClipServices(recognizer: speechRecognizer, translator: textTranslator ?? OriginalTextTranslator(), sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    private func prepareServices() async throws {
        guard var asr = profiles.first(where: { $0.id == selectedASRProfileID }) else { throw ServiceError.invalidResponse }
        if let issue = recognitionLanguageIssue { throw ClipError.message(issue) }
        asr.sourceLanguage = sourceLanguage.name
        sessionProfile = nil
        sessionASRProfile = asr
        if asr.kind == .local {
            speechRecognizer = try await localRecognizer(for: asr, language: sourceLanguage)
        } else {
            _ = try asr.validatedBaseURL()
            speechRecognizer = OpenAICompatibleSpeechRecognizer(profile: asr, apiKey: try credential(for: asr))
        }
        if originalOnly { textTranslator = nil }
        else {
            guard var mt = profiles.first(where: { $0.id == selectedTranslationProfileID }) else { throw ServiceError.invalidResponse }
            mt.sourceLanguage = sourceLanguage.name; mt.targetLanguage = targetLanguage.name
            sessionProfile = mt
            textTranslator = try await translator(for: mt)
        }
    }

    func process(_ samples: [Float], start: Double, queueTranslation: Bool = false,
                 id: UUID = UUID(), revision: Int = 1, isFinal: Bool = true, generation: UUID? = nil,
                 quietRecognitionTail: [Float] = [], continuesForcedWindow: UUID? = nil) async {
        let generation = generation ?? captionGeneration
        guard generation == captionGeneration else { return }
        guard let speechRecognizer, !samples.isEmpty else { return }
        if speechRecognizer is GemmaSpeechRecognizer,
           !gemmaDraftPolicy.shouldRecognize(id: id, sampleCount: samples.count, isFinal: isFinal, originalOnly: originalOnly) { return }
        // Silent chunks do not generate hallucinated text or billable cloud requests.
        guard samples.contains(where: { abs($0) > 0.003 }) else { status = "正在监听，等待声音…"; return }
        do {
            status = "正在识别…"
            guard revision > (captionRevisions[id] ?? 0) else { return }
            var revisionGuard = revisionGuards[id] ?? ASRRevisionGuard()
            let includeTail = isFinal && !quietRecognitionTail.isEmpty && (speechRecognizer as? MultilingualSpeechRecognizer)?.usesEnglishWhisper == true
            let decoderSamples = includeTail ? samples + quietRecognitionTail : samples
            let hypothesis = try await (isFinal ? speechRecognizer.recognizeDetailed(samples: decoderSamples) : speechRecognizer.recognizeDraft(samples: samples))
            var recognition = hypothesis
            if sourceLanguage == .english {
                recognition.text = EnglishVocalTranscript.words(in: hypothesis.text)
                if recognition.text != hypothesis.text { recognition.tokens = [] }
            }
            guard generation == captionGeneration else { return }
            guard revision > (captionRevisions[id] ?? 0) else { return }
            let end = start + Double(samples.count) / 16_000
            if queueTranslation, sourceLanguage == .english, targetLanguage.isChinese {
                let pending = speechQueue?.pendingCount ?? 0
                let music = EnglishVocalTranscript.signalsMusic(hypothesis.text)
                let automatic = recognitionOverrides[SubtitleLanguage.english.asrCode] == nil
                    && (speechRecognizer as? MultilingualSpeechRecognizer)?.usesEnglishWhisper == true
                    && sessionASRProfile?.localModelPath == nil
                if music, pending <= 1 {
                    captureEngine?.noteEnglishMusic(generation: generation)
                    if automatic { englishVocalRecognition.noteMusic(endingAt: end, models: localModels) }
                }
                if (speechRecognizer as? MultilingualSpeechRecognizer)?.usesEnglishWhisper == true,
                   let loop = EnglishDecoderLoop(recognition.text) {
                    let prior = captions.last(where: { $0.id == id })?.original ?? ""
                    let text = try await englishVocalRecognition.recover(loop, prior: prior, samples: samples, start: start,
                        isFinal: isFinal, localWhisper: speechRecognizer, pending: { self.speechQueue?.pendingCount ?? 0 })
                    guard generation == captionGeneration, revision > (captionRevisions[id] ?? 0) else { return }
                    recognition = RecognizedSpeech(text: text, language: .english)
                } else if automatic {
                    let firstPass = recognition.text
                    recognition = try await englishVocalRecognition.refine(recognition, samples: samples, start: start,
                                                                          isFinal: isFinal, pending: { self.speechQueue?.pendingCount ?? 0 })
                    guard generation == captionGeneration, revision > (captionRevisions[id] ?? 0) else { return }
                    if firstPass != recognition.text { refinedEnglishVocalCues += 1 }
                }
            }
            if sourceLanguage == .english, !hypothesis.text.isEmpty, recognition.text.isEmpty {
                // A nonverbal final supersedes its draft. Never promote a preceding
                // spurious draft to a final cue or leave its translation in flight.
                if isFinal {
                    captionRevisions[id] = revision
                    revisionGuards[id] = nil
                    prefixConfirmations[id] = nil
                    prefixTranslations[id] = nil
                    captions.removeAll { $0.id == id && $0.isDraft }
                }
                status = "正在监听，等待说话…"
                return
            }
            let reconciliation = revisionGuard.reconcile(recognition, start: start, end: end,
                recoverShortOmissions: sourceLanguage == .japanese)
            revisionGuards[id] = isFinal ? nil : revisionGuard
            if sourceLanguage == .japanese, speechRecognizer is JapaneseWindowRecognizing,
               !reconciliation.text.isEmpty || phraseIDs[id] != nil {
                var heard = recognition
                heard.text = reconciliation.text
                heard.tokens = reconciliation.tokens
                if isFinal {
                    // Keep the confirmed transcript if optional gap verification fails.
                    if let verified = try? await revisionGuard.japaneseAgreement.verifyingAudio(in: recognition, preliminary: heard,
                        samples: samples, start: start, recognize: { try await speechRecognizer.recognizeDetailed(samples: $0) }) {
                        heard = verified
                    }
                    guard generation == captionGeneration, revision > (captionRevisions[id] ?? 0) else { return }
                }
                onJapaneseHypothesis?(id, start, end, isFinal, recognition, heard.text)
                let phrases = JapaneseCaptionPhrase.split(heard, duration: end - start,
                    forTranslation: isFinal && !originalOnly && targetLanguage.isChinese)
                await updatePhrases(phrases, id: id, revision: revision, final: isFinal,
                    start: start, duration: end - start, live: queueTranslation, generation: generation,
                    continuesForcedWindow: continuesForcedWindow)
                return
            }
            // Full-window ASR revisions are corrections, not a manual approval gate.
            // Preserve every hypothesis in history and immediately translate the latest.
            let recognized = reconciliation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if sourceLanguage.isChinese {
                let phrases = ChineseCaptionPhrases.split(
                    .init(text: recognized, tokens: reconciliation.tokens), duration: end - start, language: sourceLanguage)
                if phrases.count > 1 || phraseIDs[id] != nil {
                    await updatePhrases(phrases, id: id, revision: revision, final: isFinal, start: start,
                        duration: end - start, live: queueTranslation, generation: generation, continuesForcedWindow: nil)
                    return
                }
            }
            let transcript = recognized.isEmpty && isFinal
                ? (captions.first(where: { $0.id == id })?.original ?? "") : recognized
            guard !transcript.isEmpty else { status = "正在监听，等待说话…"; return }
            let detectedLanguage: SubtitleLanguage? = sourceLanguage
            let translationSource = LiveLanguageRouting.translationSource(text: transcript, detected: detectedLanguage)
            let outputLanguage = targetLanguage
            var cueStart = start
            var original: String
            if translationSource == SubtitleLanguage.english.name && outputLanguage.isChinese {
                // A new chronological cue can read its immediate predecessor without
                // searching the entire session. Revisions reuse the same position.
                let index = start >= (captions.last?.end ?? 0) && captions.last?.id != id
                    ? captions.endIndex : captions.lastIndex { $0.id == id } ?? captions.endIndex
                let previous = EnglishCaptionContinuity.previous(in: captions, before: index, startingAt: start,
                    sessionStart: sessionFirstCaptionIndex, target: outputLanguage, recognitionPending: { revisionGuards[$0] != nil })
                original = EnglishClockNotation.source(transcript, previous: previous.last?.original)
                if isFinal, !originalOnly, index > sessionFirstCaptionIndex, index <= captions.count {
                    let preceding = captions[index - 1]
                    if preceding.targetLanguage == outputLanguage, captionRevisions[preceding.id] != nil,
                       revisionGuards[preceding.id] == nil, !preceding.isOriginalOnly, !preceding.recognitionNeedsReview,
                       let joined = EnglishVocalTranscript.joined(previous: preceding, current: original, start: start, end: end) {
                        original = joined
                        cueStart = preceding.start
                        captionRevisions[preceding.id] = nil
                        prefixConfirmations[preceding.id] = nil
                        prefixTranslations[preceding.id] = nil
                        captions.remove(at: index - 1)
                    }
                }
            } else {
                original = transcript
            }
            captionRevisions[id] = revision
            if let index = captions.firstIndex(where: { $0.id == id }) {
                captions[index].sourceLanguage = detectedLanguage ?? sourceLanguage
                captions[index].targetLanguage = outputLanguage
                let previous = captions[index].original
                if previous != original && !previous.isEmpty {
                    captions[index].originalRevisions.append(previous)
                }
                if reconciliation.restored { captions[index].originalRevisions.append("本次识别候选：" + recognition.text) }
                captions[index].recognitionNotice = reconciliation.restored
                    ? "已恢复连续识别一致、且音频时间戳支持的遗漏前段。原始候选保留在修订记录中。"
                    : previous.count - original.count >= 6
                    ? "识别结果比上一版缩短，旧文字已保留在原文修订记录中，可检查是否遗漏。" : ""
                captions[index].pendingOriginal = nil
                captions[index].recognitionNeedsReview = false
                captions[index].original = original
                captions[index].start = cueStart
                captions[index].end = end
                captions[index].isDraft = true
                if isFinal || !original.hasPrefix(captions[index].confirmedPrefix) { captions[index].confirmedPrefix = "" }
            } else {
                captions.append(Caption(id: id, start: cueStart, end: end, original: original, translated: "", isDraft: true, sourceLanguage: detectedLanguage ?? sourceLanguage, targetLanguage: outputLanguage))
            }
            if queueTranslation, firstOriginalLatency == nil { firstOriginalLatency = Date().timeIntervalSince(sessionStart) }
            if originalOnly {
                if let index = captions.firstIndex(where: { $0.id == id }) {
                    captions[index].translated = ""
                    captions[index].isDraft = !isFinal
                }
                status = isFinal ? "原文已确认" : "正在识别原文…"
                return
            }
            // Translate agreed clauses while ASR continues; always correct from the complete final source.
            guard isFinal else {
                if stablePrefixesEnabled {
                    var confirmation = prefixConfirmations[id] ?? StablePrefixConfirmation()
                    let englishClauses = translationSource == SubtitleLanguage.english.name && outputLanguage.isChinese
                    let canPreview = !queueTranslation || (!isStopping && !translatingFinal && translationQueue?.pendingCount == 0)
                    let prefix = canPreview ? confirmation.observe(original, samples: samples.count, englishClauses: englishClauses) : nil
                    prefixConfirmations[id] = confirmation
                    if let prefix, let i = captions.firstIndex(where: { $0.id == id }) { captions[i].confirmedPrefix = prefix }
                    if let saved = prefixTranslations[id], !original.hasPrefix(saved.source) {
                        prefixTranslations[id] = nil
                        if let i = captions.firstIndex(where: { $0.id == id }) { captions[i].translated = "" }
                    }
                    if let prefix, englishClauses || textTranslator?.requiresFullUtterance == false {
                        let item = TranslationSegment(id: id, revision: revision, isFinal: false,
                            original: prefix, source: translationSource, target: outputLanguage.name, live: queueTranslation, generation: generation)
                        if queueTranslation {
                            scheduleTranslationPreview(item)
                        } else { await translateCaption(item) }
                    }
                }
                guard generation == captionGeneration, captionRevisions[id] == revision else { return }
                let waitingForFinal = textTranslator?.requiresFullUtterance == true && !(sourceLanguage == .english && outputLanguage.isChinese && stablePrefixesEnabled)
                status = waitingForFinal ? "正在确认原文 · 等待完整语句" : "原文草稿 · 继续监听"
                return
            }
            if let index = captions.firstIndex(where: { $0.id == id }) {
                if let saved = prefixTranslations[id], original.hasPrefix(saved.source) { captions[index].translated = saved.chinese + " …" }
                else { captions[index].translated = "正在翻译…" }
            }
            let item = TranslationSegment(id: id, revision: revision, isFinal: isFinal,
                original: original, source: translationSource, target: outputLanguage.name, live: queueTranslation, generation: generation)
            if queueTranslation {
                cancelTranslationPreview()
                if let queue = translationQueue, case .overflow = queue.offer(item) {
                    handleProcessingOverload()
                    // Keep the ASR producer suspended with this final until the bounded queue drains.
                    _ = await Task.detached { queue.offerPreservingFinal(item, onFull: {}) }.value
                }
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
                    captions[index].recognitionNotice = "整句识别失败，已保留原文草稿与修订记录。"
                }
            }
            status = "识别失败：\(error.localizedDescription)"
        }
    }

    // Preserve row identities as a growing ASR window changes its phrase boundaries.
    private func updatePhrases(_ recognizedPhrases: [TimedCaptionPhrase], id: UUID, revision: Int, final: Bool,
                               start: Double, duration: Double, live: Bool, generation: UUID, continuesForcedWindow: UUID?) async {
        var ids = phraseIDs[id] ?? [id]
        var phrases = recognizedPhrases
        if phrases.isEmpty {
            guard final else { return }
            phrases = ids.compactMap { key in
                captions.first(where: { $0.id == key }).map {
                    TimedCaptionPhrase(text: $0.original, start: $0.start - start, end: $0.end - start)
                }
            }
        }
        for key in ids.dropFirst(phrases.count) {
            captions.removeAll { $0.id == key }
            captionRevisions[key] = nil
            prefixTranslations[key] = nil
            revisionGuards[key] = nil
        }
        ids = Array(ids.prefix(phrases.count))
        while ids.count < phrases.count { ids.append(UUID()) }
        phraseIDs[id] = final ? nil : ids
        captionRevisions[id] = revision
        let previousTail = japaneseFinalTail
        let predecessor = sourceLanguage == .japanese && final && previousTail?.window == continuesForcedWindow
            && previousTail?.generation == generation && previousTail?.app == selectedAppBundleID ? previousTail?.cue : nil
        if final, sourceLanguage == .japanese {
            japaneseFinalTail = ids.last.map { (id, $0, generation, selectedAppBundleID) }
        }
        var pending: [TranslationSegment] = []
        for (key, phrase) in zip(ids, phrases) {
            let index: Int
            if let old = captions.lastIndex(where: { $0.id == key }) {
                index = old
                if captions[index].original != phrase.text {
                    captions[index].originalRevisions.append(captions[index].original)
                    captions[index].translated = ""
                    prefixTranslations[key] = nil
                }
                captions[index].original = phrase.text
                if final { captions[index].confirmedPrefix = "" }
                captions[index].start = start + phrase.start
                captions[index].end = start + phrase.end
            } else {
                index = captions.count
                captions.append(Caption(id: key, start: start + phrase.start, end: start + phrase.end,
                    original: phrase.text, translated: "", isDraft: true, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage))
            }
            captionRevisions[key] = revision
            if final { revisionGuards[key] = nil; prefixConfirmations[key] = nil }
            else if key != id { revisionGuards[key] = ASRRevisionGuard() }
            captions[index].isDraft = true
            if originalOnly {
                // A Japanese phrase may already have a translation preview from
                // before the switch. Its source-only final must stay exportable
                // as original text when the panel later returns to bilingual.
                captions[index].translated = ""
                captions[index].isDraft = !final
                continue
            }
            let joinID = key == ids.first && targetLanguage.isChinese ? predecessor.flatMap { previousID in
                captions.last(where: { $0.id == previousID }).flatMap {
                    JapaneseCaptionPhrase.completesLocation($0.original, phrase.text) ? previousID : nil
                }
            } : nil
            if joinID == nil, let saved = prefixTranslations[key], saved.source == phrase.text {
                if final {
                    captions[index].translated = saved.chinese
                    captions[index].isDraft = false
                    prefixTranslations[key] = nil
                }
                continue
            }
            let previewable = sourceLanguage == .japanese || (stablePrefixesEnabled && textTranslator?.requiresFullUtterance == false && key != ids.last)
            if final || previewable && phrase.text.count >= 3 && duration >= 2.4 {
                pending.append(TranslationSegment(id: key, revision: revision, isFinal: final, original: phrase.text,
                    source: sourceLanguage == .japanese ? sourceLanguage.name : LiveLanguageRouting.translationSource(text: phrase.text, detected: sourceLanguage),
                    target: targetLanguage.name, live: live, generation: generation,
                    japanesePredecessor: joinID, japaneseSourceApp: selectedAppBundleID))
            }
        }
        if live, firstOriginalLatency == nil, !phrases.isEmpty { firstOriginalLatency = Date().timeIntervalSince(sessionStart) }
        if !final {
            if let preview = pending.last {
                if live { scheduleTranslationPreview(preview) } else { await translateCaption(preview) }
            }
            return
        }
        // Exact early translations can be committed directly. Changed rows use
        // the normal serialized final queue and its backpressure.
        if live { cancelTranslationPreview() }
        for item in pending {
            guard generation == captionGeneration else { return }
            if let queue = live ? translationQueue : nil {
                if case .overflow = queue.offer(item) {
                    handleProcessingOverload()
                    _ = await Task.detached { queue.offerPreservingFinal(item, onFull: {}) }.value
                }
            } else { await translateCaption(item) }
        }
        if live, firstFinalTranslationLatency == nil, ids.contains(where: { key in
            captions.contains(where: { $0.id == key && !$0.isDraft && !$0.translated.isEmpty })
        }) { firstFinalTranslationLatency = Date().timeIntervalSince(sessionStart) }
    }

    private func joinJapaneseFinal(_ item: TranslationSegment, using translator: any TextTranslating) async {
        guard let previousID = item.japanesePredecessor, sourceLanguage == .japanese, targetLanguage.isChinese,
              targetLanguage.name == item.target, !originalOnly, selectedAppBundleID == item.japaneseSourceApp,
              let index = captions.firstIndex(where: { $0.id == item.id }), index > sessionFirstCaptionIndex else { return }
        let left = captions[index - 1], right = captions[index]
        guard left.id == previousID, !left.isDraft, !right.isDraft, !left.recognitionNeedsReview, !right.recognitionNeedsReview,
              left.sourceLanguage == .japanese, right.sourceLanguage == .japanese,
              left.targetLanguage == right.targetLanguage, right.targetLanguage == targetLanguage,
              SubtitleDocument.completedTranslation(left) != nil, SubtitleDocument.completedTranslation(right) != nil,
              (-0.035...0.22).contains(right.start - left.end), right.end - left.start <= 9.5,
              left.original.count + right.original.count <= 36, JapaneseCaptionPhrase.completesLocation(left.original, right.original)
        else { return }
        let joined = left.original + right.original
        guard let chinese = try? await translator.translate(joined, from: item.source, to: item.target,
            context: .init(previous: [], isFinal: true)).trimmingCharacters(in: .whitespacesAndNewlines),
              !chinese.isEmpty, !Task.isCancelled, item.generation == captionGeneration, !originalOnly,
              selectedAppBundleID == item.japaneseSourceApp, sourceLanguage == .japanese, targetLanguage == right.targetLanguage,
              captionRevisions[item.id] == item.revision,
              let position = captions.firstIndex(where: { $0.id == item.id }), position > sessionFirstCaptionIndex,
              captions[position - 1] == left, captions[position] == right else { return }
        // Keep both valid translations visible through failure/cancellation. Commit
        // their replacement as one snapshot only after both originals still match.
        var combined = right
        combined.start = left.start
        combined.original = joined
        combined.translated = chinese
        combined.originalRevisions = left.originalRevisions + [left.original] + right.originalRevisions + [right.original]
        captionRevisions.removeValue(forKey: left.id)
        captions.replaceSubrange((position - 1)...position, with: [combined])
    }

    func startLiveTranslationWorker(capacity: Int = 24) {
        let queue = CaptionRevisionQueue<TranslationSegment>(capacity: capacity, finalsFirst: true)
        translationQueue = queue
        translationTask = Task { [weak self] in
            for await _ in queue.wakeups {
                while let item = queue.take(), let self {
                    self.translatingFinal = true
                    let work = Task { await self.translateCaption(item) }
                    self.activeFinalTranslation = work
                    await work.value
                    self.activeFinalTranslation = nil
                    self.translatingFinal = false
                }
            }
        }
    }

    func finishLiveTranslationWorker() async {
        cancelTranslationPreview()
        translationQueue?.finish()
        await translationTask?.value
        translationQueue = nil
        translationTask = nil
    }

    private func cancelTranslationPreview() {
        pendingPreview = nil
        previewTask?.cancel()
    }

    private func scheduleTranslationPreview(_ item: TranslationSegment) {
        guard !isStopping, !translatingFinal, translationQueue?.pendingCount == 0 else { return }
        pendingPreview = item
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let preview = self.pendingPreview {
                self.pendingPreview = nil
                await self.translateCaption(preview)
            }
            self.previewTask = nil
            if let next = self.pendingPreview { self.scheduleTranslationPreview(next) }
        }
    }

    private func translateCaption(_ item: TranslationSegment) async {
        // A pending newer source revision makes this work obsolete. Final revisions
        // are queued separately and cannot be overwritten by a stale draft result.
        guard item.generation == captionGeneration else { return }
        if item.isFinal { guard captionRevisions[item.id] == item.revision else { return } }
        else { guard revisionGuards[item.id] != nil, captions.contains(where: { $0.id == item.id && $0.isDraft && $0.original.hasPrefix(item.original) }) else { return } }
        if originalOnly {
            if let index = captions.firstIndex(where: { $0.id == item.id }), item.isFinal {
                captions[index].translated = ""; captions[index].isDraft = false
            }
            return
        }
        do {
            if textTranslator == nil {
                guard let profile = profiles.first(where: { $0.id == selectedTranslationProfileID }) else { throw ServiceError.invalidResponse }
                textTranslator = try await translator(for: profile)
            }
            guard let textTranslator else { throw ServiceError.invalidResponse }
            guard let index = captions.lastIndex(where: { $0.id == item.id }) else { return }
            let currentStart = captions[index].start
            let target = SubtitleLanguage.resolve(item.target)
            let englishToChinese = item.source == SubtitleLanguage.english.name && target?.isChinese == true
            let previous: [SubtitleTranslationContext.Line]
            if englishToChinese, let target {
                previous = EnglishCaptionContinuity.previous(in: captions, before: index, startingAt: currentStart,
                    sessionStart: sessionFirstCaptionIndex, target: target, recognitionPending: { revisionGuards[$0] != nil })
            } else {
                let eligible = captions.dropFirst(sessionFirstCaptionIndex).filter {
                    $0.id != item.id && !$0.isDraft && !$0.isOriginalOnly && $0.end <= currentStart + 0.001
                        && $0.targetLanguage == target
                }.sorted { $0.start < $1.start }
                previous = eligible.suffix(2).map {
                    .init(original: $0.original, translated: SubtitleDocument.completedTranslation($0) ?? "",
                          sourceLanguage: LiveLanguageRouting.translationSource(text: $0.original, detected: $0.sourceLanguage))
                }
            }
            var context = SubtitleTranslationContext(previous: previous, isFinal: true)
            context.isStablePrefix = !item.isFinal
            let incremental = !item.isFinal && englishToChinese
            let previousPreview = incremental ? prefixTranslations[item.id] : nil
            let matchingPreview = previousPreview.flatMap { item.original.hasPrefix($0.source) ? $0 : nil }
            var source = item.original
            if let matchingPreview {
                source = String(item.original.dropFirst(matchingPreview.source.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { return }
                context.previous.append(.init(original: matchingPreview.source, translated: matchingPreview.chinese, sourceLanguage: item.source))
            }
            let parts = englishToChinese
                ? try EnglishTranslationChunks.split(source) : [source]
            var translations: [String] = []
            for part in parts {
                try Task.checkCancellation()
                if englishToChinese {
                    let adjacent = context.previous.last
                    context.adjacentEnglishSource = adjacent?.original
                    context.adjacentEnglishTranslation = adjacent?.translated
                }
                let result = try await textTranslator.translate(part, from: item.source, to: item.target, context: context)
                let piece: String
                if englishToChinese {
                    let clock = EnglishClockNotation.translation(result, source: part)
                    let repaired = EnglishLagMeasurement.repairAgeUnit(in: clock, original: part, preceding: context.adjacentEnglishSource)
                    piece = repaired == clock ? clock : (target?.normalizeScript(repaired) ?? repaired)
                } else { piece = result }
                try Task.checkCancellation()
                guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.emptyResponse }
                translations.append(piece)
                if parts.count > 1 {
                    context.previous = Array((context.previous + [.init(original: part, translated: piece, sourceLanguage: item.source)]).suffix(2))
                }
            }
            let translated = translations.joined(separator: "\n")
            guard item.generation == captionGeneration else { return }
            guard !originalOnly, captions.first(where: { $0.id == item.id })?.isOriginalOnly != true else { return }
            if item.isFinal { guard captionRevisions[item.id] == item.revision else { return } }
            else { guard revisionGuards[item.id] != nil, captions.contains(where: { $0.id == item.id && $0.isDraft && $0.original.hasPrefix(item.original) }) else { return } }
            guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.emptyResponse }
            if incremental, prefixTranslations[item.id]?.source != previousPreview?.source { return }
            let assembled = matchingPreview.map { $0.chinese + "\n" + translated } ?? translated
            if let index = captions.firstIndex(where: { $0.id == item.id }) {
                captions[index].translated = assembled + (item.isFinal ? "" : " …")
                captions[index].isDraft = !item.isFinal
                if !item.isFinal { prefixTranslations[item.id] = (item.original, assembled) }
                else { prefixTranslations[item.id] = nil; prefixConfirmations[item.id] = nil }
            }
            if item.live {
                let elapsed = Date().timeIntervalSince(sessionStart)
                if firstTranslationLatency == nil { firstTranslationLatency = elapsed }
                if item.isFinal {
                    if firstFinalTranslationLatency == nil { firstFinalTranslationLatency = elapsed }
                } else if firstPreviewTranslationLatency == nil { firstPreviewTranslationLatency = elapsed }
            }
            status = item.isFinal ? "整句字幕已校订 · \(captions.count) 条" : "字幕草稿 · 说话结束后会自动校订"
            if item.japanesePredecessor != nil { await joinJapaneseFinal(item, using: textTranslator) }
        } catch {
            guard !Task.isCancelled, item.generation == captionGeneration, captionRevisions[item.id] == item.revision, !originalOnly, captions.first(where: { $0.id == item.id })?.isOriginalOnly != true else { return }
            if !item.isFinal { status = "提前翻译未完成，将在定稿后重试"; return }
            prefixConfirmations[item.id] = nil; prefixTranslations[item.id] = nil
            if let index = captions.firstIndex(where: { $0.id == item.id }) { captions[index].translated = "翻译失败：\(error.localizedDescription)" }
            status = "已保留原文，翻译失败：\(error.localizedDescription)"
        }
    }

    func retryTranslation(_ id: UUID) async {
        guard let cue = captions.first(where: { $0.id == id }), !cue.original.isEmpty else { return }
        let generation = captionGeneration
        do {
            if textTranslator == nil {
                guard let profile = profiles.first(where: { $0.id == selectedTranslationProfileID && $0.isEnabled }) else { throw ServiceError.invalidResponse }
                textTranslator = try await translator(for: profile)
            }
            guard generation == captionGeneration, let index = captions.firstIndex(where: { $0.id == id }) else { return }
            let revision = (captionRevisions[id] ?? 0) + 1
            captionRevisions[id] = revision
            captions[index].translated = "正在翻译…"
            captions[index].pendingOriginal = nil; captions[index].recognitionNeedsReview = false
            await translateCaption(.init(id: id, revision: revision, isFinal: true, original: cue.original,
                source: LiveLanguageRouting.translationSource(text: cue.original, detected: cue.sourceLanguage), target: cue.targetLanguage.name, live: false, generation: generation))
        } catch { errorMessage = error.localizedDescription }
    }

    func resolveRecognition(_ id: UUID, useCandidate: Bool) async {
        guard let snapshot = captions.first(where: { $0.id == id }), snapshot.recognitionNeedsReview,
              let candidate = snapshot.pendingOriginal else { return }
        guard !useCandidate || !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let generation = captionGeneration
        let revision = captionRevisions[id] ?? 0
        do {
            if textTranslator == nil {
                guard let profile = profiles.first(where: { $0.id == selectedTranslationProfileID && $0.isEnabled }) else { throw ServiceError.invalidResponse }
                textTranslator = try await translator(for: profile)
            }
            guard generation == captionGeneration, revision == captionRevisions[id],
                  let index = captions.firstIndex(where: { $0.id == id }) else { return }
            let chosen = useCandidate ? candidate : snapshot.original
            captions[index].originalRevisions.append("回退候选：" + candidate)
            if useCandidate { captions[index].originalRevisions.append(snapshot.original) }
            captions[index].original = chosen
            captions[index].pendingOriginal = nil; captions[index].recognitionNeedsReview = false
            captions[index].recognitionNotice = "已由用户核对原文"
            captions[index].translated = "正在翻译…"
            captionRevisions[id] = revision + 1
            await translateCaption(.init(id: id, revision: revision + 1, isFinal: true, original: chosen,
                source: LiveLanguageRouting.translationSource(text: chosen, detected: snapshot.sourceLanguage), target: snapshot.targetLanguage.name, live: false, generation: generation))
            if generation == captionGeneration, captionRevisions[id] == revision + 1,
               let failedIndex = captions.firstIndex(where: { $0.id == id }), captions[failedIndex].isDraft {
                captions[failedIndex].pendingOriginal = chosen
                captions[failedIndex].recognitionNeedsReview = true
                captions[failedIndex].recognitionNotice = "已保存核对后的原文，翻译未完成；可点击保留原文并翻译重试。"
            }
        } catch { errorMessage = "核对后翻译未启动：" + error.localizedDescription }
    }

    private func handleProcessingOverload() {
        guard !stoppingForBacklog else { return }
        stoppingForBacklog = true
        stopCapture()
        errorSection = .services
        errorMessage = L10n.text("识别或翻译持续慢于直播，已暂停采集。已接收的语音和定稿将按顺序处理，完成后可以重新开始。")
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
        panel.message = "导入音频；本地人声处理后，按说话停顿分段并翻译。"
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
                    let options = SubtitleProcessingOptions(suppressMusic: self.suppressBackgroundMusic, showDrafts: false,
                        japanesePhraseBoundaries: self.sourceLanguage == .japanese && !(self.speechRecognizer is ReazonSpeechRecognizer))
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
                            id: segment.id, revision: segment.revision, continuesForcedWindow: segment.continuesForcedWindow)
                    }
                    self.status = "音频处理完成 · \(self.captions.count) 条字幕"
                } catch { self.report(error, prefix: "音频处理失败") }
            }
        }
    }

    func exportCaptions(format: SubtitleExportFormat = .srt) {
        guard !captions.isEmpty else { return }
        // Snapshot both the text and language choice before opening the save dialog.
        let text = SubtitleDocument.render(captions.map(SubtitleDocument.liveCaption), format: format, mode: subtitleDisplayMode)
        guard !text.isEmpty else {
            errorMessage = "暂时没有已定稿的译文。说话结束并校订后即可导出；临时草稿不会写入文档。"
            return
        }
        let floating = isSubtitleOnly ? NSApp.windows.first { $0 is SubtitleFloatingPanel && $0.isVisible } : nil
        SubtitleSavePanel.present(format: format, suggestedName: "SimuSub", from: floating ?? NSApp.mainWindow) { [weak self] url in
            guard let self else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.status = "\(format.title) 字幕已导出"
            } catch { self.report(error, prefix: "字幕导出失败") }
        }
    }

    static func srt(_ captions: [Caption]) -> String {
        SubtitleDocument.render(captions.map(SubtitleDocument.liveCaption), format: .srt, mode: .bilingual)
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
    var japanesePredecessor: UUID? = nil
    var japaneseSourceApp: String? = nil
}
