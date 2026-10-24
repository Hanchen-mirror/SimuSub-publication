import AppKit
import Foundation

enum PermissionRecovery {
    static let allowedBundleIDs = ["com.mirror.simusub", "com.mirror.simusub.v2preview"]
    static func resetApplicationAudio() async throws {
        guard let identifier = Bundle.main.bundleIdentifier, allowedBundleIDs.contains(identifier) else { throw RecoveryError.invalidIdentity }
        _ = try relaunchHelper()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        // Always target this app and this single service. Never reset all apps.
        process.arguments = ["reset", "ScreenCapture", identifier]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: RecoveryError.resetFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))) }
            }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }

    @MainActor
    static func relaunch(arguments: [String] = ["--show-subtitle-settings"]) throws {
        let app = Bundle.main.bundleURL
        let helper = try relaunchHelper()
        let process = Process()
        process.executableURL = helper
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), app.path] + arguments
        try process.run()
        NSApp.terminate(nil)
    }

    private static func relaunchHelper() throws -> URL {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", allowedBundleIDs.contains(Bundle.main.bundleIdentifier ?? "") else { throw RecoveryError.invalidIdentity }
        let helper = app.appendingPathComponent("Contents/Helpers/SimuSubRelaunch")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw RecoveryError.helperMissing }
        return helper
    }

    enum RecoveryError: LocalizedError {
        case invalidIdentity, helperMissing, resetFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidIdentity: "请从正式 simuSub 应用包打开程序。"
            case .helperMissing: "重新启动组件缺失，请完整解压 simuSub 应用包。"
            case .resetFailed(let message): "应用音频授权修复失败：\(message)。请在系统录制权限列表中移除 simuSub，再重新申请。"
            }
        }
    }
}
