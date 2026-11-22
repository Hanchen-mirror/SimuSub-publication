import SwiftUI
import Darwin

@main
struct SimulSubtitleMacApp: App {
    @Environment(\.openWindow) private var openWindow
    private let interfaceDefaults: UserDefaults
    @ObservedObject private var localization = AppLocalization.shared
    @StateObject private var model: AppModel
    @StateObject private var appearance: HomeAppearance
    @StateObject private var liveMonitor: LiveMonitorStore
    @StateObject private var clips: ClipStore
    @StateObject private var subtitles = SubtitlePanelController(defaults:
        AppLaunchOptions.isDiagnostic
        ? UserDefaults(suiteName: "SimuSub.PanelChecks.\(UUID().uuidString)")! : .standard)
    @NSApplicationDelegateAdaptor(SimuSubAppDelegate.self) private var appDelegate

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--bundled-offline-test") {
            guard CommandLine.arguments.indices.contains(index + 1) else { Darwin.exit(2) }
            let audio = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await OfflineChecks.runBundled(audio: audio); Darwin.exit(0) }
                catch { fputs("FAIL: " + error.localizedDescription + "\n", stderr); Darwin.exit(1) }
            }
            RunLoop.main.run()
            Darwin.exit(1)
        }
        let diagnostics = AppLaunchOptions.isDiagnostic
        let candidateRoot: URL? = Bundle.main.bundleIdentifier == PermissionRecovery.localCandidateBundleID
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SimuSub Local Candidate") : nil
        _clips = StateObject(wrappedValue: ClipStore(root: ClipStore.diagnosticRoot ?? candidateRoot?.appendingPathComponent("Clips")))
        let appearanceDefaults: UserDefaults
        if diagnostics {
            let args = CommandLine.arguments
            let reviewID = args.firstIndex(of: "--theme-review-id")
                .flatMap { args.dropFirst($0 + 1).first }
                .flatMap { UUID(uuidString: $0) }
            appearanceDefaults = UserDefaults(suiteName: "SimuSub.AppearanceChecks." + (reviewID ?? UUID()).uuidString)!
        } else {
            appearanceDefaults = .standard
        }
        interfaceDefaults = appearanceDefaults
        AppLocalization.shared.configure(defaults: appearanceDefaults)
        if diagnostics { appearanceDefaults.set(true, forKey: "home.dark.v099") }
        let backgroundFile = diagnostics ? FileManager.default.temporaryDirectory.appendingPathComponent("no-check-wallpaper-" + UUID().uuidString)
            : candidateRoot?.appendingPathComponent("Appearance/background.png")
        _appearance = StateObject(wrappedValue: HomeAppearance(defaults: appearanceDefaults, backgroundFile: backgroundFile))
        let liveDefaults = diagnostics ? UserDefaults(suiteName: "SimuSub.LiveChecks." + UUID().uuidString)! : .standard
        let liveRoot = diagnostics ? FileManager.default.temporaryDirectory.appendingPathComponent("simusub-live-checks-" + UUID().uuidString)
            : candidateRoot?.appendingPathComponent("LiveMonitor")
        _liveMonitor = StateObject(wrappedValue: LiveMonitorStore(
            storage: LiveMonitorStorage(root: liveRoot),
            service: diagnostics ? RecordingServiceFixture() : LivePlatformService(),
            credentials: LiveCredentials(defaults: liveDefaults, enabled: !diagnostics), notificationsEnabled: !diagnostics))
        if !CommandLine.arguments.contains("--multilingual-benchmark") && !CommandLine.arguments.contains("--speech-benchmark") && !CommandLine.arguments.contains("--self-test") && !CommandLine.arguments.contains("--speech-processing-check") && !CommandLine.arguments.contains("--offline-test") && !CommandLine.arguments.contains("--download-test-models") && !CommandLine.arguments.contains("--install-local-models") {
            if CommandLine.arguments.contains("--live-capture-test") {
                _model = StateObject(wrappedValue: AppModel(defaults: UserDefaults(suiteName: "SimulSubtitle.CaptureChecks.\(UUID().uuidString)")!))
            } else if CommandLine.arguments.contains("--clip-demo"),
                      let i = CommandLine.arguments.firstIndex(of: "--clip-real-models"),
                      CommandLine.arguments.indices.contains(i + 1) {
                let defaults = UserDefaults(suiteName: "SimuSub.ClipReview." + UUID().uuidString)!
                let root = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                _model = StateObject(wrappedValue: AppModel(defaults: defaults, modelStore: LocalModelStore(root: root), modelDownloadsAllowed: false))
            } else if CommandLine.arguments.contains("--release-148-check") || CommandLine.arguments.contains("--original-mode-preview") || CommandLine.arguments.contains("--release-146-check") || CommandLine.arguments.contains("--release-145-check") || CommandLine.arguments.contains("--responsive-layout-check") || CommandLine.arguments.contains("--model-library-check") || CommandLine.arguments.contains("--release-142-check") || CommandLine.arguments.contains("--release-141-check") || CommandLine.arguments.contains("--onboarding-check") || CommandLine.arguments.contains(where: { $0.hasPrefix("--theme-") }) || CommandLine.arguments.contains("--ui-smoke-test") || CommandLine.arguments.contains("--preview-subtitle-layout") || CommandLine.arguments.contains("--subtitle-panel-check") || CommandLine.arguments.contains("--live-monitor-check") || CommandLine.arguments.contains("--clip-check") || CommandLine.arguments.contains("--clip-demo") {
                let defaults = UserDefaults(suiteName: "SimulSubtitle.UIChecks.\(UUID().uuidString)")!
                _model = StateObject(wrappedValue: AppModel(defaults: defaults, modelStore: LocalModelStore(root: FileManager.default.temporaryDirectory.appending(path: "simul-empty-\(UUID().uuidString)"))))
            } else {
                _model = StateObject(wrappedValue: AppModel())
            }
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = SmokeOutcome()
        Task.detached {
            do {
                if let index = CommandLine.arguments.firstIndex(of: "--multilingual-benchmark"), CommandLine.arguments.count > index + 3 {
                    try await MultilingualBenchmark.run(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]), manifest: URL(fileURLWithPath: CommandLine.arguments[index + 2]), report: URL(fileURLWithPath: CommandLine.arguments[index + 3]))
                } else if let index = CommandLine.arguments.firstIndex(of: "--install-local-models"), CommandLine.arguments.count > index + 1 {
                    let store = LocalModelStore()
                    try await store.importModels(from: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    guard store.isASRInstalled, store.isTranslationInstalled else { throw ServiceError.modelFilesMissing }
                    print("Local models installed and verified")
                } else if let index = CommandLine.arguments.firstIndex(of: "--speech-processing-check"), CommandLine.arguments.count > index + 3 {
                    let piano = CommandLine.arguments.count > index + 4 ? URL(fileURLWithPath: CommandLine.arguments[index + 4]) : nil
                    try await SpeechProcessingChecks.run(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]), audio: URL(fileURLWithPath: CommandLine.arguments[index + 2]), report: URL(fileURLWithPath: CommandLine.arguments[index + 3]), instrumentalAudio: piano)
                } else if let index = CommandLine.arguments.firstIndex(of: "--speech-benchmark"), CommandLine.arguments.count > index + 3 {
                    try await SpeechBenchmark.run(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]), manifest: URL(fileURLWithPath: CommandLine.arguments[index + 2]), report: URL(fileURLWithPath: CommandLine.arguments[index + 3]))
                } else if let index = CommandLine.arguments.firstIndex(of: "--offline-test"), CommandLine.arguments.count > index + 2 {
                    try await OfflineChecks.run(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]), audio: URL(fileURLWithPath: CommandLine.arguments[index + 2]))
                } else if let index = CommandLine.arguments.firstIndex(of: "--download-test-models"), CommandLine.arguments.count > index + 1 {
                    let store = LocalModelStore(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    try await store.downloadASR { value, text in print("ASR \(Int(value * 100))% \(text)") }
                    if CommandLine.arguments.contains("--include-translation") { try await store.downloadTranslation() }
                } else { try await SmokeChecks.run() }
            }
            catch { outcome.setFailure(error.localizedDescription) }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure = outcome.failure {
            fputs("FAIL: \(failure)\n", stderr)
            Darwin.exit(1)
        }
        print("PASS: requested checks completed")
        Darwin.exit(0)
    }

    var body: some Scene {
        WindowGroup("SimuSub") {
            LaunchContent(model: model)
                .defaultAppStorage(interfaceDefaults)
                .environmentObject(model)
                .environmentObject(model.permissions)
                .environmentObject(appearance)
                .environmentObject(subtitles)
                .environmentObject(liveMonitor)
                .environmentObject(clips)
                .onAppear { appDelegate.subtitles = subtitles; appDelegate.liveMonitor = liveMonitor; appDelegate.clips = clips; appDelegate.model = model }
                .appTheme().environmentObject(appearance)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.text("关于 SimuSub")) { openWindow(id: "simusub.about") }
            }
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Subtitles") {
                SubtitleWindowMenu(model: model)
            }
        }

        Window(L10n.text("关于 SimuSub"), id: "simusub.about") {
            ScrollView { UsageAboutSettingsView(initialPage: .about).padding(24) }
                .defaultAppStorage(interfaceDefaults)
                .appTheme().environmentObject(appearance)
                .frame(minWidth: 440, minHeight: 320)
        }
        .defaultSize(width: 600, height: 560)

        Settings {
            ZoomedWorkspace { SettingsWindow() }
                .defaultAppStorage(interfaceDefaults)
                .environmentObject(liveMonitor)
                .environmentObject(model)
                .environmentObject(model.permissions)
                .environmentObject(appearance)
                .appTheme().environmentObject(appearance)
                .frame(width: 960, height: 720)
        }
    }
}
