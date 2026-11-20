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

/// Keep each option at its natural width, including localized text and its checkmark.
private struct RecordingChoiceFlow: Layout {
    private let gap: CGFloat = 6

    private func layout(_ views: Subviews, width: CGFloat?) -> (CGSize, [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in views {
            let size = view.sizeThatFits(.unspecified)
            if let width, x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            widest = max(widest, x + size.width)
            rowHeight = max(rowHeight, size.height)
            x += size.width + gap
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews, width: proposal.width).0
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let points = layout(subviews, width: bounds.width).1
        for (item, point) in zip(subviews, points) {
            item.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                       anchor: .topLeading, proposal: .unspecified)
        }
    }
}

struct LiveRecordingSettings: View {
    @EnvironmentObject private var monitor: LiveMonitorStore
    @Environment(\.appThemeID) private var themeID
    @AppStorage("clips.exportFolder.v150") private var exportFolder = ""
    private var exportPath: String {
        exportFolder.isEmpty ? NSHomeDirectory() + "/Movies/SimuSub/Exports" : exportFolder
    }
    var body: some View {
        let _ = themeID
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("录制与剪辑")).interfaceFont(size: 16, weight: .semibold)
            VStack(spacing: 0) {
                destination(symbol: "video", path: monitor.settings.outputFolder, label: "录制文件夹", action: monitor.chooseFolder)
                Divider().overlay(ThemeColor.line)
                destination(symbol: "square.and.arrow.up", path: exportPath, label: "导出文件夹", action: chooseExportFolder)
            }.designPanel(inset: 18)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("录制质量")).font(.headline)
                recordingChoiceRow("格式") {
                    ForEach(RecordingContainer.allCases) { value in
                        recordingChoice(value.title, selected: monitor.settings.container == value) {
                            monitor.updateSettings { $0.container = value }
                        }
                        .accessibilityIdentifier("recording.format." + value.rawValue)
                    }
                }
                Divider().overlay(ThemeColor.line)
                HStack {
                    Text(L10n.text("画质")); Spacer()
                    DesignMenuField(title: L10n.text(monitor.settings.quality.title)) {
                        ForEach(RecordingQuality.allCases) { quality in Button(L10n.text(quality.title)) { monitor.updateSettings { $0.quality = quality } } }
                    }.frame(width: 116).accessibilityIdentifier("recording.quality")
                }
            }.designPanel(inset: 20)
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("录制行为")).font(.headline)
                recordingChoiceRow("同时录制") {
                    ForEach(1...3, id: \.self) { count in
                        let labels = [L10n.text("1 路"), L10n.text("2 路"), L10n.text("3 路")]
                        recordingChoice(labels[count - 1], selected: count == monitor.settings.maximumRecordings) {
                            monitor.updateSettings { $0.maximumRecordings = count }
                        }
                        .accessibilityIdentifier("recording.concurrent." + String(count))
                    }
                }
                Divider().overlay(ThemeColor.line)
                HStack {
                    Text(L10n.text("检查间隔")); Spacer()
                    DesignMenuField(title: L10n.text(monitor.settings.intervalSeconds < 60 ? "\(monitor.settings.intervalSeconds) 秒" : "\(monitor.settings.intervalSeconds / 60) 分钟")) {
                        ForEach([15, 30] + (1...15).map { $0 * 60 }, id: \.self) { value in
                            Button(L10n.text(value < 60 ? "\(value) 秒" : "\(value / 60) 分钟")) { monitor.updateSettings { $0.intervalSeconds = value } }
                        }
                    }.frame(width: 116).accessibilityIdentifier("recording.interval")
                }
            }.designPanel(inset: 20)
        }
    }
    private func recordingChoiceRow<Choices: View>(_ title: String, @ViewBuilder choices: () -> Choices) -> some View {
        let label = Text(L10n.text(title)).fixedSize()
        let options = HStack(spacing: 6) { choices() }.fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack { label; Spacer(minLength: 12); options }
            VStack(alignment: .leading, spacing: 8) {
                label
                RecordingChoiceFlow { choices() }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text(title))
    }

    private func recordingChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
                Text(verbatim: title).interfaceFont(size: 12, weight: .semibold)
            }
            .padding(.horizontal, 9).frame(minWidth: 52, minHeight: 32)
            .foregroundStyle(selected ? ThemeColor.primaryInk : ThemeColor.muted)
            .background(selected ? ThemeColor.selection : ThemeColor.control, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? ThemeColor.primary : ThemeColor.line) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func destination(symbol: String, path: String, label: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(ThemeColor.primaryInk).frame(width: 36, height: 36).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 10))
            Text((path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).help(path)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: { Image(systemName: "doc.on.doc").frame(width: 32, height: 30) }
            .buttonStyle(.plain)
            .help(L10n.text("复制路径"))
            .accessibilityLabel(L10n.text(label) + " · " + L10n.text("复制路径"))
            Button(action: action) { Image(systemName: "folder").frame(width: 32, height: 30) }
                .buttonStyle(.plain).background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 9))
                .help(L10n.text("更换文件夹")).accessibilityLabel(L10n.text(label) + " · " + L10n.text("更换文件夹"))
        }.padding(.vertical, 7)
    }
    private func chooseExportFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: exportPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { exportFolder = url.path }
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
                Label(L10n.text(platform.title + " 连接"), systemImage: platform.symbol).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.text("关闭连接设置"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text(credentials.selectedSource(platform) == .browser ? "已连接浏览器会话" : (credentials.usesAccount(platform) ? "使用已导入会话（由平台验证有效性）" : "访客模式 · 无需登录")))
                        .font(.headline)
                    Text(L10n.text("关注列表只保存在本机。访客可读取公开直播；受登录限制的内容可使用自己的会话。"))
                        .font(.callout).foregroundStyle(ThemeColor.muted)
                    HStack {
                        Button(L10n.text("使用访客")) { credentials.useGuest(platform); message = "已切换到访客模式。" }
                        if credentials.hasCookies(platform) {
                            Button(L10n.text("使用已导入会话")) { perform { try credentials.useSavedAccount(platform) } }
                            Button(L10n.text("移除会话"), role: .destructive) { disconnect = true }
                        }
                    }
                    Divider()
                    Text(L10n.text("连接自己的账号")).font(.headline)
                    Text(L10n.text(platform == .youtube ? "优先使用已接入的浏览器会话；未接入时使用已导入的 Cookies，没有会话则使用访客。" : "使用访客访问公开内容，或导入自己的 Cookies 会话。"))
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    HStack {
                        Button(L10n.text("打开官网登录")) { credentials.openLogin(platform) }
                        Button(L10n.text("导入 Cookies…")) {
                            let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                perform { try credentials.importCookies(url, platform: platform); message = "会话已导入 Keychain，等待下一次平台请求验证。" }
                            }
                        }
                    }
                    Text(L10n.text("仅保存所选平台的有效 Cookie；临时调用文件权限为 0600，用后删除。不会上传会话到 SimuSub 服务器。"))
                        .font(.caption).foregroundStyle(ThemeColor.muted)
                    if platform != .bilibili {
                        Divider()
                        DisclosureGroup(L10n.text("高级 · 官方搜索接口（可选）")) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text(platform == .youtube ? "YouTube API Key 用于频道关键词搜索；直播检查与录制仍使用公开频道或已导入会话。" : "Twitch 官方关键词搜索和开播检查需要 Client ID 与 Access Token；访客可以按英文频道名或链接添加。"))
                                    .font(.caption).foregroundStyle(ThemeColor.muted)
                                if platform == .twitch { TextField("Client ID", text: $clientID).textFieldStyle(ClipFieldStyle()) }
                                SecureField(platform == .youtube ? "YouTube Data API Key" : "Twitch Access Token", text: $secret).textFieldStyle(ClipFieldStyle())
                                HStack {
                                    Button(L10n.text("保存到 Keychain")) {
                                        perform { try credentials.saveAPIKey(secret, platform: platform, clientID: clientID); secret = ""; clientID = ""; message = "接口凭证已保存，下一次请求会验证有效性。" }
                                    }.disabled(secret.isEmpty || (platform == .twitch && clientID.isEmpty))
                                    if credentials.hasAPIKey(platform) {
                                        Button(L10n.text("移除接口凭证"), role: .destructive) { perform { try credentials.removeAPIKey(platform) } }
                                    }
                                }
                                Link("官方接口申请说明", destination: URL(string: platform == .youtube ? "https://developers.google.com/youtube/v3/getting-started" : "https://dev.twitch.tv/docs/authentication/")!)
                            }.padding(.top, 12)
                        }
                    }
                    if let message { Text(L10n.text(message)).font(.callout).foregroundStyle(ThemeColor.muted) }
                }
            }
        }.padding(26).frame(width: 620, height: 590)
            .confirmationDialog(L10n.text("移除本机保存的 \(platform.title) 会话？"), isPresented: $disconnect) {
                Button(L10n.text("移除并切换访客"), role: .destructive) { perform { try credentials.disconnect(platform) } }
            }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { message = LiveMonitorStore.message(error) }
    }
}

struct SimuSubGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView { UsageAboutSettingsView().padding(20) }
            Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .frame(width: 560, height: 500)
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
                Button { selected = nil } label: { Image(systemName: "display").frame(width: 32, height: 32).background(selected == nil ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 8)) }.help(L10n.text("全部平台"))
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
            HStack(spacing: 11) { PlatformLogo(platform: platform).frame(width: 22, height: 22); Text(platform.title).interfaceFont(size: 16, weight: .semibold) }
            HStack(spacing: 10) {
                Button { credentials.useGuest(platform) } label: { Text(L10n.text("访客")).frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle()).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(credentials.selectedSource(platform) == .guest ? ThemeColor.primary : ThemeColor.line))
                Button { credentials.openLogin(platform) } label: { Label(L10n.text("官网登录"), systemImage: "arrow.up.right.square").frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle()).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(credentials.selectedSource(platform) == .browser ? ThemeColor.primary : ThemeColor.line)).accessibilityAddTraits(credentials.selectedSource(platform) == .browser ? .isSelected : [])
                Button { importCookies() } label: { Text(L10n.text("导入 Cookies")).frame(maxWidth: .infinity) }.buttonStyle(ThemeActionButtonStyle()).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(credentials.selectedSource(platform) == .cookies ? ThemeColor.primary : ThemeColor.line))
            }
            if let message { Text(L10n.text(message)).font(.caption).foregroundStyle(ThemeColor.muted) }
        }.designPanel()
            .task { await credentials.refreshBrowserSession(platform) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await credentials.refreshBrowserSession(platform) }
            }
    }
    private func importCookies() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try credentials.importCookies(url, platform: platform); message = "已导入" }
        catch { message = LiveMonitorStore.message(error) }
    }
}
