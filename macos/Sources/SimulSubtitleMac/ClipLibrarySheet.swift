import SwiftUI

struct ClipLibrarySheet: View {
    @EnvironmentObject private var clips: ClipStore
    @EnvironmentObject private var monitor: LiveMonitorStore
    var onProject: (UUID) -> Void
    var onRecording: (LiveRecording, URL) -> Void
    var onImport: () -> Void
    var onClose: () -> Void
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        let _ = themeID
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(L10n.text("项目与录制历史")).font(.system(size: 18, weight: .semibold))
                Spacer()

            }
            if clips.projects.isEmpty && monitor.recordings.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "tray").font(.system(size: 30, weight: .light))
                    Text(L10n.text("暂无项目")).font(.system(size: 13))
                }.foregroundStyle(ThemeColor.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !clips.projects.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("剪辑项目")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                                ForEach(clips.projects) { project in
                                    Button { onProject(project.id) } label: {
                                        row("scissors", title: project.name, detail: "\(project.ranges.count) 个选段 · " + ClipTime.label(project.media.duration))
                                    }.buttonStyle(.plain).disabled(clips.isBusy)
                                }
                            }
                        }
                        if !monitor.recordings.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(L10n.text("直播录制")).font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                                ForEach(monitor.recordings) { recording in
                                    VStack(alignment: .leading, spacing: 10) {
                                        row("record.circle", title: recording.creatorName, detail: recording.state.title)
                                        ForEach(Array(recording.closedMediaURLs.enumerated()), id: \.element.path) { index, url in
                                            Button { onRecording(recording, url) } label: {
                                                HStack {
                                                    Image(systemName: "film")
                                                    Text(L10n.text("导入片段 \(index + 1)")); Spacer(); Image(systemName: "arrow.up.left")
                                                }.font(.system(size: 12)).padding(12)
                                                    .background(ThemeColor.control, in: RoundedRectangle(cornerRadius: 10))
                                            }.buttonStyle(.plain).disabled(clips.isBusy)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Button(action: onImport) { Label(L10n.text("导入视频"), systemImage: "plus") }
                    .buttonStyle(ThemeActionButtonStyle()).disabled(clips.isBusy)
                Spacer()
                Button(L10n.text("完成"), action: onClose).buttonStyle(ThemeActionButtonStyle(prominent: true))
            }

        }.padding(28).frame(width: 640, height: 520)
            .background(ThemeColor.background).foregroundStyle(ThemeColor.ink)
            .accessibilityIdentifier("clips.librarySheet")
    }
    private func row(_ symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(ThemeColor.primary)
                .frame(width: 40, height: 40).background(ThemeColor.soft, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(L10n.text(detail)).font(.system(size: 11)).foregroundStyle(ThemeColor.muted)
            }
            Spacer()
            if symbol == "scissors" { Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(ThemeColor.muted) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}
