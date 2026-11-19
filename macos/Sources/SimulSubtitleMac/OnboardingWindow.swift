import AppKit
import SwiftUI

struct LaunchContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if !model.onboardingCompleted && CommandLine.arguments.contains("--onboarding-check") {
                OnboardingHost(model: model)
            } else { MainWindow() }
        }
    }
}

private struct OnboardingHost: View {
    @StateObject private var setup: OnboardingState
    @EnvironmentObject private var appearance: HomeAppearance
    init(model: AppModel) { _setup = StateObject(wrappedValue: OnboardingState(model: model)) }
    var body: some View {
        OnboardingWindow(setup: setup)
            .task {
                if await OnboardingChecks.runIfRequested(model: setup.model, appearance: appearance) { return }
                setup.refreshPermission()
                await setup.checkLocalModels()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refreshPermission() }
            .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                if !CommandLine.arguments.contains("--onboarding-check") { setup.refreshPermission() }
            }
    }
}

struct OnboardingWindow: View {
    @ObservedObject var setup: OnboardingState
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        HStack(spacing: 0) {
            sidebar.frame(width: 204)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text(setup.step == .permissions ? "开启权限" : "选择模型"))
                    .font(.system(size: 30, weight: .semibold)).padding(.bottom, 48)
                if setup.step == .permissions { permissionCard }
                else {
                    HStack(alignment: .top, spacing: 20) {
                        SetupModelCard(setup: setup, model: setup.model, purpose: .speechRecognition)
                        SetupModelCard(setup: setup, model: setup.model, purpose: .translation)
                    }
                }
                Spacer(minLength: 32)
                Rectangle().fill(ThemeColor.line).frame(height: 1)
                HStack {
                    if setup.step == .models { Button(L10n.text("上一步")) { setup.step = .permissions }.frame(minWidth: 100) }
                    Spacer()
                    if setup.step == .permissions {
                        Button { setup.advance() } label: { HStack(spacing: 24) { Text(L10n.text("下一步")); Image(systemName: "arrow.right") }.frame(width: 144, height: 24) }
                            .buttonStyle(SetupContinueButtonStyle()).disabled(!setup.permissions.screenGranted)
                    } else {
                        Button { setup.finish() } label: { HStack(spacing: 18) { Text(L10n.text("进入主界面")); Image(systemName: "arrow.right") }.frame(width: 150, height: 24) }
                            .buttonStyle(SetupContinueButtonStyle()).disabled(!setup.canFinish)
                    }
                }.padding(.top, 24)
            }.padding(.horizontal, 44).padding(.top, 78).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeColor.background.ignoresSafeArea())
        .appTheme()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 38, height: 38).accessibilityHidden(true)
                }
                Text("SimuSub").font(.system(size: 23, weight: .semibold))
            }.padding(.horizontal, 20).padding(.bottom, 56)
            stepButton(.permissions, title: "开启权限", number: "1")
            stepButton(.models, title: "选择模型", number: "2").padding(.top, 10)
                .disabled(!setup.permissions.screenGranted)
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("主题")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        Button { appearance.theme = theme } label: {
                            Circle().fill(Color(nsColor: ThemePalette.color(theme, dark: false, role: .primary)))
                                .frame(width: 28, height: 28)
                                .padding(3)
                                .overlay(Circle().strokeBorder(appearance.theme == theme ? ThemeColor.primary : .clear, lineWidth: 1))
                        }.buttonStyle(.plain).help(theme.title).accessibilityLabel(L10n.text("主题：\(theme.title)"))
                            .accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
                    }
                }
            }.padding(.horizontal, 23).padding(.bottom, 30)
        }.padding(.top, 38).background(ThemeColor.sidebar.ignoresSafeArea())
    }
    private func stepButton(_ step: SetupStep, title: String, number: String) -> some View {
        Button {
            if step == .models { setup.advance() } else { setup.step = .permissions }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if step == .permissions && setup.permissions.screenGranted { Image(systemName: "checkmark").font(.system(size: 11, weight: .medium)) }
                    else { Text(number).font(.system(size: 12, weight: .semibold)) }
                }.frame(width: 25, height: 25)
                    .foregroundStyle(setup.step == step ? ThemeColor.surface : ThemeColor.primary)
                    .background(setup.step == step ? ThemeColor.primary : ThemeColor.surface, in: Circle())
                Text(L10n.text(title)).font(.system(size: 14, weight: setup.step == step ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(12).frame(height: 50)
                .background(setup.step == step ? ThemeColor.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).padding(.horizontal, 14)
    }
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 20) {
                setupIcon("display")
                Text(L10n.text("屏幕与系统音频录制")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(L10n.text(setup.permissions.screenGranted ? "✓ 已开启" : "待开启"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.primary)
                    .frame(width: 86, height: 30).background(ThemeColor.soft, in: Capsule())
            }
            Rectangle().fill(ThemeColor.line).frame(height: 1)
            HStack {
                Text(L10n.text("系统设置  ›  隐私与安全性  ›  屏幕与系统音频录制"))
                    .font(.system(size: 13)).foregroundStyle(ThemeColor.muted)
                Spacer()
                Button { setup.permissions.openSetupSettings() } label: { Label(L10n.text("打开设置"), systemImage: "arrow.up.right") }
                    .buttonStyle(ThemeActionButtonStyle(prominent: true))
            }
        }.padding(28).frame(maxWidth: .infinity, minHeight: 224)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ThemeColor.line))
    }
}

private func setupIcon(_ name: String) -> some View {
    Image(systemName: name).font(.system(size: 20, weight: .regular))
        .foregroundStyle(ThemeColor.primary).frame(width: 40, height: 40)
        .background(ThemeColor.selection, in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
}

private struct SetupModelCard: View {
    @ObservedObject var setup: OnboardingState
    @ObservedObject var model: AppModel
    let purpose: ServicePurpose
    @State private var key = ""
    @State private var showKey = false
    private var asr: Bool { purpose == .speechRecognition }
    private var profile: ServiceProfile? { setup.profile(for: purpose) }
    private var local: Bool { profile?.kind == .local }
    private var state: SetupDownloadState { setup.downloads[purpose] ?? SetupDownloadState() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                setupIcon(asr ? "waveform" : "character.bubble")
                VStack(alignment: .leading, spacing: 6) {
                    Text(asr ? "ASR" : "Translation").font(.system(size: 12, weight: .medium)).foregroundStyle(ThemeColor.muted)
                    Text(L10n.text(purpose.rawValue)).font(.system(size: 18, weight: .semibold))
                }
                Spacer()
                Menu(L10n.text(local ? "本地" : "云端")) {
                    Button(L10n.text("本地")) { setup.select(.local, for: purpose); key = "" }
                    Button(L10n.text("云端")) { setup.select(.openAICompatible, for: purpose); key = "" }
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 88, height: 32)
                    .overlay {
                        HStack {
                            Text(L10n.text(local ? "本地" : "云端")).font(.system(size: 12))
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 9))
                        }.padding(.horizontal, 14).frame(width: 88, height: 32)
                            .setupField().allowsHitTesting(false)
                    }.accessibilityLabel(L10n.text("\(purpose.rawValue)模型位置"))
            }.frame(height: 42)
            line.padding(.vertical, 22)
            if local { localFields }
            else if let profile, let binding = model.binding(for: profile.id) { cloudFields(profile, binding: binding) }
        }
        .padding(24).frame(maxWidth: .infinity, minHeight: 446, maxHeight: 446, alignment: .topLeading)
        .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(ThemeColor.line))
        .onChange(of: profile?.id) { _ in key = "" }
    }
    private var line: some View { Rectangle().fill(ThemeColor.line).frame(height: 1) }
    private func label(_ text: String) -> some View { Text(L10n.text(text)).font(.system(size: 12)).foregroundStyle(ThemeColor.muted) }
    private var localFields: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("模型").padding(.bottom, 10)
            HStack {
                Text(asr ? "ReazonSpeech · k2 v2" : "Index–Translate–2B").font(.system(size: 13))
                Spacer()
                Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
            }.padding(.horizontal, 12).frame(height: 44).setupField()
                .accessibilityLabel(L10n.text(asr ? "本地模型 ReazonSpeech k2 v2" : "本地模型 Index Translate 2B"))
            HStack {
                Text(L10n.text(asr ? "日语 · INT8 · 169 MB" : "Q4_K_M · 1.31 GB")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                Spacer(minLength: 8)
                if state.phase == .pending || (state.phase == .failed && state.canRetry) {
                    Button { setup.startDownload(purpose) } label: { Label(L10n.text(state.phase == .failed ? "重试" : "下载"), systemImage: "arrow.down.to.line") }
                        .accessibilityLabel(L10n.text("下载\(purpose.rawValue)模型"))
                } else if state.phase == .downloading || state.phase == .paused {
                    Button { setup.togglePause(purpose) } label: { Label(L10n.text(state.phase == .paused ? "继续" : "暂停"), systemImage: state.phase == .paused ? "play" : "pause") }
                }
            }.frame(height: 48)
            HStack {
                label("存储位置")
                Spacer()
                Button { setup.revealModels(purpose) } label: { Image(systemName: "folder").font(.system(size: 16)) }
                    .buttonStyle(.plain).help(L10n.text("在访达中显示模型目录")).accessibilityLabel(L10n.text("显示\(purpose.rawValue)模型目录"))
            }.padding(.bottom, 10)
            Text(displayPath).font(.system(size: 12)).lineSpacing(8)
                .textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                .padding(.horizontal, 12).setupField()
            Spacer(minLength: 12)
            downloadStatus
        }
    }
    private var displayPath: String {
        let root = model.modelStore.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if root.hasSuffix("/Application Support/SimulSubtitle/models") {
            return "~/Library/Application Support/\nSimulSubtitle/models/\(asr ? "asr-ja/" : "mt/\nindex-translate-2b.gguf")"
        }
        return root + (asr ? "/asr-ja/" : "/mt/index-translate-2b.gguf")
    }
    private var downloadStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            line.padding(.bottom, 6)
            HStack {
                if state.phase == .complete { Image(systemName: "checkmark").font(.system(size: 11)) }
                Text(L10n.text(state.label)).font(.system(size: 12, weight: .medium))
                Spacer()
                if state.phase != .complete {
                    Text("\(Int(state.fraction * 100))%").font(.system(size: 12)).monospacedDigit()
                }
                if state.phase == .downloading || state.phase == .paused {
                    Button { setup.cancel(purpose) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        .help(L10n.text("取消下载")).accessibilityLabel(L10n.text("取消\(purpose.rawValue)模型下载"))
                }
            }.foregroundStyle(ThemeColor.primary)
            GeometryReader { g in
                Capsule().fill(ThemeColor.soft)
                    .overlay(alignment: .leading) { Capsule().fill(ThemeColor.primary).frame(width: g.size.width * state.fraction) }
            }.frame(height: 5).accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("\(purpose.rawValue)下载进度")).accessibilityValue("\(Int(state.fraction * 100))% \(state.label)")
            if !state.error.isEmpty {
                Text(L10n.text(state.error)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted).lineLimit(2).help(state.error)
            } else if state.phase == .downloading || state.phase == .paused {
                let total = asr ? model.modelStore.asrDownloadBytes : model.modelStore.translationDownloadBytes
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(Double(total) * state.fraction), countStyle: .decimal)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .decimal))")
                    .font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
            }
        }.frame(height: 66, alignment: .top)
    }
    private func cloudFields(_ profile: ServiceProfile, binding: Binding<ServiceProfile>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label("API 地址")
            TextField("https://…/v1", text: binding.baseURL).textFieldStyle(.plain).padding(12).frame(height: 44).setupField()
            label("API Key").padding(.top, 4)
            HStack {
                Group {
                    if showKey { TextField(L10n.text(model.savedCredentialIDs.contains(profile.id) ? "已保存密钥" : "输入密钥"), text: $key) }
                    else { SecureField(L10n.text(model.savedCredentialIDs.contains(profile.id) ? "已保存密钥" : "输入密钥"), text: $key) }
                }.textFieldStyle(.plain)
                Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }.buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(showKey ? "隐藏密钥" : "显示密钥"))
            }.padding(12).frame(height: 44).setupField()
                .onChange(of: key) { _ in setup.invalidate(profile.id) }
                .disabled(setup.testing.contains(profile.id))
            label("模型").padding(.top, 4)
            TextField(L10n.text("输入模型名称"), text: binding.model).textFieldStyle(.plain).padding(12).frame(height: 44).setupField()
            Spacer(minLength: 8)
            line
            HStack {
                Text(L10n.text(setup.testing.contains(profile.id) ? "测试中" : setup.ready(purpose) ? "✓ 已连接" : "待配置"))
                    .font(.system(size: 12)).foregroundStyle(ThemeColor.primary)
                Spacer()
                Button(L10n.text("测试连接")) { Task { await setup.test(profile, key: key) } }
                    .disabled(setup.testing.contains(profile.id) || profile.baseURL.isEmpty || profile.model.isEmpty || (key.isEmpty && !model.savedCredentialIDs.contains(profile.id)))
            }.frame(height: 36)
            if let error = setup.connectionErrors[profile.id] {
                Text(L10n.text(error)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted).lineLimit(2).help(error)
            }
        }.font(.system(size: 13))
    }
}

private extension View {
    func setupField() -> some View {
        background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ThemeColor.line))
    }
}

private struct SetupContinueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .foregroundStyle(enabled ? ThemeColor.surface : ThemeColor.muted.opacity(0.55))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(enabled ? ThemeColor.primary : ThemeColor.sidebar, in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
