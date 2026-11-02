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
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        VStack(alignment: .leading, spacing: 24) {
            Text("录制").font(.system(size: 16, weight: .semibold))
            HStack { Text("保存位置"); Spacer(); Button(action: monitor.chooseFolder) { Label("选择文件夹", systemImage: "folder") }.buttonStyle(ThemeActionButtonStyle()) }.help(monitor.settings.outputFolder)
            HStack(spacing: 17) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("格式").font(.caption).foregroundStyle(ThemeColor.muted)
                    DesignMenuField(title: monitor.settings.container.title) { ForEach(RecordingContainer.allCases) { value in Button(value.title) { monitor.updateSettings { $0.container = value } } } }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text("同时录制").font(.caption).foregroundStyle(ThemeColor.muted)
                    DesignMenuField(title: "\(monitor.settings.maximumRecordings)") { ForEach(1...3, id: \.self) { value in Button("\(value)") { monitor.updateSettings { $0.maximumRecordings = value } } } }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("检查间隔").font(.caption).foregroundStyle(ThemeColor.muted)
                DesignMenuField(title: "\(monitor.settings.intervalSeconds / 60) 分钟") { ForEach(1...15, id: \.self) { value in Button("\(value) 分钟") { monitor.updateSettings { $0.intervalSeconds = value * 60 } } } }
            }
        }.designPanel()
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
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
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
                        .font(.callout).foregroundStyle(ThemeColor.muted)
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
                        .font(.caption).foregroundStyle(ThemeColor.muted)
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
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    if platform != .bilibili {
                        Divider()
                        DisclosureGroup("高级 · 官方搜索接口（可选）") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(platform == .youtube ? "YouTube API Key 用于频道关键词搜索；直播检查与录制仍使用公开频道或已导入会话。" : "Twitch 官方关键词搜索和开播检查需要 Client ID 与 Access Token；访客可以按英文频道名或链接添加。")
                                    .font(.caption).foregroundStyle(ThemeColor.muted)
                                if platform == .twitch { TextField("Client ID", text: $clientID).textFieldStyle(ClipFieldStyle()) }
                                SecureField(platform == .youtube ? "YouTube Data API Key" : "Twitch Access Token", text: $secret).textFieldStyle(ClipFieldStyle())
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
                    if let message { Text(message).font(.callout).foregroundStyle(ThemeColor.muted) }
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
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("使用 SimuSub").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Label("日中同传", systemImage: "captions.bubble").font(.headline)
            Text("在日中同传页选择声音来源与模型，然后开始同传。日语和中文可分别选择字体；浮窗可拖大查看历史，切换双语或仅中文，并导出 TXT、SRT、VTT。")
            Label("主播监控", systemImage: "bell.badge").font(.headline)
            Text("在直播录制页搜索并添加主播。平台入口可管理访客或导入的会话；右键主播可调整监控、提醒和自动录制。录制设置中可选择保存目录。关闭窗口继续运行，退出或睡眠后停止监控。")
            Label("自动切片", systemImage: "scissors").font(.headline)
            Text("从侧栏或首页打开独立剪辑窗，导入视频或已保存的录制。可新增、切换和删除选段，分别编辑日中字幕并设置样式；勾选片段后批量导出。原视频保留，任务可暂停或重试。高光候选由本地规则推荐；云端识别与核对会在调用前说明费用。")
            Spacer()
        }.padding(28).frame(width: 550, height: 470)
    }
}

struct PlatformAdvancedSettings: View {
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var selected: LivePlatform?
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                Button { selected = nil } label: { Image(systemName: "display").frame(width: 32, height: 32).background(selected == nil ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 8)) }.help("全部平台")
                ForEach(LivePlatform.allCases) { platform in Button { selected = platform } label: { PlatformLogo(platform: platform).frame(width: 18, height: 18).frame(width: 32, height: 32).background(selected == platform ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 8)) }.help(platform.title) }
            }.buttonStyle(.plain)
            ForEach(LivePlatform.allCases.filter { selected == nil || $0 == selected }) { platform in
                PlatformConnectionCard(platform: platform, credentials: monitor.credentials)
            }
        }
    }
}
struct PlatformConnectionCard: View {
    let platform: LivePlatform
    @ObservedObject var credentials: LiveCredentials
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 11) { PlatformLogo(platform: platform).frame(width: 22, height: 22); Text(platform.title).font(.system(size: 16, weight: .semibold)) }
            HStack(spacing: 10) {
                Button { credentials.useGuest(platform) } label: { Text("访客").frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle()).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(credentials.usesAccount(platform) ? ThemeColor.line : ThemeColor.primary))
                Button { NSWorkspace.shared.open(platform.loginURL) } label: { Label("官网登录", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle())
                Button { importCookies() } label: { Text("导入 Cookies").frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle())
            }
            if let message { Text(message).font(.caption).foregroundStyle(ThemeColor.muted) }
        }.designPanel()
    }
    private func importCookies() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try credentials.importCookies(url, platform: platform); message = "已导入" }
        catch { message = LiveMonitorStore.message(error) }
    }
}
