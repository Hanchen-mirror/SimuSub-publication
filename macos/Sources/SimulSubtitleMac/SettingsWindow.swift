import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case subtitles = "字幕设置"
    case recording = "录制设置"
    case accounts = "平台设置"
    case appearance = "外观"
    case services = "模型与服务"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .subtitles: "captions.bubble"
        case .recording: "record.circle"
        case .accounts: "person.crop.circle"
        case .appearance: "paintpalette"
        case .services: "cpu"
        }
    }
}

/// Subtitle and recording preferences; editing remains a planned destination.
struct SettingsWindow: View {
    @State private var category: SettingsCategory = .subtitles
    var recording = false
    var onClose: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    private var surface: Color { ThemeColor.background }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").frame(width: 32, height: 32) }
                        .buttonStyle(.plain).help("关闭设置").accessibilityLabel("关闭设置")
                        .keyboardShortcut(.cancelAction)
                }
            }.padding(.horizontal, 18).padding(.top, 14)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 12) {
                    ForEach(SettingsCategory.allCases) { item in
                        Button { category = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(category == item ? ThemeColor.primary : ThemeColor.muted)
                                .frame(width: 124, height: 44, alignment: .leading)
                                .background(category == item ? ThemeColor.primary.opacity(0.10) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        .help(item.rawValue).accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(category == item ? [.isSelected] : [])
                        .accessibilityIdentifier("settings.\(item.id)")
                    }
                    Spacer()
                }
                Group {
                    if category == .subtitles { SubtitleSettingsContent() }
                    else if category == .recording { LiveRecordingSettings() }
                    else if category == .accounts { PlatformAdvancedSettings() }
                    else if category == .appearance { AppearanceSettings() }
                    else { AdvancedServiceSettings() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(surface.ignoresSafeArea()).appTheme()
        .onAppear { if recording { category = .recording } }
    }
}

struct SubtitleSettingsContent: View {
    @EnvironmentObject private var model: AppModel
    @State private var showServices = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("字幕设置").font(.title2.bold())
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("背景音乐抑制", isOn: $model.suppressBackgroundMusic)
                        .help("用增强后的音频判断说话区间，保留原始音频用于识别，减少发音损伤。下次开始字幕时生效。")
                        .accessibilityIdentifier("settings.speech.musicSuppression")
                    Text("减少背景音乐误识别。歌曲中的人声或特别响的音乐仍可能被识别；声音变弱时可关闭对比。")
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    Divider()
                    Toggle("稳定前缀确认", isOn: $model.stablePrefixesEnabled)
                    Toggle("术语库辅助本地识别", isOn: $model.asrHotwordsEnabled)
                    Text(model.asrHotwordStatus).font(.caption).foregroundStyle(ThemeColor.muted)
                    Text("日语先确认连续两次一致的分句。本地小模型保留整句翻译，避免拆句误译；云端可提前翻译稳定分句，定稿后复用或纠正，每句话最多提前请求一次（4 秒超时）。热词会增加计算量，也可能误导识别，可关闭对比。")
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    if model.isBusy { Text("正在处理字幕，停止后可修改以上选项。").font(.caption).foregroundStyle(ThemeColor.muted) }
                }.padding(18).background(ThemeColor.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .disabled(model.isBusy)
                VStack(alignment: .leading, spacing: 10) {
                    Text("日中同传引擎").font(.headline)
                    Picker("日语识别", selection: $model.selectedASRProfileID) {
                        ForEach(model.profiles.filter { $0.purpose == .speechRecognition && $0.isEnabled }) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(model.isBusy)
                    Picker("翻译与上下文核对", selection: $model.selectedTranslationProfileID) {
                        ForEach(model.profiles.filter { $0.purpose == .translation && $0.isEnabled }) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }.disabled(model.isBusy)
                    Text("选择 DeepSeek：日语在本地识别，稳定分句或定稿后发送文字生成中文；无需本地翻译模型。日语草稿先显示，中文需等待网络返回。原音不上传。")
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                }
                SubtitleFontSettings()
                VTuberGlossaryEditor()
                Button("配置 DeepSeek / 第三方模型…") { showServices = true }
                    .sheet(isPresented: $showServices) {
                        VStack { HStack { Spacer(); Button("完成") { showServices = false } }.padding(); AdvancedServiceSettings() }.frame(width: 760, height: 650)
                    }
                SubtitlePermissionTools()
            }.padding(.trailing, 5).padding(.bottom, 16)
        }
    }
}

struct AdvancedServiceSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var managing = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DesignPageHeading(title: "模型与服务") { Button { managing = true } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("管理接口与密钥") }
                HStack(alignment: .top, spacing: 22) {
                    servicePanel(.speechRecognition, selection: $model.selectedASRProfileID)
                    servicePanel(.translation, selection: $model.selectedTranslationProfileID)
                }
                VStack(alignment: .leading, spacing: 22) {
                    Text("翻译偏好").font(.system(size: 15, weight: .semibold))
                    HStack { Text("直播日中翻译").font(.system(size: 13)); Spacer(); Button("编辑提示词与服务…") { managing = true } }
                }.designPanel()
                if model.isDownloadingModels { ProgressView(value: model.downloadProgress); Text(model.downloadStatus).font(.caption).foregroundStyle(ThemeColor.muted) }
            }.padding(.horizontal, 32).padding(.vertical, 28)
        }.background(ThemeColor.background)
            .sheet(isPresented: $managing) {
                VStack(spacing: 18) {
                    HStack { Text("服务配置").font(.system(size: 20, weight: .semibold)); Spacer()
                        Menu { Button("添加 DeepSeek 翻译 / 核对") { model.addDeepSeekProfile() }; Button("添加语音识别接口") { model.addProfile(.speechRecognition) }; Button("添加翻译接口") { model.addProfile(.translation) } } label: { Label("添加服务", systemImage: "plus") }.disabled(model.isBusy)
                        Button("完成") { managing = false }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(ServicePurpose.allCases) { purpose in
                                Text(purpose.rawValue).font(.headline)
                                ForEach(model.profiles.filter { $0.purpose == purpose && $0.kind != .local }) { ServiceProfileCard(profileID: $0.id) }
                            }
                        }
                    }
                }.padding(26).frame(width: 820, height: 680).appTheme()
            }
    }
    private func servicePanel(_ purpose: ServicePurpose, selection: Binding<UUID?>) -> some View {
        let profile = model.profiles.first { $0.id == selection.wrappedValue }
        let installed = purpose == .speechRecognition ? model.asrInstalled : model.translationInstalled
        return VStack(alignment: .leading, spacing: 24) {
            Text(purpose == .speechRecognition ? "语音识别" : "翻译").font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("服务商").font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                DesignMenuField(title: profile?.name ?? "选择服务") {
                    ForEach(model.profiles.filter { $0.purpose == purpose && $0.isEnabled }) { value in Button(value.name) { selection.wrappedValue = value.id } }
                }.disabled(model.isBusy)

            }
            HStack(spacing: 16) {
                Image(systemName: profile?.kind == .local ? "cpu" : "cloud").font(.system(size: 20)).foregroundStyle(ThemeColor.primary)
                VStack(alignment: .leading, spacing: 10) {
                    Text(profile?.model ?? "未选择模型").font(.system(size: 13))
                    Text(profile?.kind == .local ? (installed ? "本地已就绪" : "尚未安装") : (profile.map { model.savedCredentialIDs.contains($0.id) } == true ? "已保存密钥" : "需要配置 API Key")).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
                }
            }.padding(.top, 10)
            if profile?.kind == .local && !installed { Button("准备本地引擎", action: model.ensureLocalModels).disabled(model.isDownloadingModels || model.isBusy) }
            else if profile?.kind != .local { Button("配置服务…") { managing = true } }
            Spacer(minLength: 0)
        }.frame(height: 268).designPanel()
    }
}

private struct ServiceProfileCard: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID
    @State private var apiKey = ""
    @State private var saveStatus = ""
    @State private var connectionResult = ""
    @State private var isTesting = false
    @State private var confirmRemove = false

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        if let binding = model.binding(for: profileID) {
            let profile = binding.wrappedValue
            let isSelected = (profile.purpose == .speechRecognition ? model.selectedASRProfileID : model.selectedTranslationProfileID) == profile.id
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: profile.kind == .local ? "desktopcomputer" : "cloud").foregroundStyle(profile.kind == .local ? Color.green : ThemeColor.primary)
                    if profile.kind == .local { Text(profile.name).font(.headline) }
                    else { TextField("服务名称", text: binding.name).textFieldStyle(.plain).font(.headline) }
                    Spacer()
                    Button(isSelected ? "已选用" : "使用此服务") {
                        if profile.purpose == .speechRecognition { model.selectedASRProfileID = profile.id }
                        else { model.selectedTranslationProfileID = profile.id }
                    }.disabled(isSelected || model.isBusy)
                    if profile.kind != .local {
                        Button { confirmRemove = true } label: { Image(systemName: "trash") }.help("移除服务配置")
                    }
                }
                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("服务地址（含 /v1）").font(.caption).foregroundStyle(ThemeColor.muted)
                        TextField("https://api.example.com/v1", text: binding.baseURL).textFieldStyle(ClipFieldStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型名称").font(.caption).foregroundStyle(ThemeColor.muted)
                        TextField(profile.purpose == .speechRecognition ? "whisper-1" : "gpt-4o-mini", text: binding.model).textFieldStyle(ClipFieldStyle())
                    }
                    if profile.purpose == .translation {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("API 翻译提示词").font(.headline)
                                Spacer()
                                Button("恢复默认") { binding.wrappedValue.translationPrompt = nil }
                            }
                            TextEditor(text: Binding(get: { binding.wrappedValue.translationPrompt ?? ServiceProfile.defaultTranslationPrompt },
                                set: { binding.wrappedValue.translationPrompt = String($0.prefix(2000)) }))
                                .font(.body).scrollContentBackground(.hidden).background(ThemeColor.control).frame(height: 110)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ThemeColor.muted.opacity(0.3)))
                                .accessibilityLabel("API 翻译提示词")
                            Text("自动保存 · 最多 2000 字 · 清空可关闭附加提示词。仅发送给此翻译服务，不修改日语识别原文；内容越长，可能增加费用与延迟。停止字幕后修改，下次启动生效。")
                                .font(.caption).foregroundStyle(ThemeColor.muted)
                        }
                    }
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.savedCredentialIDs.contains(profile.id) ? "API Key · 已保存" : "API Key · 未保存")
                                .font(.caption).foregroundStyle(model.savedCredentialIDs.contains(profile.id) ? Color.green : ThemeColor.muted)
                            SecureField("粘贴密钥后点击保存", text: $apiKey).textFieldStyle(ClipFieldStyle())
                        }
                        Button("保存密钥") {
                            do { try model.saveAPIKey(apiKey, for: profile); apiKey = ""; saveStatus = "已保存到 Keychain" }
                            catch { saveStatus = error.localizedDescription }
                        }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 14) {
                        Text("日语 → 中文").font(.caption).foregroundStyle(ThemeColor.muted)
                        Stepper("超时 \(profile.timeoutSeconds) 秒", value: binding.timeoutSeconds, in: 5...180, step: 5)
                    }
                    HStack(spacing: 12) {
                        Button(isTesting ? "测试中…" : "测试服务") {
                            isTesting = true
                            connectionResult = ""
                            Task { connectionResult = await model.testConnection(for: binding.wrappedValue); isTesting = false }
                        }.disabled(isTesting || !model.savedCredentialIDs.contains(profile.id))
                        Text(profile.purpose == .speechRecognition ? "检查识别服务鉴权" : "发送日语短句验证翻译模型，可能产生少量费用")
                            .font(.caption).foregroundStyle(ThemeColor.muted)
                    }
                    if !connectionResult.isEmpty { Text(connectionResult).font(.callout).textSelection(.enabled) }
                    if !saveStatus.isEmpty { Text(saveStatus).font(.caption).foregroundStyle(ThemeColor.muted) }
                }
            }.padding(18).background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? ThemeColor.primary.opacity(0.35) : ThemeColor.line))
                .disabled(model.isBusy)
                .confirmationDialog("移除服务配置？已保存的 Keychain 密钥会保留。", isPresented: $confirmRemove) {
                    Button("移除配置", role: .destructive) { model.removeProfile(profileID) }
                }
        }
    }
}

/// The floating subtitle window opens this focused settings surface directly.
struct SubtitleQuickSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        SubtitleSettingsContent().padding(20).appTheme()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemeColor.background.ignoresSafeArea())
    }
}
