import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance = "外观", recording = "录制", accounts = "平台", permissions = "权限"
    var id: String { rawValue }
    var symbol: String { switch self { case .appearance: "eye"; case .recording: "record.circle"; case .accounts: "display"; case .permissions: "checkmark.shield" } }
}
struct SettingsWindow: View {
    @State private var category: SettingsCategory = .appearance
    var recording = false
    var initialCategory: String? = nil
    var onClose: (() -> Void)? = nil
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 20) {
            DesignPageHeading(title: "设置") {
                if let onClose { Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭设置") }
            }
            HStack(alignment: .top, spacing: 25) {
                VStack(spacing: 8) {
                    ForEach(SettingsCategory.allCases) { item in
                        Button { category = item } label: {
                            Label(item.rawValue, systemImage: item.symbol).font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).frame(height: 44)
                                .foregroundStyle(ThemeColor.ink)
                                .background(category == item ? ThemeColor.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("settings." + item.id)
                    }
                }.frame(width: 158)
                ScrollView {
                    Group {
                        switch category {
                        case .appearance: AppearanceSettings()
                        case .recording: LiveRecordingSettings()
                        case .accounts: PlatformAdvancedSettings()
                        case .permissions: SubtitlePermissionTools()
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
        }.padding(DesignV23.pageInset).background(ThemeColor.background).appTheme()
            .onAppear { if recording { category = .recording }; if let initialCategory, let initial = SettingsCategory(rawValue: initialCategory) { category = initial } }
    }
}
// Retained type for diagnostic callers; the actual settings entry is unified.
struct SubtitleSettingsContent: View { var body: some View { SubtitlePermissionTools() } }

struct AdvancedServiceSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DesignPageHeading(title: "模型与服务") { EmptyView() }
                HStack(alignment: .top, spacing: 22) {
                    servicePanel(.speechRecognition, selection: $model.selectedASRProfileID)
                    servicePanel(.translation, selection: $model.selectedTranslationProfileID)
                }
                if model.isDownloadingModels { ProgressView(value: model.downloadProgress); Text(model.downloadStatus).font(.caption).foregroundStyle(ThemeColor.muted) }
            }.padding(DesignV23.pageInset)
        }.background(ThemeColor.background)
    }
    private func servicePanel(_ purpose: ServicePurpose, selection: Binding<UUID?>) -> some View {
        let profile = model.profiles.first { $0.id == selection.wrappedValue }
        let installed = purpose == .speechRecognition ? model.asrInstalled : model.translationInstalled
        return VStack(alignment: .leading, spacing: 24) {
            Text(purpose == .speechRecognition ? "语音识别" : "翻译").font(.system(size: 16, weight: .semibold))
            DesignMenuField(title: profile?.name ?? "选择服务") {
                ForEach(model.profiles.filter { $0.purpose == purpose && $0.isEnabled }) { value in Button(value.name) { selection.wrappedValue = value.id } }
                Divider()
                if purpose == .translation { Button("添加 DeepSeek") { model.addDeepSeekProfile() } }
                Button("添加接口") { model.addProfile(purpose) }
            }.disabled(model.isBusy)
            if let profile, profile.kind != .local { ServiceProfileCard(profileID: profile.id).id(profile.id) }
            else {
                HStack {
                    VStack(alignment: .leading, spacing: 8) { Text(profile?.model ?? "本地引擎").font(.system(size: 13)); Text(installed ? "已就绪" : "未安装").font(.caption).foregroundStyle(ThemeColor.muted) }
                    Spacer()
                    if !installed { Button("准备模型", action: model.ensureLocalModels).disabled(model.isDownloadingModels || model.isBusy) }
                }
            }
        }.designPanel()
    }
}
private struct ServiceProfileCard: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID
    @State private var apiKey = ""
    @State private var status = ""
    @State private var isTesting = false
    @State private var confirmRemove = false
    var body: some View {
        if let binding = model.binding(for: profileID) {
            VStack(alignment: .leading, spacing: 18) {
                field("API 地址", text: binding.baseURL)
                VStack(alignment: .leading, spacing: 9) {
                    Text("API Key").font(.caption).foregroundStyle(ThemeColor.muted)
                    SecureField(model.savedCredentialIDs.contains(profileID) ? "已保存密钥" : "输入 API Key", text: $apiKey).textFieldStyle(ClipFieldStyle())
                }
                field("模型", text: binding.model)
                HStack {
                    Button("保存") {
                        do { if !apiKey.isEmpty { try model.saveAPIKey(apiKey, for: binding.wrappedValue); apiKey = "" }; status = "已保存" }
                        catch { status = error.localizedDescription }
                    }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                    Spacer()
                    Menu {
                        Button(isTesting ? "测试中…" : "测试连接") { isTesting = true; Task { status = await model.testConnection(for: binding.wrappedValue); isTesting = false } }.disabled(isTesting)
                        Button("删除服务", role: .destructive) { confirmRemove = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 30)
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled) }
                DisclosureGroup("高级") {
                    VStack(alignment: .leading, spacing: 12) {
                        field("服务名称", text: binding.name)
                        Stepper("超时 \(binding.wrappedValue.timeoutSeconds) 秒", value: binding.timeoutSeconds, in: 5...180, step: 5)
                        if binding.wrappedValue.purpose == .translation {
                            Text("翻译提示词").font(.caption)
                            TextEditor(text: Binding(get: { binding.wrappedValue.translationPrompt ?? ServiceProfile.defaultTranslationPrompt }, set: { binding.wrappedValue.translationPrompt = String($0.prefix(2000)) })).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 100).background(ThemeColor.control)
                            Button("恢复默认提示词") { binding.wrappedValue.translationPrompt = nil }
                        }
                    }.padding(.top, 12)
                }.font(.system(size: 12))
            }.disabled(model.isBusy)
                .confirmationDialog("删除服务配置？", isPresented: $confirmRemove) { Button("删除", role: .destructive) { model.removeProfile(profileID) } }
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(title).font(.caption).foregroundStyle(ThemeColor.muted); TextField(title, text: text).textFieldStyle(ClipFieldStyle()) }
    }
}
struct SubtitleQuickSettings: View { var body: some View { SettingsWindow() } }
