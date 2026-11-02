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
                    VStack(alignment: .leading, spacing: 26) {
                        Text("声音来源").font(.system(size: 16, weight: .semibold))
                        SubtitleSourceDock().zIndex(2)
                        HStack(alignment: .bottom, spacing: 14) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("源语言").font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                                DesignMenuField(title: "日语") { Button("日语") {} }.accessibilityIdentifier("subtitle.sourceLanguage")
                            }
                            Image(systemName: "arrow.right").foregroundStyle(ThemeColor.muted).frame(height: 44)
                            VStack(alignment: .leading, spacing: 9) {
                                Text("翻译为").font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                                DesignMenuField(title: "简体中文") { Button("简体中文") {} }.accessibilityIdentifier("subtitle.targetLanguage")
                            }
                        }
                        Button {
                            model.isSubtitleOnly = true
                            if model.isCapturing { subtitles.show() } else { model.toggleSubtitlePlayback() }
                        } label: { Label(model.isCapturing ? "打开字幕浮窗" : "开始同传", systemImage: "play").frame(maxWidth: .infinity).frame(height: 28) }
                            .buttonStyle(ThemeActionButtonStyle(prominent: true)).disabled(model.isStarting || model.isStopping || model.isLoadingApplications)
                            .accessibilityIdentifier("subtitle.start")
                    }.designPanel().zIndex(1).accessibilityIdentifier("subtitle.sourcePanel")
                    VStack(alignment: .leading, spacing: 24) {
                        Text("字幕外观").font(.system(size: 16, weight: .semibold))
                        VStack(spacing: 7) {
                            if model.subtitleDisplayMode == .bilingual { Text("今日も一緒に、ゆっくりいこう。").font(Font(SubtitleFont.native(appearance.japaneseFont, size: appearance.japaneseSize))).foregroundStyle(ThemeColor.muted) }
                            Text("今天也一起，慢慢来吧。").font(Font(SubtitleFont.native(appearance.chineseFont, size: appearance.chineseSize, weight: .semibold)))
                        }.frame(maxWidth: .infinity).frame(height: 116).background(ThemeColor.preview, in: RoundedRectangle(cornerRadius: 12))
                        SubtitleFontSettings()
                        HStack(spacing: 17) {
                            sizePicker("日语字号", selection: $appearance.japaneseSize)
                            sizePicker("中文字号", selection: $appearance.chineseSize)
                        }
                        Toggle("显示日语原文", isOn: Binding(get: { model.subtitleDisplayMode == .bilingual }, set: { model.subtitleDisplayMode = $0 ? .bilingual : .chinese }))
                            .toggleStyle(DesignToggleStyle()).frame(height: 36)
                    }.designPanel().accessibilityIdentifier("subtitle.appearancePanel")
                }
            }.padding(DesignV23.pageInset)
        }.background(ThemeColor.background)
    }
    private func sizePicker(_ title: String, selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
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
                        }.frame(maxWidth: .infinity).frame(height: 86).background(model.selectedAppBundleID == app.bundleIdentifier ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).help("选择 " + (app.localizedName ?? "应用")).accessibilityIdentifier("source." + (app.bundleIdentifier ?? ""))
                }
                Button { reload(); more.toggle(); searchFocused = more } label: {
                    VStack(spacing: 7) { Image(systemName: "plus").font(.system(size: 23, weight: .light)).frame(height: 36); Text("其他").font(.system(size: 10)) }.frame(maxWidth: .infinity).frame(height: 86)
                }.buttonStyle(.plain).foregroundStyle(ThemeColor.muted).accessibilityIdentifier("source.more")
                Spacer(minLength: 0)
            }.padding(.vertical, 8).disabled(model.isBusy)
                .overlay(alignment: .topLeading) {
                    if more { moreApplications.offset(y: 94).zIndex(3) }
                }
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
