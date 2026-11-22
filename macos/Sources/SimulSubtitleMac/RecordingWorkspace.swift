import SwiftUI

struct RecordingWorkspace: View {
    var onSettings: () -> Void
    var onClips: (UUID?) -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @StateObject private var presentation = CreatorSearchState()
    @State private var adding = false
    @State private var platform: LivePlatform?
    @Namespace private var filterHighlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        GeometryReader { geometry in
            let metrics = WorkspaceMetrics(width: geometry.size.width)
            let header = metrics.narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 8))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DesignPageHeading(title: "直播录制") {
                        Button { adding = true } label: { Label(L10n.text("添加主播"), systemImage: "plus") }.buttonStyle(ThemeActionButtonStyle(prominent: true))
                    }
                    if let notice = monitor.notice { Text(L10n.text(notice)).font(.caption).foregroundStyle(.orange) }
                    VStack(alignment: .leading, spacing: 20) {
                        header {
                            Text(L10n.text("关注的主播")).interfaceFont(size: 15, weight: .semibold)
                            if !metrics.narrow { Spacer(minLength: 6) }
                            HStack(spacing: 4) {
                                filter(nil)
                                ForEach(LivePlatform.allCases) { filter($0) }
                            }.padding(4).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: platform)
                            Button { monitor.refreshNow() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help(L10n.text("刷新直播状态"))
                        }
                        CreatorListV23(onClips: onClips, platform: platform)
                    }.designPanel(inset: metrics.cardInset)
                }.padding(metrics.gutter)
            }
        }.background(ThemeColor.background)
            .sheet(isPresented: $adding) {
                AddCreatorSheet(presentation: presentation, onDone: { adding = false })
            }
    }
    private func filter(_ value: LivePlatform?) -> some View {
        Button { platform = value } label: {
            Group { if let value { PlatformLogo(platform: value).frame(width: 17, height: 17) } else { Image(systemName: "square.grid.2x2").interfaceFont(size: 16) } }
                .frame(width: 32, height: 30)
                .background {
                    if platform == value {
                        RoundedRectangle(cornerRadius: 9).fill(ThemeColor.surface)
                            .matchedGeometryEffect(id: "activePlatform", in: filterHighlight)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(L10n.text(value?.title ?? "全部平台"))
            .accessibilityLabel(L10n.text(value?.title ?? "全部平台"))
            .accessibilityAddTraits(platform == value ? .isSelected : [])
            .accessibilityIdentifier("recording.filter." + (value?.rawValue ?? "all"))
    }
}

struct AddCreatorSheet: View {
    @ObservedObject var presentation: CreatorSearchState
    var onDone: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.text("添加主播")).interfaceFont(size: 20, weight: .semibold)
                Spacer()
                Button(L10n.text("完成"), action: onDone)
            }
            CreatorPlatformPicker(selection: $presentation.platform)
            CreatorSearchField(presentation: presentation)
            Spacer(minLength: 0)
        }.padding(26).frame(width: 620, height: 400).appTheme()
    }
}

struct CreatorPlatformPicker: View {
    @Binding var selection: LivePlatform
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        HStack(spacing: 4) {
            ForEach(LivePlatform.allCases) { platform in
                Button { selection = platform } label: {
                    Text(platform.title).interfaceFont(size: 13, weight: .medium)
                        .foregroundStyle(selection == platform ? ThemeColor.primaryInk : ThemeColor.muted)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(selection == platform ? ThemeColor.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).help(platform.title)
                .accessibilityLabel(platform.title)
                .accessibilityAddTraits(selection == platform ? .isSelected : [])
                .accessibilityIdentifier("creator.platform." + platform.rawValue)
            }
        }
        .padding(4).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain).accessibilityLabel(L10n.text("平台"))
    }
}

struct CreatorListV23: View {
    var onClips: (UUID?) -> Void
    var limit: Int? = nil
    var platform: LivePlatform? = nil
    @EnvironmentObject private var monitor: LiveMonitorStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var creators: [WatchedCreator] { Array(monitor.creators.filter { platform == nil || $0.platform == platform }.prefix(limit ?? Int.max)) }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        let visibleCreators = creators
        let emptyTitle = monitor.creators.isEmpty ? "暂未添加主播" : "此平台暂无关注的主播"
        VStack(spacing: 0) {
            if visibleCreators.isEmpty {
                Divider().overlay(ThemeColor.line)
                VStack(spacing: 8) {
                    Image(systemName: "video").interfaceFont(size: 16).accessibilityHidden(true)
                    Text(L10n.text(emptyTitle)).interfaceFont(size: 13)
                }
                .foregroundStyle(ThemeColor.muted)
                .frame(maxWidth: .infinity, minHeight: 104)
                .accessibilityIdentifier("recording.empty")
                .transition(.opacity)
            }
            ForEach(visibleCreators) { creator in
                VStack(spacing: 0) {
                    Divider().overlay(ThemeColor.line)
                    CreatorRowV23(creator: creator, onClips: { onClips(creator.id) })
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: visibleCreators.map(\.id))
    }
}
private struct CreatorRowV23: View {
    let creator: WatchedCreator
    var onClips: () -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var removing = false
    private var active: LiveRecording? { monitor.activeRecording(creator.id) }
    private var recordingMessage: String? {
        let latest = monitor.recordings.first { $0.creatorID == creator.id }
        guard let latest, [.preparing, .interrupted, .failed].contains(latest.state) else { return nil }
        return latest.message
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        HStack(spacing: 14) {
            PlatformAvatar(url: creator.avatarURL, platform: creator.platform).frame(width: 54, height: 54).clipShape(Circle())
                .contentShape(Circle()).onTapGesture(count: 2, perform: openLive)
                .help(L10n.text("双击打开直播间")).accessibilityLabel(L10n.text(creator.name + " 直播间")).accessibilityAction(named: "打开直播间", openLive)
            VStack(alignment: .leading, spacing: 7) {
                Text(creator.name).interfaceFont(size: 15, weight: .semibold)
                HStack(spacing: 6) { PlatformLogo(platform: creator.platform).frame(width: 14, height: 14); HStack(spacing: 4) {
                    Circle().fill(CreatorBadge(creator).color).frame(width: 6, height: 6)
                    Text(CreatorBadge(creator).title).fontWeight(.semibold)
                }.foregroundStyle(CreatorBadge(creator).color).lineLimit(1) }.interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
                if let error = recordingMessage ?? creator.lastError { Text(L10n.text(error)).font(.caption).foregroundStyle(.orange).lineLimit(3) }
            }
            Spacer()
            if let active { Text(L10n.text(active.state.title)).interfaceFont(size: 11).foregroundStyle(ThemeColor.muted) }
            Button {
                if let active { monitor.stopRecording(active.id) } else { monitor.startRecording(creator.id) }
            } label: {
                Image(systemName: active == nil ? "record.circle" : "stop.circle.fill").interfaceFont(size: 23).foregroundStyle(Color(red: 0.67, green: 0.37, blue: 0.38)).frame(width: 38, height: 38)
            }.buttonStyle(.plain).help(L10n.text(active == nil ? "检查并录制当前直播" : active?.state == .preparing ? "取消连接" : "停止录制"))
                .accessibilityLabel(L10n.text(active == nil ? "开始录制" : active?.state == .preparing ? "取消连接" : "停止录制")).accessibilityIdentifier("home.record." + creator.id.uuidString)
                .disabled(active?.state == .stopping)
            Menu {
                if let active, [LiveRecordingState.recording, .paused].contains(active.state) {
                    Button(L10n.text(active.state == .paused ? "继续录制" : "暂停录制")) {
                        if active.state == .paused { monitor.resumeRecording(active.id) } else { monitor.pauseRecording(active.id) }
                    }
                }
                Toggle(L10n.text("自动录制"), isOn: Binding(get: { creator.autoRecord }, set: { monitor.updateCreator(creator.id, autoRecord: $0); if $0 { monitor.startMonitoring() } }))
                Toggle(L10n.text("监控直播"), isOn: Binding(get: { creator.monitoring }, set: { monitor.updateCreator(creator.id, monitoring: $0); if $0 { monitor.startMonitoring() } }))
                Toggle(L10n.text("开播提醒"), isOn: Binding(get: { creator.notify }, set: { value in monitor.updateCreator(creator.id, notify: value); if value { Task { await monitor.requestNotifications() } } }))
                Button(L10n.text("打开录制文件夹"), action: monitor.showFolder)
                Divider()
                Button(L10n.text("删除主播"), role: .destructive) { removing = true }
            } label: { Image(systemName: "ellipsis").frame(width: 30, height: 34) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30).help(L10n.text("主播操作")).accessibilityIdentifier("creator.more." + creator.id.uuidString)
        }.padding(.vertical, 14).frame(minHeight: 85)
            .sheet(isPresented: $removing) { CreatorRemovalConfirmation(name: creator.name, onCancel: { removing = false }) { Task { await monitor.removeCreator(creator.id) }; removing = false } }
    }
    private func openLive() {
        if let address = try? LiveAddress.normalize(creator.address, platform: creator.platform), let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
