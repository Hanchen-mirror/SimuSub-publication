import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @EnvironmentObject private var appearance: HomeAppearance
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        VStack(alignment: .leading, spacing: 24) {
            Text("外观").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 15) {
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
                            HStack { Text(mode.title); Spacer(); if appearance.mode == mode { Image(systemName: "checkmark") } }
                        }.font(.system(size: 12)).padding(10).frame(maxWidth: .infinity)
                            .background(appearance.mode == mode ? ThemeColor.soft : ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.mode == mode ? ThemeColor.primary : ThemeColor.line))
                    }.buttonStyle(.plain).accessibilityIdentifier("appearance.mode." + mode.rawValue)
                }
            }
            HStack(spacing: 8) {
                ForEach(AppTheme.allCases) { theme in
                    Button { appearance.theme = theme } label: {
                        HStack(spacing: 9) {
                            Circle().fill(Color(nsColor: ThemePalette.color(theme, dark: false, role: .primary))).frame(width: 20, height: 20)
                                .overlay { if appearance.theme == theme { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                            Text(theme.title).font(.system(size: 12))
                        }.padding(.horizontal, 12).frame(height: 40)
                            .background(appearance.theme == theme ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("appearance.theme." + theme.rawValue)
                }
            }
            Toggle("减少动态效果", isOn: $appearance.reduceMotion).toggleStyle(DesignToggleStyle()).frame(height: 32)
            Toggle("恢复上次窗口", isOn: $appearance.restorePage).toggleStyle(DesignToggleStyle()).frame(height: 32)
        }.designPanel()
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
    @EnvironmentObject private var appearance: HomeAppearance
    private var families: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        HStack(spacing: 14) {
            fontPicker("日语字体", selection: $appearance.japaneseFont, size: $appearance.japaneseSize)
            fontPicker("中文字体", selection: $appearance.chineseFont, size: $appearance.chineseSize)
        }
    }
    private func fontPicker(_ title: String, selection: Binding<String>, size: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12))
            DesignMenuField(title: selection.wrappedValue.isEmpty ? "系统字体" : selection.wrappedValue) {
                Button("系统字体") { selection.wrappedValue = "" }
                ForEach(families, id: \.self) { family in Button(family) { selection.wrappedValue = family } }
            }.accessibilityLabel(title)
            Stepper(value: size, in: 12...32, step: 1) {
                Text("字号 \(Int(size.wrappedValue))").font(.system(size: 12)).monospacedDigit()
            }
            .accessibilityLabel(title.replacingOccurrences(of: "字体", with: "字号"))
            .accessibilityValue("\(Int(size.wrappedValue))")

        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SubtitleFont {
    static func native(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        family.isEmpty ? .systemFont(ofSize: size, weight: weight) : NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
