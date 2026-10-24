import SwiftUI
import UniformTypeIdentifiers

extension LivePlatform {
    var color: Color {
        switch self {
        case .bilibili: Color(red: 0, green: 0.66, blue: 0.84)
        case .youtube: .red
        case .twitch: .purple
        }
    }
}

struct LiveRecordingSettings: View {
    @EnvironmentObject private var monitor: LiveMonitorStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("录制设置").font(.title2.bold())
                VStack(alignment: .leading, spacing: 16) {
                    Text("保存目录").font(.headline)
                    Text(monitor.settings.outputFolder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("选择文件夹", action: monitor.chooseFolder)
                        Button("在 Finder 中打开", action: monitor.showFolder)
                    }
                    Divider()
                    Picker("视频格式", selection: Binding(get: { monitor.settings.container }, set: { value in monitor.updateSettings { $0.container = value } })) {
                        ForEach(RecordingContainer.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 300)
                    Text("默认 MKV，适合长时间录制；MP4 使用分段封装。原画质保存，不重复编码，已录内容在断开时尽量保留。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("同时录制：\(monitor.settings.maximumRecordings) 位主播", value: Binding(get: { monitor.settings.maximumRecordings }, set: { value in monitor.updateSettings { $0.maximumRecordings = value } }), in: 1...3)
                    Stepper("检查间隔：\(monitor.settings.intervalSeconds / 60) 分钟", value: Binding(get: { monitor.settings.intervalSeconds / 60 }, set: { value in monitor.updateSettings { $0.intervalSeconds = value * 60 } }), in: 1...15)
                }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                Text("设置对下一次录制生效。自动录制按主播单独开启；达到并发上限时等待后续检查。单次录制上限 12 小时，失败后等待 10 分钟再尝试。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("主播监控仅在 SimuSub 运行且 Mac 保持唤醒时工作；平台访问限制会影响检查与录制。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.trailing, 5)
        }
    }
}

struct LiveConnectionSheet: View {
    let platform: LivePlatform
    @ObservedObject var credentials: LiveCredentials
    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var secret = ""
    @State private var clientID = ""
    @State private var disconnect = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(platform.title + " 连接", systemImage: platform.symbol).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭连接设置")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(credentials.usesAccount(platform) ? "使用已导入会话（由平台验证有效性）" : "访客模式 · 无需登录")
                        .font(.headline)
                    Text("关注列表只保存在本机。访客可读取公开直播；受登录限制的内容可使用自己的会话。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("使用访客") { credentials.useGuest(platform); message = "已切换到访客模式。" }
                        if credentials.hasCookies(platform) {
                            Button("使用已导入会话") { perform { try credentials.useSavedAccount(platform) } }
                            Button("移除会话", role: .destructive) { disconnect = true }
                        }
                    }
                    Divider()
                    Text("连接自己的账号").font(.headline)
                    Text("先在官网登录，再导入仅包含该平台的 Netscape Cookies 文本。会话可代表你的账号，请只导入自己的文件；应用不会读取浏览器数据库。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("打开官网登录") { NSWorkspace.shared.open(platform.loginURL) }
                        Button("导入 Cookies…") {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                perform { try credentials.importCookies(url, platform: platform); message = "会话已导入 Keychain，等待下一次平台请求验证。" }
                            }
                        }
                    }
                    Text("仅保存所选平台的有效 Cookie；临时调用文件权限为 0600，用后删除。不会上传会话到 SimuSub 服务器。")
                        .font(.caption).foregroundStyle(.secondary)
                    if platform != .bilibili {
                        Divider()
                        DisclosureGroup("高级 · 官方搜索接口（可选）") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(platform == .youtube ? "YouTube API Key 用于频道关键词搜索；直播检查与录制仍使用公开频道或已导入会话。" : "Twitch 官方关键词搜索和开播检查需要 Client ID 与 Access Token；访客可以按英文频道名或链接添加。")
                                    .font(.caption).foregroundStyle(.secondary)
                                if platform == .twitch { TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder) }
                                SecureField(platform == .youtube ? "YouTube Data API Key" : "Twitch Access Token", text: $secret).textFieldStyle(.roundedBorder)
                                HStack {
                                    Button("保存到 Keychain") {
                                        perform { try credentials.saveAPIKey(secret, platform: platform, clientID: clientID); secret = ""; clientID = ""; message = "接口凭证已保存，下一次请求会验证有效性。" }
                                    }.disabled(secret.isEmpty || (platform == .twitch && clientID.isEmpty))
                                    if credentials.hasAPIKey(platform) {
                                        Button("移除接口凭证", role: .destructive) { perform { try credentials.removeAPIKey(platform) } }
                                    }
                                }
                                Link("官方接口申请说明", destination: URL(string: platform == .youtube ? "https://developers.google.com/youtube/v3/getting-started" : "https://dev.twitch.tv/docs/authentication/")!)
                            }.padding(.top, 12)
                        }
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }.padding(26).frame(width: 620, height: 590)
            .confirmationDialog("移除本机保存的 \(platform.title) 会话？", isPresented: $disconnect) {
                Button("移除并切换访客", role: .destructive) { perform { try credentials.disconnect(platform) } }
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { message = LiveMonitorStore.message(error) }
    }
}

struct SimuSubGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("使用 SimuSub").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Label("日中同传", systemImage: "captions.bubble").font(.headline)
            Text("打开字幕，点击播放，选择正在播放日语的应用。可切换日中双语或仅中文，并导出 TXT、SRT、VTT。")
            Label("主播监控", systemImage: "bell.badge").font(.headline)
            Text("搜索并添加主播后自动开启监控。悬停平台图标可选择访客、官网登录或导入 Cookies；点击平台切换搜索，小眼睛隐藏搜索。拖动卡片排序，缩放窗口调整头像大小，右键设置提醒和录制。底部铃铛开关监控；关闭窗口继续运行，退出或睡眠后停止。")
            Label("自动切片", systemImage: "scissors").font(.headline)
            Text("从主播下方的切片或首页高光切片进入，选择已保存的录制片段，或导入视频。设置时间范围、生成日中字幕并编辑后，勾选片段导出双语 MP4。原视频保留，可暂停、继续、取消或重试任务。先生成字幕再推荐高光，候选附时间与原因；预览确认后加入选段批量导出。")
            Spacer()
        }.padding(28).frame(width: 550, height: 470)
    }
}

struct PlatformAdvancedSettings: View {
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var selected: LivePlatform?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("平台设置").font(.title2.bold())
            Text("账号入口在首页平台图标旁。这里可管理已保存的会话和可选接口凭证。")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(LivePlatform.allCases) { platform in
                Button { selected = platform } label: {
                    HStack(spacing: 12) {
                        PlatformLogo(platform: platform).frame(width: 24, height: 24)
                        Text(platform.title)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }.padding(14).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
            Spacer()
        }.sheet(item: $selected) { LiveConnectionSheet(platform: $0, credentials: monitor.credentials) }
    }
}
