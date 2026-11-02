import AppKit
import ScreenCaptureKit
import SwiftUI

struct ApplicationDockPicker: View {
    let applications: [CaptureApplication]
    let selectedBundleID: String?
    let isRefreshing: Bool
    var onRefresh: () -> Void
    var onSelect: (CaptureApplication) -> Void
    var onCancel: () -> Void
    @StateObject private var previews = ApplicationPreviewStore()
    @State private var hoveredID: String?
    @State private var search = ""
    private var filteredApps: [CaptureApplication] { applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search) } }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var focusedApp: CaptureApplication? {
        filteredApps.first { $0.id == hoveredID }
            ?? filteredApps.first { $0.id == selectedBundleID }
            ?? filteredApps.first
    }

    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 14) {
            HStack {
                Text("选择应用音频").font(.headline)
                Spacer()
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(isRefreshing)
                    .help("刷新应用").accessibilityLabel("刷新应用")
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    .help("取消选择").accessibilityLabel("取消选择")
            }

            TextField("搜索应用名称或标识…", text: $search).textFieldStyle(ClipFieldStyle()).accessibilityIdentifier("application.search")

            if let app = focusedApp {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(ThemeColor.ink.opacity(0.035))
                    if let preview = previews.images[app.id] {
                        Image(nsImage: preview).resizable().scaledToFit().padding(4)
                    } else {
                        VStack(spacing: 10) {
                            Image(nsImage: previews.icon(for: app)).resizable().scaledToFit()
                                .frame(width: 72, height: 72)
                            Text(app.name).font(.callout).foregroundStyle(ThemeColor.muted)
                        }
                    }
                }
                .frame(height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("\(app.name)的应用预览")
                Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "app.dashed").font(.system(size: 36, weight: .light))
                    Text(isRefreshing ? "正在读取应用…" : (search.isEmpty ? "请先打开 Safari 等应用，再刷新" : "没有匹配的应用"))
                        .font(.callout).foregroundStyle(ThemeColor.muted)
                }.frame(maxWidth: .infinity).frame(height: 207)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(filteredApps.enumerated()), id: \.element.id) { index, app in
                        dockIcon(app, index: index)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
            }
            .frame(height: 116)
            .background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 22))
            Text("点击图标选择声音来源 · 左右滑动查看更多应用")
                .font(.caption).foregroundStyle(ThemeColor.muted)
        }
        .padding(22)
        .frame(width: 680, height: 470)
        .background(ThemeColor.background)
        .task(id: focusedApp?.id) {
            if let app = focusedApp { await previews.loadPreview(for: app) }
        }
    }

    private func dockIcon(_ app: CaptureApplication, index: Int) -> some View {
        let active = hoveredID == app.id
        let hoveredIndex = filteredApps.firstIndex { $0.id == hoveredID }
        let neighbor = hoveredIndex.map { abs($0 - index) == 1 } ?? false
        return Button { onSelect(app) } label: {
            VStack(spacing: 8) {
                Image(nsImage: previews.icon(for: app)).resizable().scaledToFit()
                    .frame(width: 54, height: 54)
                    .shadow(color: .black.opacity(active ? 0.2 : 0.06), radius: active ? 8 : 3, y: 4)
                    .scaleEffect(reduceMotion ? 1 : (active ? 1.12 : (neighbor ? 1.04 : 1)), anchor: .bottom)
                    .offset(y: reduceMotion ? 0 : (active ? -8 : (neighbor ? -3 : 0)))
                Text(app.name).font(.system(size: 10, weight: active ? .medium : .regular))
                    .lineLimit(1).truncationMode(.tail).frame(width: 74)
                Circle().fill(app.id == selectedBundleID ? ThemeColor.primary : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 76, height: 86)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredID = app.id }
            else if hoveredID == app.id { hoveredID = nil }
        }
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 340, damping: 27), value: hoveredID)
        .help("监听 \(app.name)")
        .accessibilityLabel("监听 \(app.name)")
        .accessibilityIdentifier("application.\(app.id)")
    }
}

/// Thumbnails stay in memory only and are requested only for the focused app.
/// macOS 13.3 retains icon selection; window snapshots require macOS 14 or later.
@MainActor
private final class ApplicationPreviewStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var icons: [String: NSImage] = [:]
    private var unavailable: Set<String> = []

    func icon(for app: CaptureApplication) -> NSImage {
        if let cached = icons[app.id] { return cached }
        let image: NSImage
        if let running = NSRunningApplication(processIdentifier: app.processID)?.icon { image = running }
        else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else { image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: app.name) ?? NSImage() }
        icons[app.id] = image
        return image
    }

    func loadPreview(for app: CaptureApplication) async {
        guard #available(macOS 14.0, *), let windowID = app.windowID,
              images[app.id] == nil, !unavailable.contains(app.id) else { return }
        do {
            // Hovering quickly across the Dock does not capture every window.
            try await Task.sleep(nanoseconds: 160_000_000)
            let content = try await AudioCaptureEngine.shareableContent()
            try Task.checkCancellation()
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = 640
            configuration.height = max(1, min(480, Int(640 * window.frame.height / max(1, window.frame.width))))
            configuration.showsCursor = false
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image: CGImage = try await withCheckedThrowingContinuation { continuation in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? AudioCaptureError.noShareableContent) }
                }
            }
            try Task.checkCancellation()
            images[app.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            if !Task.isCancelled { unavailable.insert(app.id) }
        }
    }
}
