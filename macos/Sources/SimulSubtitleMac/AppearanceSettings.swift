import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var guide = false
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DesignPageHeading(title: "设置") { EmptyView() }
                VStack(alignment: .leading, spacing: 22) {
                    Text("外观").font(.headline)
                    HStack(spacing: 16) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Button { appearance.mode = mode } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 5) {
                                        RoundedRectangle(cornerRadius: 4).fill(sample(mode, .sidebar)).frame(width: 30)
                                        VStack(spacing: 5) {
                                            RoundedRectangle(cornerRadius: 4).fill(sample(mode, .surface))
                                            RoundedRectangle(cornerRadius: 4).fill(sample(mode, .surface))
                                        }
                                    }.padding(8).frame(height: 64).background(sample(mode, .background), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .trailing) { if mode == .system {
                                        VStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: ThemePalette.color(appearance.theme, dark: true, role: .surface))); RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: ThemePalette.color(appearance.theme, dark: true, role: .surface))) }.padding(8).frame(width: 59, height: 64).background(Color(nsColor: ThemePalette.color(appearance.theme, dark: true, role: .background))).clipShape(RoundedRectangle(cornerRadius: 6))
                                    } }
                                    HStack { Text(mode.title); Spacer(); if appearance.mode == mode { Image(systemName: "checkmark") } }
                                }.padding(12).frame(width: 126)
                                    .background(appearance.mode == mode ? ThemeColor.soft : ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.mode == mode ? ThemeColor.primary : ThemeColor.line))
                            }.buttonStyle(.plain).accessibilityIdentifier("appearance.mode." + mode.rawValue)
                        }
                    }
                    Divider().overlay(ThemeColor.line)
                    Text("主题色").font(.subheadline)
                    HStack(spacing: 12) {
                        ForEach(AppTheme.allCases) { theme in
                            Button { appearance.theme = theme } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(Color(nsColor: ThemePalette.color(theme, dark: true, role: .primary)))
                                        .frame(width: 25, height: 25)
                                        .overlay { if appearance.theme == theme { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(nsColor: ThemePalette.color(theme, dark: false, role: .ink))) } }
                                    Text(theme.title).font(.callout)
                                }.padding(12).frame(minWidth: 100)
                                    .background(appearance.theme == theme ? ThemeColor.soft : ThemeColor.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.theme == theme ? ThemeColor.primary : .clear))
                            }.buttonStyle(.plain).accessibilityIdentifier("appearance.theme." + theme.rawValue)
                        }
                    }
                }.designPanel()
                VStack(alignment: .leading, spacing: 22) {
                    Text("使用偏好").font(.system(size: 15, weight: .semibold))
                    Divider().overlay(ThemeColor.line)
                    Toggle("减少动画", isOn: $appearance.reduceMotion).toggleStyle(DesignToggleStyle())
                    Divider().overlay(ThemeColor.line)
                    Toggle("恢复上次打开的页面", isOn: $appearance.restorePage).toggleStyle(DesignToggleStyle())
                    DisclosureGroup("首页背景") {
                        HStack {
                            Text(appearance.hasBackground ? "已设置自定义图片" : "使用主题背景").foregroundStyle(ThemeColor.muted)
                            Spacer(); Button("导入 PNG", action: appearance.choosePNG)
                            Button("恢复主题背景", action: appearance.restoreDefault).disabled(!appearance.hasBackground)
                        }.padding(.top, 12)
                    }.font(.system(size: 12)).foregroundStyle(ThemeColor.muted)
                }.designPanel()
                VStack(alignment: .leading, spacing: 12) {
                    Text("关于").font(.headline)
                    HStack { Text("SimuSub v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.29")); Spacer(); Button { guide = true } label: { Label("使用帮助", systemImage: "questionmark.circle") } }
                    Text("本地同传、直播录制与剪辑。").foregroundStyle(ThemeColor.muted)
                }.designPanel()
            }.padding(.horizontal, 32).padding(.vertical, 28)
        }.background(ThemeColor.background)
            .sheet(isPresented: $guide) { SimuSubGuide().appTheme() }
            .alert("背景操作失败", isPresented: Binding(get: { appearance.importError != nil }, set: { if !$0 { appearance.importError = nil } })) { Button("知道了") { appearance.importError = nil } } message: { Text(appearance.importError ?? "") }
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
            fontPicker("日语字体", selection: $appearance.japaneseFont)
            fontPicker("中文字体", selection: $appearance.chineseFont)
        }
    }
    private func fontPicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12))
            DesignMenuField(title: selection.wrappedValue.isEmpty ? "系统字体" : selection.wrappedValue) {
                Button("系统字体") { selection.wrappedValue = "" }
                ForEach(families, id: \.self) { family in Button(family) { selection.wrappedValue = family } }
            }.accessibilityLabel(title)

        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SubtitleFont {
    static func native(_ family: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        family.isEmpty ? .systemFont(ofSize: size, weight: weight) : NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}
