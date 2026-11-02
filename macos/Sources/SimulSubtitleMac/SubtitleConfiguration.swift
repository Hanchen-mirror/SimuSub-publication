import AppKit
import SwiftUI

struct SubtitleConfiguration: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var subtitles: SubtitlePanelController
    @EnvironmentObject private var appearance: HomeAppearance
    var onServices: () -> Void
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DesignPageHeading(title: "日中同传") { EmptyView() }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("声音与翻译").font(.system(size: 15, weight: .semibold)).padding(.bottom, 28)
                        Text("声音来源").font(.system(size: 12)).padding(.bottom, 12)
                        SubtitleSourceDock().padding(.bottom, 26).zIndex(2)
                        Text("语言").font(.system(size: 12)).padding(.bottom, 12)
                        HStack(spacing: 14) {
                            Text("日语"); Image(systemName: "arrow.right").foregroundStyle(ThemeColor.muted)
                            Text("简体中文").foregroundStyle(ThemeColor.primaryInk).frame(maxWidth: .infinity).frame(height: 38)
                                .background(ThemeColor.dockSelected, in: RoundedRectangle(cornerRadius: 8))
                                .padding(4).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                        }.font(.system(size: 13)).padding(.bottom, 20)
                        Divider().overlay(ThemeColor.line)
                        Button(action: onServices) {
                            HStack(spacing: 10) {
                                Image(systemName: "cpu").font(.system(size: 19)).foregroundStyle(ThemeColor.primary)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("模型与服务").font(.system(size: 12, weight: .semibold))
                                    Text("语音识别 · " + serviceName(model.selectedASRProfileID) + "   /   翻译 · " + serviceName(model.selectedTranslationProfileID)).font(.system(size: 10)).foregroundStyle(ThemeColor.muted).lineLimit(2)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(ThemeColor.primary)
                            }.padding(.vertical, 18)
                        }.buttonStyle(.plain).accessibilityIdentifier("subtitle.services")
                        Divider().overlay(ThemeColor.line).padding(.bottom, 24)
                        Toggle("弱化背景音乐", isOn: $model.suppressBackgroundMusic).toggleStyle(DesignToggleStyle()).padding(14)
                            .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 12)).disabled(model.isBusy)
                        if model.isDownloadingModels {
                            ProgressView(value: model.downloadProgress).padding(.top, 14)
                            Text(model.downloadStatus).font(.system(size: 10)).foregroundStyle(ThemeColor.muted).padding(.top, 6)
                        } else if !model.readinessIssues.isEmpty {
                            Button("准备本地引擎", action: model.ensureLocalModels).font(.system(size: 11)).padding(.top, 14)
                        }
                        Spacer(minLength: 20)
                        Button {
                            model.isSubtitleOnly = true
                            if model.isCapturing { subtitles.show() } else { model.toggleSubtitlePlayback() }
                        } label: { Label(model.isCapturing ? "打开字幕浮窗" : "开始同传", systemImage: "play.fill").frame(maxWidth: .infinity).frame(height: 32) }
                            .buttonStyle(ThemeActionButtonStyle(prominent: true)).disabled(model.isStarting || model.isStopping || model.isLoadingApplications)
                            .accessibilityIdentifier("subtitle.start")
                    }.frame(height: 568).designPanel().zIndex(1).accessibilityIdentifier("subtitle.sourcePanel")
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text("字幕外观").font(.system(size: 15, weight: .semibold)); Spacer(); Text("实时预览").font(.system(size: 10)).foregroundStyle(ThemeColor.muted).padding(8).background(ThemeColor.soft, in: Capsule()) }.frame(height: 22).padding(.bottom, 28)
                        VStack(spacing: 7) {
                            if model.subtitleDisplayMode == .bilingual { Text("今日も一緒に、ゆっくりいこう。").font(Font(SubtitleFont.native(appearance.japaneseFont, size: appearance.japaneseSize))).foregroundStyle(ThemeColor.muted) }
                            Text("今天也一起，慢慢来吧。").font(Font(SubtitleFont.native(appearance.chineseFont, size: appearance.chineseSize, weight: .medium)))
                        }.frame(maxWidth: .infinity).frame(height: 116)
                            .background(ThemeColor.caption, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(ThemeColor.line)).padding(.horizontal, 14).padding(.vertical, 18)
                            .background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 16)).padding(.bottom, 24)
                        SubtitleFontSettings().padding(.bottom, 22)
                        HStack(spacing: 14) {
                            sizePicker("原文字号", selection: $appearance.japaneseSize)
                            sizePicker("译文字号", selection: $appearance.chineseSize)
                        }
                        Spacer(minLength: 20)
                        Toggle("显示日语原文", isOn: Binding(get: { model.subtitleDisplayMode == .bilingual }, set: { model.subtitleDisplayMode = $0 ? .bilingual : .chinese }))
                            .toggleStyle(DesignToggleStyle()).padding(14).frame(height: 48).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 12))
                    }.frame(height: 568).designPanel().accessibilityIdentifier("subtitle.appearancePanel")
                }
            }.padding(.horizontal, 32).padding(.vertical, 28)
        }.background(ThemeColor.background)
    }
    private func serviceName(_ id: UUID?) -> String {
        guard let profile = model.profiles.first(where: { $0.id == id }) else { return "未选择" }
        return profile.kind == .local ? "本地" : profile.name
    }
    private func sizePicker(_ title: String, selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12))
            DesignMenuField(title: "\(Int(selection.wrappedValue)) px") {
                ForEach([12.0,14,16,18,20,22,24,28,32], id: \.self) { size in Button("\(Int(size)) px") { selection.wrappedValue = size } }
            }

        }.frame(maxWidth: .infinity)
    }
}

struct SubtitleSourceDock: View {
    @EnvironmentObject private var model: AppModel
    @State private var apps: [NSRunningApplication] = []
    @State private var more = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var dockApps: [NSRunningApplication] {
        let selected = apps.filter { $0.bundleIdentifier == model.selectedAppBundleID }
        return Array((selected + apps.filter { $0.bundleIdentifier != model.selectedAppBundleID }).prefix(4))
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                ForEach(dockApps, id: \.processIdentifier) { app in
                    Button { choose(app) } label: {
                        VStack(spacing: 5) {
                            Image(nsImage: app.icon ?? NSImage()).resizable().scaledToFit().frame(width: 36, height: 36)
                            Text(shortName(app)).font(.system(size: 10)).lineLimit(1)
                            Circle().fill(model.selectedAppBundleID == app.bundleIdentifier ? ThemeColor.primary : .clear).frame(width: 4, height: 4)
                        }.frame(width: 54, height: 76).background(model.selectedAppBundleID == app.bundleIdentifier ? ThemeColor.dockSelected : .clear, in: RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(.plain).help("选择 " + (app.localizedName ?? "应用")).accessibilityIdentifier("source." + (app.bundleIdentifier ?? ""))
                }
                Divider().frame(height: 64)
                Button { reload(); more.toggle(); searchFocused = more } label: {
                    VStack(spacing: 7) { Image(systemName: "plus").font(.system(size: 23, weight: .light)).frame(height: 36); Text("更多").font(.system(size: 10)) }.frame(width: 44, height: 76)
                }.buttonStyle(.plain).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("source.more")
                Spacer(minLength: 0)
            }.padding(.horizontal, 8).padding(.vertical, 8).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(ThemeColor.line)).disabled(model.isBusy)
                .overlay(alignment: .topLeading) {
                    if more { moreApplications.offset(y: 124).zIndex(3) }
                }
            Text(model.selectedAppName.map { $0 + " · 已选择" } ?? "选择正在播放日语的应用").font(.system(size: 10)).foregroundStyle(ThemeColor.muted).padding(.horizontal, 4)
        }.onAppear(perform: reload)
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in reload() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in reload() }
    }
    private var moreApplications: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColor.muted)
                TextField("搜索应用", text: $search, prompt: Text("搜索应用").foregroundColor(ThemeColor.muted)).textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("source.search")
                Button { more = false; searchFocused = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭应用列表")
            }.padding(10).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 9))
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(apps.filter { search.isEmpty || ($0.localizedName ?? "").localizedCaseInsensitiveContains(search) }, id: \.processIdentifier) { app in
                        Button { choose(app); more = false; searchFocused = false } label: {
                            HStack(spacing: 12) { Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 25, height: 25); Text(app.localizedName ?? "应用").font(.system(size: 12)); Spacer(); if app.bundleIdentifier == model.selectedAppBundleID { Image(systemName: "checkmark").foregroundStyle(ThemeColor.primary) } }.padding(9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if apps.filter({ search.isEmpty || ($0.localizedName ?? "").localizedCaseInsensitiveContains(search) }).isEmpty { Text("没有匹配的应用").font(.system(size: 12)).foregroundStyle(ThemeColor.muted).padding() }
                }
            }.frame(height: 172)
            HStack { Spacer(); Button("刷新应用", action: reload).font(.system(size: 11)) }
        }.padding(10).frame(maxWidth: .infinity).background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ThemeColor.line))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
            .onAppear { searchFocused = true }
    }
    private func shortName(_ app: NSRunningApplication) -> String {
        if app.bundleIdentifier == "com.apple.Safari" { return "Safari" }
        if app.bundleIdentifier == "com.google.Chrome" { return "Chrome" }
        return app.localizedName ?? "应用"
    }
    private func choose(_ app: NSRunningApplication) {
        guard !model.isBusy else { return }
        // Configuration only. Screen/audio permission and capture start remain
        // in AppModel.startCapture, triggered by the explicit Start button.
        model.selectedAppBundleID = app.bundleIdentifier
        model.selectedAppName = app.localizedName
    }
    private func reload() {
        let preferred = ["com.apple.Safari", "com.google.Chrome", "com.colliderli.iina", "org.videolan.vlc"]
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil }.sorted {
            let a = preferred.firstIndex(of: $0.bundleIdentifier ?? "") ?? 99, b = preferred.firstIndex(of: $1.bundleIdentifier ?? "") ?? 99
            return a == b ? ($0.localizedName ?? "") < ($1.localizedName ?? "") : a < b
        }
    }
}
