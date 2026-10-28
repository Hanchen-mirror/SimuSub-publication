import SwiftUI

/// Network errors and unknown responses must never be presented as confirmed offline.
enum DashboardGroup: String, CaseIterable, Identifiable {
    case live, offline, pending
    var id: String { rawValue }
    var title: String { switch self { case .live: "正在直播"; case .offline: "暂未开播"; case .pending: "状态待确认" } }
    var color: Color { switch self { case .live: .green; case .offline: .purple; case .pending: .orange } }
    static func group(_ creator: WatchedCreator) -> Self {
        switch CreatorBadge(creator) {
        case .live: .live
        case .offline, .upcoming: .offline
        case .unknown, .error, .confirming: .pending
        }
    }
    func matches(_ creator: WatchedCreator, platform: String, keyword: String) -> Bool {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.group(creator) == self && (platform.isEmpty || creator.platform.rawValue == platform)
            && (query.isEmpty || creator.name.localizedCaseInsensitiveContains(query) || creator.snapshot.title.localizedCaseInsensitiveContains(query))
    }
}

@MainActor
struct HomeDashboard: View {
    var onClips: (UUID?) -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(DashboardGroup.allCases) { group in
                    if group != .pending || monitor.creators.contains(where: { DashboardGroup.group($0) == .pending }) {
                        DashboardSection(group: group, onClips: onClips)
                    }
                }
            }.padding(.vertical, 6)
        }.accessibilityIdentifier("home.dashboard")
    }
}

@MainActor
private struct DashboardSection: View {
    let group: DashboardGroup
    var onClips: (UUID?) -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var platform = ""
    @State private var keyword = ""
    private var creators: [WatchedCreator] {
        monitor.creators.filter { group.matches($0, platform: platform, keyword: keyword) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(group.color).frame(width: 9, height: 9)
                Text(group.title).font(.system(size: 21, weight: .semibold))
                Text("\(creators.count)").font(.caption.weight(.semibold)).padding(.horizontal, 9).padding(.vertical, 4)
                    .background(group.color.opacity(0.15), in: Capsule())
                Spacer()
                Picker("平台", selection: $platform) {
                    Text("全部平台").tag("")
                    ForEach(LivePlatform.allCases) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 120).accessibilityLabel(group.title + "平台筛选")
                TextField("筛选名称 / 标题", text: $keyword).textFieldStyle(.roundedBorder).frame(width: 150)
                    .accessibilityLabel(group.title + "关键词筛选")
            }
            if creators.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: group == .live ? "video" : "moon.zzz").font(.system(size: 25, weight: .light)).foregroundStyle(group.color)
                    Text(monitor.creators.isEmpty ? "从上方搜索并添加喜欢的主播" : "没有符合条件的主播").font(.callout)
                    if !platform.isEmpty || !keyword.isEmpty {
                        Button("清除筛选") { platform = ""; keyword = "" }.buttonStyle(.borderless)
                    } else if !monitor.creators.isEmpty {
                        Button("刷新直播状态") { monitor.refreshNow() }.buttonStyle(.borderless)
                    }
                }.frame(maxWidth: .infinity).frame(height: 130)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: group == .live ? 265 : 210), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(creators) { creator in
                        DashboardCreatorCard(creator: creator, onClips: { onClips(creator.id) })
                    }
                }
            }
        }.accessibilityIdentifier("home.section." + group.rawValue)
    }
}

@MainActor
private struct DashboardCreatorCard: View {
    let creator: WatchedCreator
    var onClips: () -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var removing = false
    @State private var controls = false
    private var active: LiveRecording? { monitor.activeRecording(creator.id) }
    private var badge: CreatorBadge { CreatorBadge(creator) }
    private var status: String {
        if let active { return active.state.title }
        switch badge {
        case .live: return "LIVE"
        case .offline: return "未开播"
        case .upcoming: return "等待开播"
        case .unknown: return "尚未确认"
        case .error: return "连接失败"
        case .confirming: return "正在确认"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                PlatformAvatar(url: creator.avatarURL, platform: creator.platform)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom).frame(height: 64)
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            PlatformLogo(platform: creator.platform).frame(width: 17, height: 17)
                            Text(creator.platform.title).font(.caption.weight(.medium))
                        }.padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(9)
                    }
                    .overlay(alignment: .topTrailing) {
                        Text(status).font(.caption.weight(.semibold)).foregroundStyle(active == nil ? badge.color : .red)
                            .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(9)
                    }
            }.frame(height: DashboardGroup.group(creator) == .live ? 155 : 105)
                .contentShape(Rectangle()).onTapGesture(perform: openCreator).help("点击在浏览器观看")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(creator.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    if badge == .live || active != nil {
                        Button {
                            if let active { monitor.stopRecording(active.id) }
                            else { monitor.startRecording(creator.id) }
                        } label: {
                            Label(active == nil ? "开始录制" : active?.state == .preparing ? "取消连接" : active?.state == .stopping ? "保存中" : "停止保存",
                                  systemImage: active == nil ? "record.circle" : "stop.circle")
                                .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 9)
                                .foregroundStyle(Color.black).background(active == nil ? Color.cyan : Color.orange, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(active?.state == .stopping)
                            .accessibilityIdentifier("home.record.\(creator.id)")
                    }
                }
                Text(creator.lastError ?? (creator.snapshot.title.isEmpty ? creator.snapshot.state.title : creator.snapshot.title))
                    .font(.system(size: 12)).foregroundStyle(badge == .error ? Color.orange : Color.secondary).lineLimit(2).frame(height: 34, alignment: .top)
                HStack {
                    Button(action: openCreator) { Label("观看", systemImage: "play.rectangle") }
                    Spacer()
                    Button { controls.toggle() } label: { Image(systemName: "ellipsis") }
                        .help("录制操作与文件").accessibilityLabel("录制操作与文件")
                        .popover(isPresented: $controls) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(creator.name).font(.headline)
                                HomeRecordingBar(creator: creator, onClips: onClips)
                                Button("进入剪辑工作台", action: onClips)
                            }.padding(18)
                        }
                }.font(.caption).foregroundStyle(.secondary).buttonStyle(.plain)
            }.padding(12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.09)))
        .contextMenu {
            Button("在浏览器观看", action: openCreator)
            Button("刷新直播状态") { monitor.refreshNow() }
            Button("剪辑这位主播的录像", action: onClips)
            Button("打开录制文件夹", action: monitor.showFolder)
            Toggle("自动录制", isOn: Binding(get: { creator.autoRecord }, set: { monitor.updateCreator(creator.id, autoRecord: $0); if $0 { monitor.startMonitoring() } }))
            Toggle("监控这位主播", isOn: Binding(get: { creator.monitoring }, set: { monitor.updateCreator(creator.id, monitoring: $0); if $0 { monitor.startMonitoring() } }))
            Divider()
            Button("向前移动") { monitor.shiftCreator(creator.id, by: -1) }
            Button("向后移动") { monitor.shiftCreator(creator.id, by: 1) }
            Button("移除主播…", role: .destructive) { removing = true }
        }
        .sheet(isPresented: $removing) {
            CreatorRemovalConfirmation(name: creator.name, onCancel: { removing = false }) {
                Task { await monitor.removeCreator(creator.id) }; removing = false
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(creator.name + "，" + status)
        .accessibilityIdentifier("home.creator.\(creator.id)")
    }
    private func openCreator() {
        if let address = try? LiveAddress.normalize(creator.address, platform: creator.platform), let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }
}
