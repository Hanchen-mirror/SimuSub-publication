import SwiftUI

struct UsageAboutSettingsView: View {
    enum Page { case guide, about }

    @ObservedObject private var localization = AppLocalization.shared
    @State private var page: Page
    @State private var readingLicense = false

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
        .sheet(isPresented: $readingLicense) {
            licenseReader(title: copy.licenseTitle)
        }
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
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading(copy.licenseTitle, symbol: "doc.text")
                paragraph(copy.licenseSummary)
                Button { readingLicense = true } label: {
                    Label(copy.licenseLinkTitle, systemImage: "doc.plaintext")
                        .interfaceFont(size: 14, weight: .medium)
                }
                .buttonStyle(ThemeActionButtonStyle())
                .accessibilityIdentifier("usage.readLicense")
            }
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
                            Text(verbatim: model.name).interfaceFont(size: 15, weight: .semibold)
                                .foregroundStyle(ThemeColor.ink).fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: model.author + " · " + model.role).interfaceFont(size: 14)
                                .foregroundStyle(ThemeColor.muted).fixedSize(horizontal: false, vertical: true)
                            externalLink(model.url, label: model.name)
                        }
                        .padding(.vertical, 10)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ThemeColor.line) }
            }
            separator
            VStack(alignment: .leading, spacing: 9) {
                sectionHeading(copy.mentorTitle, symbol: "person")
                paragraph(copy.mentorBody)
                externalLink(copy.mentorLink.url, label: copy.mentorLink.title, showLabel: true)
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

    private func externalLink(_ url: URL, label: String, showLabel: Bool = false) -> some View {
        let address = url.absoluteString.replacingOccurrences(of: "https://", with: "")
        return Link(destination: url) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.up.right.square").font(.system(size: 13)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if showLabel { Text(verbatim: label).interfaceFont(size: 14, weight: .medium) }
                    Text(verbatim: address).underline().interfaceFont(size: 14)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(ThemeColor.primaryInk).padding(.vertical, 3)
        }
        .help(url.absoluteString)
        .accessibilityLabel(label + ", " + address)
    }

    private func licenseReader(title: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title).interfaceFont(size: 20, weight: .semibold).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { readingLicense = false } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).help(L10n.text("关闭")).accessibilityLabel(L10n.text("关闭"))
                .keyboardShortcut(.cancelAction)
            }
            separator
            ScrollView {
                Text(verbatim: Self.license ?? unavailableLicense)
                    .font(.system(size: 14, design: .monospaced)).lineSpacing(5)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(ThemeColor.ink).padding(20)
        .frame(minWidth: 320, idealWidth: 520, maxWidth: 620, minHeight: 280, idealHeight: 400, maxHeight: 520)
        .background(ThemeColor.background)
        .accessibilityIdentifier("usage.license")
    }

    private var unavailableLicense: String {
        switch localization.language {
        case .english: return "The license file could not be read."
        case .japanese: return "ライセンスファイルを読み込めませんでした。"
        default: return localization.language.normalizeScript("无法读取许可证文件。")
        }
    }

    private static let mark = Bundle.main.url(forResource: "SimuSubMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    private static let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let version: String? = {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        return (info?["CFBundleVersion"] as? String).map { version + " (" + $0 + ")" } ?? version
    }()
}
