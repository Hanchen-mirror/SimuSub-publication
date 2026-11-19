import AppKit
import Combine
import Foundation

/// A download can span several ASR files; pause carries across file boundaries.
final class ModelDownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var downloader: ModelDownloader?
    private var paused = false
    func attach(_ downloader: ModelDownloader) {
        lock.lock(); defer { lock.unlock() }
        self.downloader = downloader
        downloader.setPaused(paused)
    }
    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        downloader?.setPaused(value)
    }
}

enum SetupStep { case permissions, models }
enum SetupDownloadPhase { case checking, pending, downloading, paused, cancelling, complete, failed }
struct SetupDownloadState {
    var phase: SetupDownloadPhase = .checking
    var fraction: Double = 0
    var error = ""
    var canRetry = true
    var label: String {
        switch phase {
        case .checking: return "校验中"
        case .pending: return "待下载"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .cancelling: return "取消中"
        case .complete: return "已完成"
        case .failed: return "未完成"
        }
    }
}

@MainActor
final class OnboardingState: ObservableObject {
    @Published var step: SetupStep = .permissions
    @Published private(set) var downloads: [ServicePurpose: SetupDownloadState] = [:]
    @Published private(set) var testing: Set<UUID> = []
    @Published private(set) var connectionErrors: [UUID: String] = [:]
    @Published private(set) var verifiedProfiles: [UUID: ServiceProfile] = [:]
    private var tasks: [ServicePurpose: Task<Void, Never>] = [:]
    private var controls: [ServicePurpose: ModelDownloadControl] = [:]
    private var requestIDs: [ServicePurpose: UUID] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var checking = false
    private var connectionRevisions: [UUID: UUID] = [:]
    let model: AppModel
    let permissions: CapturePermissionCenter
    let downloadsAllowed: Bool
    private let connectionCheck: (ServiceProfile) async throws -> Void

    init(model: AppModel, permissions: CapturePermissionCenter? = nil,
         downloadsAllowed: Bool = !AppLaunchOptions.isDiagnostic,
         connectionCheck: ((ServiceProfile) async throws -> Void)? = nil) {
        self.model = model
        self.permissions = permissions ?? model.permissions
        self.downloadsAllowed = downloadsAllowed
        self.connectionCheck = connectionCheck ?? { try await model.checkSetupConnection(for: $0) }
        for purpose in ServicePurpose.allCases { downloads[purpose] = SetupDownloadState() }
        model.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        self.permissions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    }

    func profile(for purpose: ServicePurpose) -> ServiceProfile? {
        let id = purpose == .speechRecognition ? model.selectedASRProfileID : model.selectedTranslationProfileID
        return model.profiles.first { $0.id == id && $0.purpose == purpose }
    }
    func select(_ kind: ServiceKind, for purpose: ServicePurpose) {
        guard permissions.screenGranted else { return }
        guard let profile = model.profiles.first(where: { $0.kind == kind && $0.purpose == purpose }) else { return }
        if purpose == .speechRecognition { model.selectedASRProfileID = profile.id }
        else { model.selectedTranslationProfileID = profile.id }
    }
    func ready(_ purpose: ServicePurpose) -> Bool {
        guard let profile = profile(for: purpose) else { return false }
        if profile.kind == .local { return downloads[purpose]?.phase == .complete }
        return verifiedProfiles[profile.id] == profile && !testing.contains(profile.id)
    }
    var canFinish: Bool {
        permissions.screenGranted && ServicePurpose.allCases.allSatisfy(ready)
            && tasks.isEmpty && testing.isEmpty
    }
    func advance() {
        permissions.refreshSetupConsent()
        if permissions.screenGranted { step = .models }
    }
    func finish() {
        permissions.refreshSetupConsent()
        guard canFinish else { return }
        model.refreshModels()
        model.completeOnboarding()
    }
    func refreshPermission() {
        permissions.refreshSetupConsent()
        if !permissions.screenGranted { step = .permissions }
    }
    func checkLocalModels() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        for purpose in ServicePurpose.allCases where tasks[purpose] == nil {
            downloads[purpose] = SetupDownloadState()
            do {
                let exists = try await model.modelStore.verifyInstalled(for: purpose)
                downloads[purpose] = SetupDownloadState(phase: exists ? .complete : .pending, fraction: exists ? 1 : 0)
            } catch {
                downloads[purpose] = SetupDownloadState(phase: .failed, error: error.localizedDescription, canRetry: false)
            }
        }
        model.refreshModels()
    }
    func startDownload(_ purpose: ServicePurpose) {
        guard downloadsAllowed, permissions.screenGranted, tasks[purpose] == nil,
              let state = downloads[purpose], state.canRetry,
              state.phase == .pending || state.phase == .failed else { return }
        let control = ModelDownloadControl()
        controls[purpose] = control
        let requestID = UUID()
        requestIDs[purpose] = requestID
        downloads[purpose] = SetupDownloadState(phase: .downloading)
        tasks[purpose] = Task { [self] in
            defer { tasks[purpose] = nil; controls[purpose] = nil; requestIDs[purpose] = nil; model.refreshModels(); objectWillChange.send() }
            do {
                let progress: LocalModelStore.Progress = { [weak self] value, _ in
                    Task { @MainActor in
                        guard let self, self.requestIDs[purpose] == requestID,
                              self.downloads[purpose]?.phase == .downloading || self.downloads[purpose]?.phase == .paused else { return }
                        self.downloads[purpose]?.fraction = min(1, max(0, value))
                    }
                }
                if purpose == .speechRecognition { try await model.modelStore.downloadASR(control: control, progress: progress) }
                else { try await model.modelStore.downloadTranslation(control: control, progress: progress) }
                try Task.checkCancellation()
                guard try await model.modelStore.verifyInstalled(for: purpose) else { throw ServiceError.modelFilesMissing }
                downloads[purpose] = SetupDownloadState(phase: .complete, fraction: 1)
            } catch {
                downloads[purpose] = Task.isCancelled ? SetupDownloadState(phase: .pending)
                    : SetupDownloadState(phase: .failed, error: error.localizedDescription)
            }
        }
    }
    func togglePause(_ purpose: ServicePurpose) {
        guard let phase = downloads[purpose]?.phase, phase == .downloading || phase == .paused else { return }
        let pause = phase == .downloading
        controls[purpose]?.setPaused(pause)
        downloads[purpose]?.phase = pause ? .paused : .downloading
    }
    func cancel(_ purpose: ServicePurpose) {
        guard tasks[purpose] != nil else { return }
        downloads[purpose]?.phase = .cancelling
        tasks[purpose]?.cancel()
    }
    func invalidate(_ id: UUID) {
        connectionRevisions[id] = UUID()
        verifiedProfiles[id] = nil
        connectionErrors[id] = nil
    }
    func test(_ profile: ServiceProfile, key: String) async {
        guard !testing.contains(profile.id), permissions.screenGranted else { return }
        invalidate(profile.id)
        let revision = connectionRevisions[profile.id]
        testing.insert(profile.id)
        defer { testing.remove(profile.id) }
        do {
            guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.invalidResponse }
            _ = try profile.validatedBaseURL()
            if !key.isEmpty { try model.saveAPIKey(key, for: profile) }
            try await connectionCheck(profile)
            // Edits while a request is pending cannot approve a different configuration.
            guard connectionRevisions[profile.id] == revision, model.profiles.first(where: { $0.id == profile.id }) == profile else { return }
            verifiedProfiles[profile.id] = profile
        } catch { connectionErrors[profile.id] = error.localizedDescription }
    }
    func applyDiagnosticState(_ state: SetupDownloadState, for purpose: ServicePurpose) {
        guard !downloadsAllowed, CommandLine.arguments.contains("--onboarding-check") else { return }
        downloads[purpose] = state
    }
    func revealModels(_ purpose: ServicePurpose) {
        let url = model.modelStore.root.appendingPathComponent(purpose == .speechRecognition ? "asr-ja" : "mt")
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: url.path) ? url : model.modelStore.root])
    }
}
