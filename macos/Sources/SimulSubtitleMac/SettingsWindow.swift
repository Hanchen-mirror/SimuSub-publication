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

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("模型与服务").font(.title3.bold())
                        Text("默认使用自动安装的本地引擎；第三方接口为可选项，密钥保存在 Keychain。")
                            .font(.callout).foregroundStyle(ThemeColor.muted)
                    }
                    Spacer()
                    Menu {
                        Button("添加 DeepSeek 翻译 / 核对") { model.addDeepSeekProfile() }
                        Button("添加语音识别接口") { model.addProfile(.speechRecognition) }
                        Button("添加翻译接口") { model.addProfile(.translation) }
                    } label: { Label("添加服务", systemImage: "plus") }.disabled(model.isBusy)
                }
                Button("使用默认本地引擎") {
                    model.selectedASRProfileID = model.profiles.first { $0.kind == .local && $0.purpose == .speechRecognition }?.id
                    model.selectedTranslationProfileID = model.profiles.first { $0.kind == .local && $0.purpose == .translation }?.id
                    model.ensureLocalModels()
                }.disabled(model.isBusy)
                Text("日语 → 中文 · 本地引擎自动安装，无需手动选择模型文件。")
                    .font(.callout).foregroundStyle(ThemeColor.muted)
                HStack(spacing: 16) {
                    ForEach(model.profiles.filter { $0.kind == .local }) { profile in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(profile.name, systemImage: "desktopcomputer").font(.headline)
                            Text(profile.model).font(.callout).foregroundStyle(ThemeColor.muted)
                            let installed = profile.purpose == .speechRecognition ? model.asrInstalled : model.translationInstalled
                            Label(installed ? "已就绪 · 本地运行" : "尚未安装", systemImage: installed ? "checkmark.circle" : "arrow.down.circle")
                                .font(.caption).foregroundStyle(installed ? ThemeColor.primary : ThemeColor.muted)
                            Button("使用此模型") {
                                if profile.purpose == .speechRecognition { model.selectedASRProfileID = profile.id }
                                else { model.selectedTranslationProfileID = profile.id }
                                model.ensureLocalModels()
                            }.disabled(model.isBusy)
                        }.themeCard()
                    }
                }
                if model.isDownloadingModels { ProgressView(value: model.downloadProgress); Text(model.downloadStatus).font(.caption) }
                ForEach(ServicePurpose.allCases) { purpose in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(purpose.rawValue).font(.headline).padding(.top, 6)
                        ForEach(model.profiles.filter { $0.purpose == purpose && $0.kind != .local }) { profile in
                            ServiceProfileCard(profileID: profile.id)
                        }
                    }
                }
                Text("云端识别会发送音频；云端翻译会发送识别文本。本地识别和翻译在下载完模型后可离线运行。")
                    .font(.caption).foregroundStyle(ThemeColor.muted)
            }.padding(24).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(ThemeColor.background)
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
