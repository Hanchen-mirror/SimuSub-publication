import SwiftUI

/// The active route is selected per source language. Local resources and remote
/// configurations share a picker, but never a readiness or storage claim.
struct AdvancedServiceSettings: View {
    @EnvironmentObject private var model: AppModel
    var clipJobActive = false
    @Environment(\.appThemeID) private var themeID
    @State private var showServices = false
    @State private var showImport = false
    @State private var editing: ServiceProfile?
    @State private var detail: ServiceProfile?
    @State private var deleting: ServiceProfile?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = themeID
        GeometryReader { geometry in
            let metrics = WorkspaceMetrics(width: geometry.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DesignPageHeading(title: "模型与服务") {
                        Button { showServices.toggle() } label: { Image(systemName: "plus").frame(width: 18, height: 18) }
                            .buttonStyle(ThemeActionButtonStyle()).help(L10n.text("添加自定义接口"))
                            .accessibilityLabel(L10n.text("添加自定义接口")).accessibilityIdentifier("services.add")
                            .popover(isPresented: $showServices, arrowEdge: .bottom) { servicesMenu }
                    }
                    if let reason = model.serviceSelectionLockReason {
                        HStack {
                            Label(L10n.text(reason), systemImage: "info.circle").font(.caption).foregroundStyle(ThemeColor.muted)
                            Spacer()
                            if model.isCapturing && !model.isStopping {
                                Button(L10n.text("停止同传"), action: model.stopCapture).buttonStyle(ThemeActionButtonStyle())
                            }
                        }.accessibilityIdentifier("services.selectionLockReason")
                    }
                    VStack(spacing: 0) {
                        groupHeading("语音识别", translation: false)
                        ForEach(AppModel.recognitionLanguages) { language in
                            modelRow(profile: model.recognitionProfile(for: language), language: language, narrow: geometry.size.width < 550)
                            if language != AppModel.recognitionLanguages.last { Divider().overlay(ThemeColor.line) }
                        }
                    }.designPanel(inset: 20)
                    VStack(spacing: 0) {
                        groupHeading("翻译", translation: true)
                        modelRow(profile: model.profiles.first { $0.id == model.selectedTranslationProfileID }, language: nil, narrow: geometry.size.width < 550)
                    }.designPanel(inset: 20)
                    storage
                    if model.isDownloadingModels {
                        ProgressView(value: model.downloadProgress)
                        Text(L10n.text(model.downloadStatus)).font(.caption).foregroundStyle(ThemeColor.muted)
                    }
                    ModelLibraryNotice(library: model.localModels)
                }.padding(metrics.gutter)
            }.accessibilityIdentifier(metrics.stacked ? "services.stacked" : "services.columns")
        }.background(ThemeColor.background)
            .onReceive(refresh) { _ in model.refreshModels() }
            .sheet(item: $editing) { profile in ServiceConfigurationEditor(profile: profile) }
            .sheet(item: $detail) { profile in modelDetails(profile) }
            .sheet(isPresented: $showImport) { importModels }
            .confirmationDialog(removalTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { profile in
                Button(L10n.text(removalAction(profile)), role: .destructive) {
                    guard !removalLocked else { return }
                    if profile.kind == .local { model.removeLocalModel(profile) } else { model.removeProfile(profile.id) }
                }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { profile in
                Text(L10n.text(profile.kind != .local ? "仅移除配置，保留本地文件和已保存的密钥。" :
                    (model.removal(for: profile)?.isReference == true ? "保留原位置的模型文件。" : "此模型的文件将移到废纸篓，使用它的语言或服务需要重新准备模型。")))
            }
    }

    private func groupHeading(_ title: String, translation: Bool) -> some View {
        HStack(spacing: 10) {
            ServiceGlyph(translation: translation).frame(width: 20, height: 20).foregroundStyle(ThemeColor.primary)
            Text(L10n.text(title)).interfaceFont(size: 15, weight: .semibold)
            Spacer()
        }.padding(.bottom, 14).overlay(alignment: .bottom) { Divider().overlay(ThemeColor.line) }
    }

    private func modelRow(profile: ServiceProfile?, language: SubtitleLanguage?, narrow: Bool) -> some View {
        HStack(spacing: 18) {
            Group {
                if let language { languageBadge(language) }
                else { ServiceGlyph(translation: true).padding(8) }
            }.frame(width: 36, height: 36).foregroundStyle(ThemeColor.primary)
                .background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.text(language.map { $0.isChinese ? "中文" : $0.name } ?? (profile?.kind == .openAICompatible ? "云端翻译" : "本地翻译")))
                    .interfaceFont(size: 14, weight: .semibold)
                Text(profile.map { $0.kind == .local ? $0.model : $0.name + " · " + $0.model } ?? L10n.text("选择服务"))
                    .font(.system(size: 12)).foregroundStyle(ThemeColor.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let profile {
                if !narrow { Text(profile.kind == .local ? byteLabel(bytes(profile)) : L10n.text("云端接口")).font(.caption).foregroundStyle(ThemeColor.muted).frame(width: 85, alignment: .trailing) }
                status(profile)
            }
            Menu {
                if let profile, profile.kind == .local {
                    Button(L10n.text("打开模型文件夹")) {
                        let folder = model.modelFolder(for: profile)
                        if !NSWorkspace.shared.open(folder) { model.localModels.message = "无法打开模型文件夹" }
                    }.disabled(!FileManager.default.fileExists(atPath: model.modelFolder(for: profile).path))
                }
                Menu(L10n.text("选择服务")) {
                    if let language {
                        Button { model.chooseRecognition(nil, for: language) } label: {
                            Label(L10n.text("默认本地模型"), systemImage: model.hasRecognitionOverride(for: language) ? "desktopcomputer" : "checkmark")
                        }
                        Divider()
                        ForEach(model.recognitionChoices(for: language)) { choice in
                            Button { model.chooseRecognition(choice.id, for: language) } label: { choiceLabel(choice, selected: choice.id == profile?.id) }
                        }
                    } else {
                        ForEach(model.translationChoices) { choice in
                            Button { model.selectedTranslationProfileID = choice.id } label: { choiceLabel(choice, selected: choice.id == profile?.id) }
                        }
                    }
                    Divider()
                    Button(L10n.text("导入本地模型")) { showImport = true }
                    Button(L10n.text("添加接口")) { newService(language == nil ? .translation : .speechRecognition) }
                }.disabled(model.isBusy)
                if let profile {
                    Button(L10n.text("模型详情")) { detail = profile }
                    if profile.kind != .local || model.removal(for: profile) != nil {
                        Divider()
                        Button(L10n.text(removalAction(profile)), role: .destructive) { deleting = profile }.disabled(removalLocked)
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L10n.text("模型操作"))
                .accessibilityLabel(L10n.text(language?.name ?? "翻译") + " · " + L10n.text("模型操作"))
                .accessibilityIdentifier(language.map { "services.asr." + $0.asrCode } ?? "services.translation")
        }.padding(.vertical, 14)
    }

    private var removalLocked: Bool {
        model.isBusy || clipJobActive || model.isDownloadingModels || model.localModels.downloadingID != nil
    }
    private func removalAction(_ profile: ServiceProfile) -> String {
        if profile.kind != .local { return "移除配置" }
        return model.removal(for: profile)?.isReference == true ? "移除模型引用" : "移到废纸篓"
    }
    private var removalTitle: String {
        guard let profile = deleting else { return "" }
        let name = profile.kind == .local ? profile.model : profile.name
        return L10n.text(removalAction(profile)) + " · " + name
    }
    private func choiceLabel(_ profile: ServiceProfile, selected: Bool) -> some View {
        Label(profile.kind == .local ? profile.model : profile.name, systemImage: selected ? "checkmark" : (profile.kind == .local ? "desktopcomputer" : "cloud"))
    }
    private func languageBadge(_ language: SubtitleLanguage) -> some View {
        HStack(spacing: 0) {
            Text(language.isChinese ? "ZH" : language == .japanese ? "JP" : "EN").font(.system(size: language.isChinese ? 10 : 12, weight: .semibold))
            if language.isChinese { Text("-CN").font(.system(size: 7, weight: .semibold)) }
        }
    }
    private func status(_ profile: ServiceProfile) -> some View {
        let ready = profile.kind == .local && model.localProfileInstalled(profile)
        let title = profile.kind == .local ? (ready ? "已就绪" : "等待中") : (model.savedCredentialIDs.contains(profile.id) ? "已配置" : "待配置")
        return Label(L10n.text(title), systemImage: ready ? "checkmark.circle" : "clock")
            .font(.system(size: 11)).foregroundStyle(ready ? Color.green : (profile.kind == .local ? Color.red : ThemeColor.muted))
    }
    private func bytes(_ profile: ServiceProfile) -> Int64 {
        if let path = profile.localModelPath { return Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if let definition = LocalModelDefinition.catalog.first(where: { $0.id == profile.localModelID }) { return definition.bytes }
        return Int64(profile.purpose == .translation ? model.modelStore.translationDownloadBytes : model.modelStore.asrDownloadBytes)
    }
    private func byteLabel(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
    private var storage: some View {
        let installed = model.profiles.filter { $0.kind == .local && model.localProfileInstalled($0) }
        var seen = Set<String>()
        let unique = installed.filter { seen.insert($0.localModelPath ?? $0.localModelID ?? $0.purpose.rawValue).inserted }
        let speech = unique.filter { $0.purpose == .speechRecognition }.reduce(Int64(0)) { $0 + bytes($1) }
        let translation = unique.filter { $0.purpose == .translation }.reduce(Int64(0)) { $0 + bytes($1) }
        let total = speech + translation
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("模型空间")).interfaceFont(size: 14, weight: .semibold); Spacer()
                Text(byteLabel(total)).interfaceFont(size: 19, weight: .semibold)
                Button { model.localModels.openDirectory() } label: { Image(systemName: "folder").frame(width: 26, height: 24) }.buttonStyle(.plain).help(L10n.text("打开模型文件夹"))
            }
            GeometryReader { geometry in
                HStack(spacing: total > 0 ? 3 : 0) {
                    Capsule().fill(ThemeColor.primary).frame(width: total > 0 ? max(0, (geometry.size.width - 3) * CGFloat(translation) / CGFloat(total)) : 0)
                    Capsule().fill(ThemeColor.muted.opacity(0.6))
                }
            }.frame(height: 8).background(ThemeColor.line, in: Capsule())
            HStack(spacing: 24) {
                Label(L10n.text("翻译") + "  " + byteLabel(translation), systemImage: "square.fill").foregroundStyle(ThemeColor.primary)
                Label(L10n.text("语音识别") + "  " + byteLabel(speech), systemImage: "square.fill").foregroundStyle(ThemeColor.muted)
            }.font(.system(size: 11))
        }.designPanel(inset: 20).accessibilityIdentifier("services.storage")
    }

    private func newService(_ purpose: ServicePurpose) {
        showServices = false
        editing = ServiceProfile(name: "", kind: .openAICompatible, purpose: purpose)
    }
    private var servicesMenu: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(L10n.text("添加 ASR")) { newService(.speechRecognition) }
                Button(L10n.text("添加翻译")) { newService(.translation) }
            }.buttonStyle(ThemeActionButtonStyle())
            ForEach(model.profiles.filter { $0.kind != .local }) { profile in
                Divider()
                HStack(spacing: 10) {
                    ServiceGlyph(translation: profile.purpose == .translation).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 4) { Text(profile.name).font(.system(size: 13, weight: .semibold)); Text(profile.model).font(.caption).foregroundStyle(ThemeColor.muted) }
                    Spacer(minLength: 8)
                    Button { showServices = false; editing = profile } label: { Image(systemName: "slider.horizontal.3") }.help(L10n.text("编辑"))
                    Button { showServices = false; deleting = profile } label: { Image(systemName: "trash") }.help(L10n.text("移除"))
                }.buttonStyle(.plain)
                HStack(spacing: 6) {
                    if profile.purpose == .speechRecognition {
                        ForEach(AppModel.recognitionLanguages) { language in
                            Button(L10n.text(language.isChinese ? "中文" : language.name)) { model.chooseRecognition(profile.id, for: language) }
                                .disabled(!model.recognitionChoices(for: language).contains { $0.id == profile.id })
                                .buttonStyle(ThemeActionButtonStyle(prominent: model.recognitionProfile(for: language)?.id == profile.id))
                        }
                    } else {
                        Button(L10n.text("使用翻译")) { model.selectedTranslationProfileID = profile.id }
                            .disabled(!model.translationChoices.contains { $0.id == profile.id })
                            .buttonStyle(ThemeActionButtonStyle(prominent: model.selectedTranslationProfileID == profile.id))
                    }
                }
            }
            Divider()
            Button { showServices = false; showImport = true } label: { Label(L10n.text("导入本地模型"), systemImage: "folder.badge.plus") }.buttonStyle(.plain)
        }.padding(16).frame(width: 300).background(ThemeColor.surface).disabled(model.isBusy).appTheme()
    }

    private func modelDetails(_ profile: ServiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(profile.kind == .local ? profile.model : profile.name).font(.headline); Spacer(); Button(L10n.text("完成")) { detail = nil } }
            HStack { Text(L10n.text("状态")); Spacer(); status(profile) }
            Divider()
            if profile.kind == .local {
                LocalModelActions(profile: profile, library: model.localModels, mayPrepareBuiltIn: profile.purpose == .translation || profile.id == model.selectedASRProfileID)
                Button(L10n.text("导入其他模型")) { detail = nil; showImport = true }.buttonStyle(ThemeActionButtonStyle())
            } else {
                Text(profile.model).foregroundStyle(ThemeColor.muted)
                Button(L10n.text("编辑接口")) { detail = nil; editing = profile }.buttonStyle(ThemeActionButtonStyle())
                Button(L10n.text("移除配置"), role: .destructive) { detail = nil; deleting = profile }.disabled(model.isBusy)
            }
        }.padding(24).frame(width: 420).appTheme()
    }
    private var importModels: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("导入本地模型")).font(.headline); Spacer(); Button(L10n.text("完成")) { showImport = false } }
            Text(L10n.text("选择兼容的模型文件夹；文件保留在原位置。")).font(.caption).foregroundStyle(ThemeColor.muted)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(LocalModelDefinition.catalog) { definition in
                        HStack { Text(definition.name).font(.system(size: 13)); Spacer(); Button(L10n.text("导入")) { model.localModels.importFolder(definition) }.buttonStyle(ThemeActionButtonStyle()) }
                    }
                }
            }.frame(maxHeight: 300)
            Divider()
            Button(L10n.text("选择 GGUF 翻译模型…")) { model.chooseTranslationModel() }.buttonStyle(ThemeActionButtonStyle())
            ModelLibraryNotice(library: model.localModels)
        }.padding(24).frame(width: 440).disabled(model.isBusy).appTheme()
    }
}

struct ServiceGlyph: View {
    var translation: Bool
    var body: some View {
        if translation {
            GeometryReader { geometry in
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w * 0.08, y: h * 0.72))
                    path.addQuadCurve(to: CGPoint(x: w * 0.92, y: h * 0.72), control: CGPoint(x: w * 0.5, y: h * 0.02))
                    path.move(to: CGPoint(x: w * 0.2, y: h * 0.75))
                    path.addQuadCurve(to: CGPoint(x: w * 0.8, y: h * 0.75), control: CGPoint(x: w * 0.5, y: h * 0.3))
                }.stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            }.accessibilityHidden(true)
        } else {
            Image(systemName: "waveform").resizable().scaledToFit().accessibilityHidden(true)
        }
    }
}

private struct ServiceConfigurationEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: ServiceProfile
    @State private var key = ""
    @State private var error = ""
    @State private var testing = false
    private var existing: Bool { model.profiles.contains { $0.id == profile.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L10n.text(existing ? "编辑接口" : (profile.purpose == .translation ? "添加自定义翻译" : "添加自定义 ASR"))).font(.headline); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.text("关闭")) }
            field("名称", text: $profile.name)
            field("接口地址", text: $profile.baseURL)
            field("模型 ID", text: $profile.model)
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key").font(.caption).foregroundStyle(ThemeColor.muted)
                SecureField(L10n.text(model.savedCredentialIDs.contains(profile.id) ? "已保存密钥；留空保持" : "输入 API Key"), text: $key)
                    .textFieldStyle(ClipFieldStyle())
                    .accessibilityLabel("API Key")
                    .accessibilityIdentifier("services.apiKey")
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled).accessibilityIdentifier("services.validation") }
            HStack {
                Button(L10n.text(testing ? "测试中…" : "测试连接"), action: test)
                    .buttonStyle(ThemeActionButtonStyle()).accessibilityIdentifier("services.testConnection")
                Spacer()
                Button(L10n.text("保存")) { if save() { dismiss() } }.buttonStyle(ThemeActionButtonStyle(prominent: true))
            }
        }.padding(24).frame(width: 420).disabled(model.isBusy || testing).appTheme()
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(L10n.text(title)).font(.caption).foregroundStyle(ThemeColor.muted); TextField(L10n.text(title), text: text).textFieldStyle(ClipFieldStyle()) }
    }
    private func validate(requireName: Bool) -> Bool {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!requireName || !profile.name.isEmpty), !profile.model.isEmpty else { error = L10n.text("请填写名称和模型 ID。"); return false }
        guard (try? profile.validatedBaseURL()) != nil else { error = L10n.text("请输入有效的 http:// 或 https:// 接口地址。"); return false }
        return true
    }
    private func save() -> Bool {
        guard validate(requireName: true) else { return false }
        do {
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try model.saveAPIKey(key, for: profile); key = "" }
            if let index = model.profiles.firstIndex(where: { $0.id == profile.id }) { model.profiles[index] = profile }
            else { model.profiles.append(profile) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func test() {
        guard validate(requireName: false) else { return }
        testing = true
        error = ""
        Task {
            error = await model.testConnection(for: profile, draftKey: key)
            testing = false
        }
    }
}
