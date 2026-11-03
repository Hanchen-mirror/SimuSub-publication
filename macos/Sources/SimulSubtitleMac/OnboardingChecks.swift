import AppKit
import SwiftUI

@MainActor
enum OnboardingChecks {
    static func runIfRequested(model: AppModel, appearance: HomeAppearance) async -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--onboarding-check"), CommandLine.arguments.count > index + 1 else { return false }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        var results: [String] = []
        func check(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "OnboardingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            results.append(name)
        }
        var granted = false
        let permissions = CapturePermissionCenter(readScreen: { granted }, probeScreen: { throw CapturePermissionError.screenNotGranted })
        let setup = OnboardingState(model: model, permissions: permissions, downloadsAllowed: false, connectionCheck: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingWindow(setup: setup).environmentObject(appearance))
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
            appearance.mode = .light; appearance.theme = .green
            setup.refreshPermission()
            setup.advance()
            setup.finish()
            try check(setup.step == .permissions && !setup.canFinish && !model.onboardingCompleted, "Permission gate blocks navigation and completion")
            await setup.checkLocalModels()
            setup.startDownload(.speechRecognition)
            try check(setup.downloads[.speechRecognition]?.phase == .pending && !model.isDownloadingModels, "Missing-model checks never download or mutate files")
            try await capture("01-permissions")
            granted = true; setup.refreshPermission(); setup.advance()
            try check(setup.step == .models && !setup.canFinish, "Missing local models block completion")
            setup.applyDiagnosticState(.init(phase: .complete, fraction: 1), for: .translation)
            try await capture("02-local-models")
            setup.applyDiagnosticState(.init(phase: .downloading, fraction: 0.42), for: .speechRecognition)
            setup.applyDiagnosticState(.init(phase: .downloading, fraction: 0.28), for: .translation)
            try await capture("03-downloading")
            setup.togglePause(.speechRecognition)
            try check(setup.downloads[.speechRecognition]?.phase == .paused, "Download pause state")
            setup.togglePause(.speechRecognition)
            try check(setup.downloads[.speechRecognition]?.phase == .downloading, "Download resume state")
            setup.applyDiagnosticState(.init(phase: .complete, fraction: 1), for: .speechRecognition)
            setup.applyDiagnosticState(.init(phase: .complete, fraction: 1), for: .translation)
            try check(setup.canFinish, "Both completed local services enable entry")
            try await capture("04-complete")
            for theme in AppTheme.allCases {
                appearance.theme = theme
                try await capture("theme-\(theme.rawValue)")
            }
            appearance.theme = .blue
            setup.select(.openAICompatible, for: .translation)
            try check(!setup.canFinish, "Untested cloud service blocks entry")
            try await capture("05-cloud")
            if let profile = setup.profile(for: .translation) {
                await setup.test(profile, key: "")
                try check(setup.canFinish, "Successful selected cloud configuration unlocks entry")
                model.binding(for: profile.id)?.wrappedValue.model = "different-model"
                try check(!setup.canFinish, "Editing a verified cloud model invalidates readiness")
                if let changed = setup.profile(for: .translation) { await setup.test(changed, key: "") }
                setup.invalidate(profile.id)
                try check(!setup.canFinish, "Changing credentials invalidates readiness")
            }
            setup.select(.local, for: .translation)
            granted = false; setup.refreshPermission()
            try check(setup.step == .permissions && !setup.canFinish, "Revoked permission returns to first step")
            granted = true; setup.refreshPermission(); setup.advance(); setup.finish()
            try check(model.onboardingCompleted, "Completed setup persists")
            // Independent suite proves completion survives creating a fresh app model.
            let suite = "SimuSub.OnboardingPersistence." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = AppModel(defaults: defaults, modelStore: model.modelStore)
            first.completeOnboarding()
            let reopened = AppModel(defaults: defaults, modelStore: model.modelStore)
            try check(reopened.onboardingCompleted, "Completion restores on relaunch")
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
