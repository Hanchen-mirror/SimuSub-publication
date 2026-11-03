import AppKit
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class CapturePermissionCenter: ObservableObject {
    @Published private(set) var screenGranted = false
    @Published private(set) var isRequesting = false
    @Published private(set) var isRepairing = false
    @Published private(set) var screenAccessError = ""
    @Published var notice = ""
    @Published var needsResetConfirmation = false

    private let readScreen: () -> Bool
    private let probeScreen: () async throws -> Void
    private var verifiedScreenAccess = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mirror.simusub", category: "permissions")

    static var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SimuSub"
    }

    init(readScreen: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         probeScreen: @escaping () async throws -> Void = { _ = try await AudioCaptureEngine.shareableContent() }) {
        self.readScreen = readScreen
        self.probeScreen = probeScreen
    }

    func refresh() {
        screenGranted = screenAccessError.isEmpty && (readScreen() || verifiedScreenAccess)
    }

    func authorizeScreen() async throws {
        guard !isRequesting, !isRepairing else { throw CapturePermissionError.screenRequestInProgress }
        isRequesting = true
        defer { isRequesting = false }
        do {
            // ScreenCaptureKit is the authority used by the actual capture path.
            // A negative legacy preflight must not block its own consent request.
            try await probeScreen()
            verifiedScreenAccess = true
            screenGranted = true
            screenAccessError = ""
            logger.info("ScreenCaptureKit application access verified")
        } catch {
            verifiedScreenAccess = false
            screenGranted = false
            let underlying = error as NSError
            screenAccessError = "\(underlying.domain)（\(underlying.code)）：\(error.localizedDescription)"
            logger.error("ScreenCaptureKit access failed: \(self.screenAccessError, privacy: .public)")
            throw CapturePermissionError.screenAccessFailed(screenAccessError)
        }
    }

    func requestScreenFromUI() {
        guard !isRequesting, !isRepairing else { return }
        Task {
            notice = "正在检查应用音频访问，请处理系统授权弹窗。"
            do { try await authorizeScreen(); notice = "应用音频访问已验证，可以选择应用。" }
            catch { notice = error.localizedDescription }
        }
    }

    func repairScreenFromUI() {
        guard !isRequesting, !isRepairing else { return }
        isRepairing = true
        Task {
            defer { isRepairing = false }
            notice = "正在检查应用音频访问…"
            do {
                try await probeScreen()
                verifiedScreenAccess = true
                screenGranted = true
                screenAccessError = ""
                notice = "音频权限正常，无需重置。可以返回字幕选择应用。"
            } catch {
                verifiedScreenAccess = false
                screenGranted = false
                let detail = error as NSError
                screenAccessError = "\(detail.domain)（\(detail.code)）：\(error.localizedDescription)"
                if readScreen() {
                    notice = "系统开关已开启，但当前访问仍失败。可以重新打开应用；旧记录失效时可重置本应用授权。"
                    needsResetConfirmation = true
                } else {
                    notice = "已打开系统设置，请开启「\(Self.applicationName)」的录制权限；按系统提示重新打开应用。"
                    openSettings()
                }
            }
        }
    }

    func resetScreenFromUI() {
        guard !isRequesting, !isRepairing else { return }
        isRepairing = true
        Task {
            defer { isRepairing = false }
            do {
                notice = "正在重置本应用的旧音频授权…"
                try await PermissionRecovery.resetApplicationAudio()
                verifiedScreenAccess = false
                screenGranted = false
                screenAccessError = ""
                try PermissionRecovery.relaunch(arguments: ["--show-subtitle-settings", "--request-audio-access"])
            } catch { notice = error.localizedDescription }
        }
    }

    func openSettings() {
        let pane = "Privacy_ScreenCapture"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        if !NSWorkspace.shared.open(url) { notice = "请手动打开系统设置 → 隐私与安全性 → 屏幕与系统音频录制。" }
    }

    /// Setup only reads consent. It never probes audio or reuses an old session grant.
    func refreshSetupConsent() {
        screenGranted = readScreen()
        if screenGranted { screenAccessError = "" }
    }

    func openSetupSettings() {
        // Register this signed application in TCC on the user's explicit button press.
        if !readScreen() { _ = CGRequestScreenCaptureAccess() }
        openSettings()
        refreshSetupConsent()
    }

    func restartApplication() {
        do { try PermissionRecovery.relaunch() }
        catch { notice = "重新打开失败：\(error.localizedDescription)" }
    }

    var snapshot: [String: Any] {
        ["screenCaptureGranted": screenGranted,
         "applicationName": Self.applicationName, "shareableContentVerified": verifiedScreenAccess,
         "screenAccessError": screenAccessError,
         "bundleIdentifier": Bundle.main.bundleIdentifier ?? "", "bundlePath": Bundle.main.bundleURL.path]
    }
}

enum CapturePermissionError: LocalizedError {
    case screenNotGranted, screenRequestInProgress
    case screenAccessFailed(String)
    private var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "SimuSub"
    }
    var errorDescription: String? {
        switch self {
        case .screenNotGranted: "应用音频尚未获授权。请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中开启「\(applicationName)」。如果系统要求退出并重新打开，请点击「重新打开应用」。"
        case .screenRequestInProgress: "应用音频授权检查或修复正在进行，请处理系统弹窗。"
        case .screenAccessFailed(let detail): "应用音频访问失败。请到「字幕设置」点击扳手检查，或点击门图标打开系统录制权限设置。系统返回：\(detail)"
        }
    }
}
