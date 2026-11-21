import AppKit
import SwiftUI

@MainActor
enum OnboardingChecks {
    static func runIfRequested(model: AppModel, appearance: HomeAppearance) async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--onboarding-check"),
              CommandLine.arguments.count > index + 1 else { return false }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        var results: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "OnboardingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            results.append(name)
        }
        var granted = false
        var destination: WorkspaceDestination?
        var allowRequest = false
        var permissionEvents: [String] = []
        let permissions = CapturePermissionCenter(readScreen: { granted }, probeScreen: {
            permissionEvents.append("request")
            if !allowRequest { throw CapturePermissionError.screenNotGranted }
        }, openPrivacyPane: {
            permissionEvents.append("settings")
            return true
        })
        let setup = OnboardingState(model: model, permissions: permissions)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingWindow(setup: setup) { destination = $0 }.environmentObject(appearance))
        func capture(_ name: String) async throws {
            window.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 120_000_000)
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ServiceError.invalidResponse }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ServiceError.invalidResponse }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            appearance.mode = .dark
            appearance.theme = .purple
            setup.refreshPermission()
            setup.finish(at: .subtitle) { destination = $0 }
            try check(!permissions.screenGranted && destination == nil && !model.onboardingCompleted, "No live subtitles before consent")
            try check(permissionEvents.isEmpty, "Visiting the guide does not request access or open Settings")
            await permissions.requestScreenSettings(manageGranted: true)
            try check(permissionEvents == ["request", "settings"] && !permissions.screenGranted &&
                      permissions.notice == CapturePermissionCenter.missingAppHint,
                      "Settings button requests ScreenCaptureKit before opening the pane and explains how to add a missing app")
            permissionEvents.removeAll()
            allowRequest = true
            await permissions.requestScreenSettings()
            setup.refreshPermission()
            try check(permissionEvents == ["request"] && permissions.screenGranted,
                      "Retrying from onboarding honors a ScreenCaptureKit grant without opening Settings")
            permissions.leaveSetup()
            setup.refreshPermission()
            try check(!permissions.screenGranted, "Returning to the guide checks current permission again")
            try await capture("01-permissions")
            window.setContentSize(NSSize(width: 640, height: 420))
            try await capture("01-permissions-compact")
            window.setContentSize(NSSize(width: 1120, height: 780))
            granted = true
            setup.refreshPermission()
            try check(permissions.screenGranted && !model.onboardingCompleted, "Returning from System Settings enables live entry")
            permissionEvents.removeAll()
            await permissions.requestScreenSettings(manageGranted: true)
            try check(permissionEvents == ["settings"], "Users with access can manage it directly in Settings")
            try await capture("02-permissions-ready")
            granted = false
            setup.finish(at: .subtitle) { destination = $0 }
            try check(!permissions.screenGranted && destination == nil && !model.onboardingCompleted, "Permission revoked before clicking is rechecked")
            granted = true
            setup.finish(at: .subtitle) { destination = $0 }
            try check(destination == .subtitle && model.onboardingCompleted && !model.isDownloadingModels, "Live entry works without a model setup step")

            let suite = "SimuSub.OnboardingPersistence." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = AppModel(defaults: defaults, modelStore: model.modelStore)
            try check(!first.onboardingCompleted, "A fresh user sees the guide")
            let deferred = OnboardingState(model: first, permissions: permissions)
            granted = false
            deferred.refreshPermission()
            deferred.finish(at: .clips) { destination = $0 }
            try check(destination == .clips && first.onboardingCompleted && !permissions.screenGranted, "Not now opens the clip workspace without authorization")
            let reopened = AppModel(defaults: defaults, modelStore: model.modelStore)
            try check(reopened.onboardingCompleted, "Completion or deferral persists across relaunch")
            let reopenedGuide = OnboardingState(model: reopened, permissions: permissions)
            granted = true
            reopenedGuide.refreshPermission()
            try check(reopenedGuide.permissions.screenGranted, "A fresh guide instance observes an existing grant")
            if let rootIndex = CommandLine.arguments.firstIndex(of: "--onboarding-models-root"), CommandLine.arguments.count > rootIndex + 1 {
                let store = LocalModelStore(root: URL(fileURLWithPath: CommandLine.arguments[rootIndex + 1]))
                let asr = try await store.verifyInstalled(for: .speechRecognition)
                let mt = try await store.verifyInstalled(for: .translation)
                try check(asr && mt, "Existing ASR and translation SHA-256 verified read-only")
            }
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": results, "networkDownloads": 0], options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
            print("PASS: onboarding \(results.count) checks")
            window.close()
            NSApp.terminate(nil)
        } catch {
            try? error.localizedDescription.write(to: directory.appendingPathComponent("FAILED.txt"), atomically: true, encoding: .utf8)
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        return true
    }
}
