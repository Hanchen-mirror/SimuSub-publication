import SwiftUI

@MainActor
struct CreatorSearchField: View {
    @ObservedObject var presentation: CreatorSearchState
    @EnvironmentObject private var monitor: LiveMonitorStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var request: Task<Void, Never>?
    @FocusState private var focused: Bool

    static func popupHeight(presentation: CreatorSearchState, monitor: LiveMonitorStore) -> CGFloat {
        guard presentation.resultsVisible else { return 0 }
        if monitor.isSearching { return 76 }
        if monitor.searchError != nil { return 108 }
        return min(208, max(76, CGFloat(monitor.results.count) * 64 + 8))
    }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(ThemeColor.muted)
                TextField(L10n.text("搜索主播或粘贴直播链接"), text: $presentation.query)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                    .onSubmit(search).accessibilityIdentifier("home.search.field")
                Button {
                    request?.cancel(); request = nil
                    presentation.query = ""; monitor.clearSearch(); presentation.resultsVisible = false
                    focused = true
                } label: { Image(systemName: "xmark").frame(width: 22, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(ThemeColor.muted)
                    .help(L10n.text("清空搜索")).accessibilityLabel(L10n.text("清空搜索")).accessibilityIdentifier("home.search.clear")
                Button {
                    request?.cancel(); monitor.clearSearch(); focused = false
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.88)) { presentation.resultsVisible = false }
                } label: { Image(systemName: "chevron.up").frame(width: 22, height: 28) }
                    .buttonStyle(.plain).disabled(!presentation.resultsVisible).help(L10n.text("收起搜索结果"))
                    .accessibilityLabel(L10n.text("收起搜索结果")).accessibilityIdentifier("home.search.hide")
            }.padding(.horizontal, 16).frame(height: 46)
                .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ThemeColor.line, lineWidth: 1))
            if presentation.resultsVisible {
                popup.frame(height: max(1, Self.popupHeight(presentation: presentation, monitor: monitor) - 8))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ThemeColor.ink.opacity(0.08)))
                    .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
                    .transition(.opacity)
            }
        }
        .onChange(of: presentation.query) { _ in request?.cancel(); monitor.clearSearch(); presentation.resultsVisible = false }
        .onChange(of: presentation.platform) { _ in request?.cancel(); monitor.clearSearch(); focused = false }
        .onDisappear { request?.cancel(); monitor.clearSearch() }
    }
    @ViewBuilder private var popup: some View {
        if monitor.isSearching {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L10n.text("正在搜索 \(presentation.platform.title)…")).font(.callout).foregroundStyle(ThemeColor.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = monitor.searchError {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text(error)).font(.caption).foregroundStyle(ThemeColor.muted).lineLimit(3)
                HStack {
                    Button(L10n.text("官网搜索")) { NSWorkspace.shared.open(presentation.platform.searchURL(presentation.query)) }
                    Spacer()
                    Button(L10n.text("收起")) { presentation.resultsVisible = false }
                }.font(.caption)
            }.padding(14)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(monitor.results) { candidate in
                        HStack(spacing: 12) {
                            PlatformAvatar(url: candidate.avatarURL, platform: candidate.platform).frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 11))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(candidate.platform.title).font(.caption).foregroundStyle(ThemeColor.muted)
                            }
                            Spacer()
                            Button {
                                if monitor.addAndMonitor(candidate) { presentation.resultsVisible = false }
                            } label: {
                                Image(systemName: monitor.follows(candidate) ? "checkmark" : "plus")
                                    .font(.system(size: 16, weight: .medium)).frame(width: 30, height: 30)
                                    .background(candidate.platform.color.opacity(0.12), in: Circle())
                            }.buttonStyle(.plain).disabled(monitor.follows(candidate))
                                .help(L10n.text(monitor.follows(candidate) ? "已添加" : "添加主播"))
                                .accessibilityLabel(L10n.text("添加 \(candidate.name)")).accessibilityIdentifier("home.search.add.\(candidate.id)")
                        }.padding(.horizontal, 14).frame(height: 64)
                    }
                }.padding(.vertical, 4)
            }.scrollIndicators(.hidden)
        }
    }
    private func search() {
        guard !presentation.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        request?.cancel(); presentation.resultsVisible = true
        let query = presentation.query, platform = presentation.platform
        request = Task { await monitor.search(query, platform: platform) }
    }
}

struct PlatformAvatar: View {
    var url: String?
    var platform: LivePlatform
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        Group {
            if let url, let address = URL(string: url), address.scheme == "https" {
                AsyncImage(url: address, transaction: Transaction(animation: .easeOut(duration: 0.18))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { placeholder }
                }
            } else { placeholder }
        }.clipped().accessibilityHidden(true)
    }
    private var placeholder: some View {
        LinearGradient(colors: [platform.color.opacity(0.19), platform.color.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(PlatformLogo(platform: platform).frame(width: 34, height: 34).opacity(0.55))
    }
}
