import SwiftUI

struct HomeRecordingBar: View {
    let creator: WatchedCreator
    var onClips: () -> Void
    @EnvironmentObject private var monitor: LiveMonitorStore
    @State private var discarding = false
    private var latest: LiveRecording? { monitor.activeRecording(creator.id) ?? monitor.recordings.first { $0.creatorID == creator.id } }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        HStack(spacing: 12) {
            let active = monitor.activeRecording(creator.id)
            Button {
                if let active { monitor.stopRecording(active.id) } else { monitor.startRecording(creator.id) }
            } label: {
                Label(active == nil ? "录制" : active?.state == .stopping ? "保存中" : "停止保存", systemImage: active == nil ? "record.circle.fill" : "stop.circle.fill").foregroundStyle(.red)
            }.disabled(active?.state == .preparing || active?.state == .stopping || (active == nil && CreatorBadge(creator) != .live))
                .accessibilityIdentifier("home.record.\(creator.id)")
            Button {
                guard let active else { return }
                if active.state == .paused { monitor.resumeRecording(active.id) } else { monitor.pauseRecording(active.id) }
            } label: { Label(active?.state == .paused ? "继续" : "暂停", systemImage: active?.state == .paused ? "play.fill" : "pause.fill") }
                .disabled(active == nil || ![LiveRecordingState.recording, .paused].contains(active!.state)).help("暂停会先保存片段，继续后写入新片段")
            Button { if let latest { monitor.convertRecording(latest.id) } } label: { Label("转换", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(latest == nil || latest.map { monitor.convertingIDs.contains($0.id) } == true).help("停止录制并把已保存片段转换为 MP4，保留原文件")
            Button(action: monitor.showFolder) { Image(systemName: "folder") }.help("打开录制文件夹").accessibilityLabel("打开录制文件夹")
            Button { discarding = true } label: { Image(systemName: "xmark") }.disabled(latest == nil || latest.map { monitor.convertingIDs.contains($0.id) } == true).help("丢弃本次录制，移到废纸篓").accessibilityLabel("丢弃本次录制")
            if let latest { TimelineView(.periodic(from: .now, by: 1)) { _ in Text(ClipTime.label(latest.elapsed).components(separatedBy: ".")[0]).font(.system(size: 11, design: .monospaced)).foregroundStyle(ThemeColor.muted) } }
        }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ThemeColor.ink.opacity(0.1)))
            .confirmationDialog("丢弃本次录制？录像片段会移到系统废纸篓。", isPresented: $discarding, titleVisibility: .visible) {
                Button("停止并移到废纸篓", role: .destructive) { if let latest { Task { await monitor.discardRecording(latest.id) } } }
                Button("取消", role: .cancel) {}
            }
    }
}
