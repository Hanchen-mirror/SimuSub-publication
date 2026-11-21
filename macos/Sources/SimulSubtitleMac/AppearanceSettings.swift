import AppKit
import SwiftUI

struct AppearanceSettings: View {
    var compact = false
    var inset: CGFloat = DesignV23.panelInset
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 24) {
            let heading = compact ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
            heading {
                Text(L10n.text("外观")).interfaceFont(size: 16, weight: .semibold)
                if !compact { Spacer() }
                InterfaceLanguageSettings()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 12)], spacing: 12) {
                ForEach(AppearanceMode.allCases) { mode in
                    Button { appearance.mode = mode } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            GeometryReader { geometry in
                                ZStack {
                                    modePreview(mode == .system ? .light : mode)
                                    if mode == .system {
                                        modePreview(.dark).mask(alignment: .trailing) {
                                            Rectangle().frame(width: geometry.size.width / 2)
                                        }
                                    }
                                }
                            }.frame(height: 70).clipShape(RoundedRectangle(cornerRadius: 7))
                            HStack { Text(L10n.text(mode.title)); Spacer(); if appearance.mode == mode { Image(systemName: "checkmark") } }
                        }.interfaceFont(size: 12).padding(10).frame(maxWidth: .infinity)
                            .background(appearance.mode == mode ? ThemeColor.soft : ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.mode == mode ? ThemeColor.primary : ThemeColor.line))
                    }.buttonStyle(.plain).accessibilityIdentifier("appearance.mode." + mode.rawValue)
                }
            }
            ThemeColorChoices(compact: false)
            Toggle(L10n.text("SimuSub 字标扫光"), isOn: $appearance.wordmarkSheen)
                .toggleStyle(DesignToggleStyle()).frame(height: 32)
                .accessibilityIdentifier("appearance.wordmarkSheen")
            Toggle(L10n.text("减少动态效果"), isOn: $appearance.reduceMotion).toggleStyle(DesignToggleStyle()).frame(height: 32)
            Toggle(L10n.text("清空字幕前询问"), isOn: $appearance.askBeforeClearing)
                .toggleStyle(DesignToggleStyle()).frame(height: 32)
                .accessibilityIdentifier("appearance.askBeforeClearing")
            Toggle(L10n.text("恢复上次窗口"), isOn: $appearance.restorePage).toggleStyle(DesignToggleStyle()).frame(height: 32)
        }.designPanel(inset: inset)
    }
    private func modePreview(_ mode: AppearanceMode) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(sample(mode, .sidebar)).frame(width: 24)
            RoundedRectangle(cornerRadius: 4).fill(sample(mode, .surface)).padding(.vertical, 8)
        }.padding(8).background(sample(mode, .background))
    }
    private func sample(_ mode: AppearanceMode, _ role: ThemeRole) -> Color {
        Color(nsColor: ThemePalette.color(appearance.theme, dark: mode == .dark || (mode == .system && appearance.isDark), role: role))
    }
}

struct SubtitleFontSettings: View {
    var stacked = false
    var inlineSizes = false
    @EnvironmentObject private var appearance: HomeAppearance
    private var families: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        if inlineSizes {
            VStack(spacing: 12) {
                typographyRow("原文", fontTitle: "原文字体", sizeTitle: "原文字号", family: $appearance.japaneseFont, size: $appearance.japaneseSize)
                typographyRow("译文", fontTitle: "译文字体", sizeTitle: "译文字号", family: $appearance.chineseFont, size: $appearance.chineseSize)
            }
        } else {
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
            layout {
                fontPicker("原文字体", selection: $appearance.japaneseFont)
                fontPicker("译文字体", selection: $appearance.chineseFont)
            }
        }
    }
    private func typographyRow(_ title: String, fontTitle: String, sizeTitle: String, family: Binding<String>, size: Binding<Double>) -> some View {
        let label = Text(L10n.text(title)).interfaceFont(size: 12).foregroundStyle(ThemeColor.muted)
        let controls = HStack(spacing: 8) {
            fontMenu(fontTitle, selection: family, height: 38)
                .frame(maxWidth: 164)
            DesignMenuField(title: "\(Int(size.wrappedValue)) px", height: 38) {
                ForEach([12.0, 14, 16, 18, 20, 22, 24, 28, 32], id: \.self) { value in
                    Button("\(Int(value)) px") { size.wrappedValue = value }
                }
            }.frame(width: 80).help(L10n.text(sizeTitle)).accessibilityLabel(L10n.text(sizeTitle))
                .accessibilityValue("\(Int(size.wrappedValue)) px")
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                // Both rows reserve the width of the longer translated label.
                ZStack(alignment: .leading) {
                    ForEach(["原文", "译文"], id: \.self) { key in
                        Text(L10n.text(key)).interfaceFont(size: 12).hidden().accessibilityHidden(true)
                    }
                    label
                }.fixedSize()
                controls.frame(width: 252)
            }
            VStack(alignment: .leading, spacing: 6) {
                label
                controls
            }
        }.frame(maxWidth: .infinity, alignment: .center)
    }
    private func fontPicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).interfaceFont(size: 12)
            fontMenu(title, selection: selection, height: 44)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fontMenu(_ title: String, selection: Binding<String>, height: CGFloat) -> some View {
        let selected = selection.wrappedValue.isEmpty ? L10n.text("系统字体") : selection.wrappedValue
        return DesignMenuField(title: selected, height: height) {
            Button(L10n.text("系统字体")) { selection.wrappedValue = "" }
            ForEach(families, id: \.self) { family in Button(family) { selection.wrappedValue = family } }
        }.help(L10n.text(title) + " · " + selected).accessibilityLabel(L10n.text(title)).accessibilityValue(selected)
    }
}

enum SubtitleFont {
    static func native(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        family.isEmpty ? .systemFont(ofSize: size, weight: weight) : NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
