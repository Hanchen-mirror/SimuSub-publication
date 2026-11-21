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

@MainActor
final class OnboardingState: ObservableObject {
    let model: AppModel
    let permissions: CapturePermissionCenter
    private var permissionChanges: AnyCancellable?

    init(model: AppModel, permissions: CapturePermissionCenter? = nil) {
        self.model = model
        self.permissions = permissions ?? model.permissions
        permissionChanges = self.permissions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func refreshPermission() {
        permissions.refreshSetupConsent()
    }

    func finish(at destination: WorkspaceDestination, navigate: (WorkspaceDestination) -> Void) {
        switch destination {
        case .subtitle:
            refreshPermission()
            guard permissions.screenGranted else { return }
        case .clips: break
        default: return
        }
        navigate(destination)
        model.completeOnboarding()
    }
}
