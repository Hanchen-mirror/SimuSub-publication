import SwiftUI

struct ThemeColorChoices: View {
    let compact: Bool
    @EnvironmentObject private var appearance: HomeAppearance
    @State private var editing: String?
    @State private var restoring = false

    var body: some View {
        if compact {
            HStack(spacing: 10) { choices }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) { choices }
        }
    }

    @ViewBuilder private var choices: some View {
        ForEach(appearance.visibleThemes) { theme in
            RemovableSwatch(value: theme.rawValue, editing: $editing,
                            removeID: "appearance.theme.remove." + theme.rawValue,
                            onSelect: { appearance.theme = theme },
                            onRemove: { appearance.hideTheme(theme) }) {
                choiceLabel(theme)
                    .accessibilityIdentifier("appearance.theme." + theme.rawValue)
                    .accessibilityLabel(L10n.text(theme.title))
                    .accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
            }
            .help(L10n.text(theme.title))
        }
        if !appearance.hiddenThemes.isEmpty {
            Button {
                editing = nil
                restoring = true
            } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
                    .foregroundStyle(ThemeColor.muted)
                    .overlay { Circle().strokeBorder(ThemeColor.line) }
            }.buttonStyle(.plain)
                .help(L10n.text("恢复颜色")).accessibilityLabel(L10n.text("恢复颜色"))
                .accessibilityIdentifier("appearance.theme.add")
                .popover(isPresented: $restoring) {
                    HStack(spacing: 8) {
                        ForEach(appearance.hiddenThemes) { theme in
                            Button {
                                restoring = false
                                appearance.restoreTheme(theme)
                            } label: {
                                dot(theme).frame(width: 30, height: 30).contentShape(Rectangle())
                            }.buttonStyle(.plain).help(L10n.text(theme.title))
                                .accessibilityLabel(L10n.text(theme.title))
                                .accessibilityIdentifier("appearance.theme.restore." + theme.rawValue)
                        }
                    }.padding(12).background(ThemeColor.surface)
                }
        }
    }

    private func dot(_ theme: AppTheme) -> some View {
        Circle().fill(Color(nsColor: ThemePalette.color(theme, dark: false, role: .primary)))
            .frame(width: compact ? 28 : 20, height: compact ? 28 : 20)
    }

    @ViewBuilder private func choiceLabel(_ theme: AppTheme) -> some View {
        let selected = appearance.theme == theme
        if compact {
            dot(theme).padding(3)
                .overlay { Circle().strokeBorder(selected ? ThemeColor.primary : .clear) }
                .contentShape(Rectangle())
        } else {
            HStack(spacing: 9) {
                dot(theme).overlay {
                    if selected {
                        Image(systemName: "checkmark").interfaceFont(size: 10, weight: .bold).foregroundStyle(.white)
                    }
                }
                Text(L10n.text(theme.title)).interfaceFont(size: 12)
            }.padding(.horizontal, 12).frame(height: 40)
                .background(selected ? ThemeColor.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
    }
}
