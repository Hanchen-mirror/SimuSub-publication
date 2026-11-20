import SwiftUI

struct UsageAboutSettingsView: View {
    enum Page { case guide, about }

    @ObservedObject private var localization = AppLocalization.shared
    @State private var page: Page

    init(initialPage: Page = .guide) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        let copy = UsageAboutContent(language: localization.language)
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .bottom, spacing: 22) {
                navigation(.guide, title: copy.guideTitle, symbol: "book")
                navigation(.about, title: copy.aboutTitle, symbol: "info.circle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(ThemeColor.line).frame(height: 1) }
            .accessibilityIdentifier("usage.page")

            if page == .guide { guide(copy) } else { about(copy) }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navigation(_ destination: Page, title: String, symbol: String) -> some View {
        let selected = page == destination
        return Button { page = destination } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                    Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
                }
                .interfaceFont(size: 15, weight: selected ? .semibold : .regular)
                .padding(.horizontal, 2).padding(.top, 4)
                Rectangle().fill(selected ? ThemeColor.primaryInk : .clear).frame(height: 3)
            }
            .fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(selected ? ThemeColor.primaryInk : ThemeColor.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(destination == .guide ? "usage.nav.guide" : "usage.nav.about")
    }

    private func guide(_ copy: UsageAboutContent) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(copy.guideSections.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 13) {
                    sectionHeading(item.title, symbol: item.symbol)
                    ForEach(item.steps.indices, id: \.self) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: String(step + 1) + ".").monospacedDigit()
                                .interfaceFont(size: 14, weight: .medium)
                                .foregroundStyle(ThemeColor.primaryInk).frame(minWidth: 20, alignment: .trailing)
                            paragraph(item.steps[step])
                        }
                    }
                }
                if index + 1 < copy.guideSections.count { separator }
            }
        }
        .accessibilityIdentifier("usage.guide")
    }

    private func about(_ copy: UsageAboutContent) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 13) {
                if let mark = Self.mark {
                    Image(nsImage: mark).resizable().scaledToFit().frame(width: 46, height: 46)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "SimuSub").interfaceFont(size: 26, weight: .semibold)
                        .foregroundStyle(ThemeColor.ink).accessibilityAddTraits(.isHeader)
                    if let version = Self.version {
                        Text(verbatim: version).interfaceFont(size: 13).foregroundStyle(ThemeColor.muted)
                    }
                }
            }
            paragraph(copy.licenseSummary)
            separator
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading(copy.originTitle, symbol: "captions.bubble")
                paragraph(copy.originBody)
            }
            separator
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading(copy.modelsTitle, symbol: "waveform")
                paragraph(copy.modelsIntro)
            }
            ForEach(Array(copy.modelGroups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: group.title).interfaceFont(size: 16, weight: .semibold)
                        .foregroundStyle(ThemeColor.ink).accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 7)
                    ForEach(Array(group.models.enumerated()), id: \.offset) { index, model in
                        if index > 0 { separator }
                        VStack(alignment: .leading, spacing: 4) {
                            externalLink(model.url, label: model.name)
                            Text(verbatim: model.author + " · " + model.role).interfaceFont(size: 14)
                                .foregroundStyle(ThemeColor.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 9)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            separator
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading(copy.mentorTitle, symbol: "person")
                paragraph(copy.mentorBody)
                externalLink(copy.mentorLink.url, label: copy.mentorLink.title)
            }
        }
        .accessibilityIdentifier("usage.about")
    }

    private var separator: some View { Rectangle().fill(ThemeColor.line).frame(height: 1) }

    private func sectionHeading(_ title: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(ThemeColor.primaryInk).frame(width: 22)
            Text(verbatim: title).interfaceFont(size: 20, weight: .semibold)
                .foregroundStyle(ThemeColor.ink).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func paragraph(_ text: String) -> some View {
        Text(verbatim: text).interfaceFont(size: 15).lineSpacing(5)
            .foregroundStyle(ThemeColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func externalLink(_ url: URL, label: String) -> some View {
        Link(destination: url) {
            Text(verbatim: label).underline().interfaceFont(size: 15, weight: .medium)
                .foregroundStyle(ThemeColor.primaryInk).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }

    private static let mark = Bundle.main.url(forResource: "SimuSubMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    private static let version: String? = {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (info?["CFBundleVersion"] as? String).map { version + " (" + $0 + ")" } ?? version
    }()
}
