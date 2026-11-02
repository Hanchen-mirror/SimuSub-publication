import SwiftUI

struct RecordingWorkspace: View {
    var onSettings: () -> Void
    var onClips: (UUID?) -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @StateObject private var presentation = HomeLivePresentation()
    @State private var adding = false
    @State private var platform: LivePlatform?
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DesignPageHeading(title: "直播录制") {
                    Button { adding = true } label: { Label("添加主播", systemImage: "plus") }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("关注的主播").font(.system(size: 15, weight: .semibold)); Spacer()
                        HStack(spacing: 4) {
                            filter(nil)
                            ForEach(LivePlatform.allCases) { filter($0) }
                        }.padding(4).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                        Button { monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新直播状态")
                    }
                    CreatorListV23(onClips: onClips, platform: platform)
                }.designPanel()
                VStack(alignment: .leading, spacing: 22) {
                    HStack { Text("录制偏好").font(.system(size: 15, weight: .semibold)); Spacer(); Button(action: onSettings) { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("录制与平台设置") }
                    Button(action: monitor.chooseFolder) {
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(ThemeColor.primary).frame(width: 38, height: 38).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 11))
                            Text("保存位置"); Spacer(); Text(monitor.settings.outputFolder).font(.system(size: 12)).foregroundStyle(ThemeColor.muted).lineLimit(1).truncationMode(.middle); Image(systemName: "chevron.right").font(.caption)
                        }.frame(height: 48)
                    }.buttonStyle(.plain).accessibilityIdentifier("recording.folder")
                    Divider().overlay(ThemeColor.line)
                    HStack { Text("视频格式"); Spacer(); DesignMenuField(title: monitor.settings.container.title) { ForEach(RecordingContainer.allCases) { value in Button(value.title) { monitor.updateSettings { $0.container = value } } } }.frame(width: 180) }

                    Divider().overlay(ThemeColor.line)
                    HStack { Label("直播结束后自动保存", systemImage: "checkmark.circle"); Spacer(); Button("打开录制文件夹", action: monitor.showFolder) }.font(.system(size: 13))
                }.designPanel()
                if let notice = monitor.notice { HStack { Text(notice).font(.caption); Spacer(); Button { monitor.notice = nil } label: { Image(systemName: "xmark") } }.foregroundStyle(ThemeColor.muted) }
            }.padding(.horizontal, 32).padding(.vertical, 28)
        }.background(ThemeColor.background)
            .sheet(isPresented: $adding) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("添加主播").font(.system(size: 20, weight: .semibold)); Spacer(); Button("完成") { adding = false } }
                    Picker("平台", selection: $presentation.platform) { ForEach(LivePlatform.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    HomeCreatorSearch(presentation: presentation)
                    Spacer(minLength: 0)
                }.padding(26).frame(width: 620, height: 400).appTheme()
            }
    }
    private func filter(_ value: LivePlatform?) -> some View {
        Button { platform = value } label: {
            Group { if let value { PlatformLogo(platform: value).frame(width: 17, height: 17) } else { Image(systemName: "square.grid.2x2").font(.system(size: 16)) } }
                .frame(width: 32, height: 30).background(platform == value ? ThemeColor.surface : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).help(value?.title ?? "全部平台").accessibilityLabel(value?.title ?? "全部平台")
    }
}

struct CreatorListV23: View {
    var onClips: (UUID?) -> Void
    var limit: Int? = nil
    var platform: LivePlatform? = nil
    @EnvironmentObject private var monitor: LiveMonitorStore
    private var creators: [WatchedCreator] { Array(monitor.creators.filter { platform == nil || $0.platform == platform }.prefix(limit ?? Int.max)) }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 0) {
            if creators.isEmpty {
                Divider().overlay(ThemeColor.line)
                Label(monitor.creators.isEmpty ? "添加主播后，在这里查看直播与录制状态" : "该平台还没有关注的主播", systemImage: "video")
                    .font(.system(size: 13)).foregroundStyle(ThemeColor.muted).frame(maxWidth: .infinity, minHeight: 104)
            }
            ForEach(creators) { creator in
                Divider().overlay(ThemeColor.line)
                CreatorRowV23(creator: creator, onClips: { onClips(creator.id) })
            }
        }
    }
}
private struct CreatorRowV23: View {
    let creator: WatchedCreator
    var onClips: () -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var removing = false
    @State private var controls = false
    private var active: LiveRecording? { monitor.activeRecording(creator.id) }
    private var badge: CreatorBadge { CreatorBadge(creator) }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        HStack(spacing: 14) {
            PlatformAvatar(url: creator.avatarURL, platform: creator.platform).frame(width: 40, height: 40).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(creator.name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) { PlatformLogo(platform: creator.platform).frame(width: 12, height: 12); Text(creator.lastError ?? (creator.snapshot.title.isEmpty ? creator.snapshot.state.title : creator.snapshot.title)).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
            }
            Spacer()
            if let active {
                Text(active.state.title).font(.system(size: 11)).foregroundStyle(ThemeColor.primary)
                Button { monitor.stopRecording(active.id) } label: { Label(active.state == .stopping ? "保存中" : "停止保存", systemImage: "stop.circle") }.disabled(active.state == .stopping)
            } else if badge == .live {
                Label("直播中", systemImage: "circle.fill").font(.system(size: 10)).foregroundStyle(.green).padding(8).background(Color.green.opacity(0.06), in: Capsule())
                Button { monitor.startRecording(creator.id) } label: { Label("开始录制", systemImage: "record.circle") }
            } else {
                Button { monitor.updateCreator(creator.id, notify: !creator.notify); if !creator.notify { Task { await monitor.requestNotifications() } } } label: { Label(creator.notify ? "已开启提醒" : "开播提醒", systemImage: creator.notify ? "bell.badge" : "bell") }
            }
            Button { controls = true } label: { Image(systemName: "ellipsis") }.buttonStyle(.plain).help("主播与录制操作")
                .popover(isPresented: $controls) { VStack(alignment: .leading, spacing: 14) { Text(creator.name).font(.headline); HomeRecordingBar(creator: creator, onClips: onClips); Button("剪辑录像", action: onClips) }.padding(20) }
        }.frame(minHeight: 85)
            .contextMenu {
                Button("打开直播") { if let address = try? LiveAddress.normalize(creator.address, platform: creator.platform), let url = URL(string: address) { NSWorkspace.shared.open(url) } }
                Button("剪辑录像", action: onClips)
                Toggle("自动录制", isOn: Binding(get: { creator.autoRecord }, set: { monitor.updateCreator(creator.id, autoRecord: $0); if $0 { monitor.startMonitoring() } }))
                Toggle("监控主播", isOn: Binding(get: { creator.monitoring }, set: { monitor.updateCreator(creator.id, monitoring: $0); if $0 { monitor.startMonitoring() } }))
                Button("移除主播…", role: .destructive) { removing = true }
            }.sheet(isPresented: $removing) { CreatorRemovalConfirmation(name: creator.name, onCancel: { removing = false }) { Task { await monitor.removeCreator(creator.id) }; removing = false } }
    }
}
