import SwiftUI

struct ModelReadiness: View {
    let ready: Bool
    var body: some View {
        Label(L10n.text(ready ? "已就绪" : "等待中"), systemImage: ready ? "checkmark.circle" : "minus.circle")
            .font(.caption).foregroundStyle(ready ? Color.green : Color.red)
    }
}

struct LocalModelActions: View {
    @EnvironmentObject private var model: AppModel
    let profile: ServiceProfile
    @ObservedObject var library: LocalModelLibrary
    let mayPrepareBuiltIn: Bool

    private var definition: LocalModelDefinition? { LocalModelDefinition.catalog.first { $0.id == profile.localModelID } }
    private var size: String? {
        let bytes: Int64
        if let definition { bytes = definition.bytes }
        else if let path = profile.localModelPath {
            guard let count = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            bytes = Int64(count)
        } else {
            bytes = profile.purpose == .speechRecognition ? model.modelStore.asrDownloadBytes : model.modelStore.translationDownloadBytes
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack { metadata; Spacer(minLength: 4); actions }
                VStack(alignment: .leading, spacing: 6) { metadata; actions }
            }
            if let definition, library.downloadingID == definition.id { ProgressView(value: library.progress) }
        }.disabled(model.isBusy)
    }

    @ViewBuilder private var metadata: some View {
        if let size { Text(size).font(.caption).foregroundStyle(ThemeColor.muted) }
        if model.localProfileInstalled(profile), LocalModelStore.isInsideApplication(model.modelFolder(for: profile)) {
            Label(L10n.text("随应用安装"), systemImage: "shippingbox").font(.caption).foregroundStyle(ThemeColor.muted)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let definition {
                if library.downloadingID == definition.id {
                    Button(action: library.cancel) { Image(systemName: "xmark") }
                        .help(L10n.text("取消下载")).buttonStyle(ThemeActionButtonStyle())
                } else if !library.isUsable(definition) {
                    Button(L10n.text("下载")) { library.download(definition) }
                        .buttonStyle(ThemeActionButtonStyle()).disabled(library.downloadingID != nil)
                        .accessibilityIdentifier("models.download." + definition.id)
                }
            } else if !model.localProfileInstalled(profile) {
                if profile.localModelPath != nil {
                    Button(L10n.text("重新选择模型"), action: model.chooseTranslationModel)
                } else if mayPrepareBuiltIn {
                    Button(L10n.text("准备模型"), action: model.ensureLocalModels).disabled(model.isDownloadingModels)
                }
            }
            if let definition {
                Button(L10n.text("导入已下载模型")) { library.importFolder(definition) }
                    .buttonStyle(ThemeActionButtonStyle())
                Button(L10n.text("模型主页")) { NSWorkspace.shared.open(definition.homepage) }
                    .buttonStyle(ThemeActionButtonStyle())
            }
        }
    }
}

struct TranslationPromptEditor: View {
    @EnvironmentObject private var model: AppModel
    let profileID: UUID
    var height: CGFloat = 113
    var body: some View {
        if let binding = model.binding(for: profileID) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("翻译提示词")).font(.caption)
                TextEditor(text: Binding(get: { binding.wrappedValue.editableTranslationPrompt },
                    set: { binding.wrappedValue.translationPrompt = String($0.prefix(2000)) }))
                    .interfaceFont(size: 12).scrollContentBackground(.hidden).padding(8).frame(height: height)
                    .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("models.translationPrompt")
                Button(L10n.text("恢复默认提示词")) { binding.wrappedValue.translationPrompt = nil }
                    .buttonStyle(ThemeActionButtonStyle())
                    .accessibilityIdentifier("models.restoreTranslationPrompt")
            }.disabled(model.isBusy)
        }
    }
}

struct ModelLibraryNotice: View {
    @ObservedObject var library: LocalModelLibrary
    var body: some View {
        if !library.message.isEmpty { Text(L10n.text(library.message)).font(.caption).foregroundStyle(ThemeColor.muted).textSelection(.enabled) }
    }
}
