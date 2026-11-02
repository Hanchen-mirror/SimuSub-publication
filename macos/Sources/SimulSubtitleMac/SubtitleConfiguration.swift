import SwiftUI

struct SubtitleConfiguration: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subtitles: SubtitlePanelController
    var onServices: () -> Void
    @State private var settings = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("日中同传").font(.system(size: 28, weight: .semibold)); Spacer(); Button("字幕设置") { settings = true } }
                VStack(alignment: .leading, spacing: 20) {
                    Label("声音来源", systemImage: "speaker.wave.2").font(.headline)
                    HStack(spacing: 16) {
                        if let id = model.selectedAppBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 46, height: 46)
                        } else { Image(systemName: "app.dashed").font(.system(size: 36)).foregroundStyle(ThemeColor.muted) }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.selectedAppName ?? "选择正在播放声音的应用").font(.headline)
                            Text("只采集所选应用的声音").font(.caption).foregroundStyle(ThemeColor.muted)
                        }
                        Spacer()
                        if model.isLoadingApplications { ProgressView().controlSize(.small) }
                        Button(model.selectedAppName == nil ? "选择应用…" : "更换应用…", action: model.selectApplication).disabled(model.isBusy || model.isLoadingApplications)
                    }
                }.themeCard()
                VStack(alignment: .leading, spacing: 20) {
                    Label("语言与模型", systemImage: "waveform").font(.headline)
                    HStack(spacing: 20) {
                        language("日语", subtitle: "语音识别", purpose: .speechRecognition, selection: $model.selectedASRProfileID)
                        Image(systemName: "arrow.right").font(.title2).foregroundStyle(ThemeColor.primary)
                        language("中文", subtitle: "文本翻译", purpose: .translation, selection: $model.selectedTranslationProfileID)
                    }
                    HStack {
                        Text(model.readinessIssues.isEmpty ? "所选引擎已就绪" : model.readinessIssues.joined(separator: " · ")).font(.caption).foregroundStyle(ThemeColor.muted)
                        Spacer(); Button("模型与服务", action: onServices)
                    }
                    if model.isDownloadingModels { ProgressView(value: model.downloadProgress); Text(model.downloadStatus).font(.caption) }
                    else if !model.readinessIssues.isEmpty { Button("准备本地模型", action: model.ensureLocalModels) }
                }.themeCard()
                VStack(alignment: .leading, spacing: 20) {
                    Label("字幕样式", systemImage: "textformat").font(.headline)
                    SubtitleFontSettings()
                    HStack {
                        Toggle("显示日语原文", isOn: Binding(get: { model.subtitleDisplayMode == .bilingual }, set: { model.subtitleDisplayMode = $0 ? .bilingual : .chinese })).toggleStyle(.switch)
                        Spacer()
                        Button(model.isCapturing ? "打开字幕浮窗" : "开始同传") {
                            model.isSubtitleOnly = true
                            if !model.isCapturing { model.toggleSubtitlePlayback() }
                        }.buttonStyle(ThemeActionButtonStyle(prominent: true)).controlSize(.large)
                            .disabled(model.isStarting || model.isStopping || model.isLoadingApplications)
                    }
                }.themeCard()
            }.padding(30)
        }.sheet(isPresented: $settings) {
            VStack { HStack { Text("字幕设置").font(.headline); Spacer(); Button("完成") { settings = false } }.padding(); SubtitleQuickSettings() }.frame(width: 760, height: 680).appTheme()
        }
    }
    private func language(_ title: String, subtitle: String, purpose: ServicePurpose, selection: Binding<UUID?>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.medium))
            Picker(subtitle, selection: selection) {
                ForEach(model.profiles.filter { $0.purpose == purpose && $0.isEnabled }) { Text($0.name + " · " + $0.model).tag(Optional($0.id)) }
            }.disabled(model.isBusy)
        }.padding(18).frame(maxWidth: .infinity).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 14))
    }
}
