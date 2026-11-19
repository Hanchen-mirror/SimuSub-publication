import SwiftUI

enum WorkspaceZoom: Int, CaseIterable, Identifiable {
    case normal = 100, medium = 125, large = 150, extraLarge = 200
    var id: Int { rawValue }
    var factor: CGFloat { CGFloat(rawValue) / 100 }
    var label: String { "\(rawValue)%" }

    func logicalSize(_ physical: CGSize) -> CGSize {
        CGSize(width: physical.width / factor, height: physical.height / factor)
    }
}

enum WorkspaceNavigation: String {
    case sidebar, rail, top
    init(width: CGFloat) { self = width >= 1120 ? .sidebar : width >= 760 ? .rail : .top }
    var width: CGFloat? {
        switch self {
        case .sidebar: DesignV23.sidebar
        case .rail: 68
        case .top: nil
        }
    }
}

struct WorkspaceMetrics {
    let width: CGFloat
    var stacked: Bool { width < 760 }
    var narrow: Bool { width < 420 }
    var gutter: CGFloat { narrow ? 14 : stacked ? 20 : width < 1040 ? 28 : 46 }
    var cardInset: CGFloat { narrow ? 14 : stacked ? 18 : width < 1040 ? 20 : 26 }
    var gap: CGFloat { stacked ? 26 : width < 1040 ? 16 : 22 }
    var columns: AnyLayout {
        stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: gap))
            : AnyLayout(HStackLayout(alignment: .top, spacing: gap))
    }
    var promptHeight: CGFloat { width < 500 || (760..<840).contains(width) ? 135 : width < 1040 ? 113 : 91 }
}

// Shared typography remains at the standard size; subtitle sizing is independent.
private struct InterfaceFontSizeKey: EnvironmentKey { static let defaultValue: CGFloat = 13 }
extension EnvironmentValues {
    var interfaceFontSize: CGFloat {
        get { self[InterfaceFontSizeKey.self] }
        set { self[InterfaceFontSizeKey.self] = newValue }
    }
}
private struct InterfaceFontModifier: ViewModifier {
    @Environment(\.interfaceFontSize) private var baseSize
    var size: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    func body(content: Content) -> some View {
        content.font(.system(size: size * baseSize / 13, weight: weight, design: design))
    }
}
extension View {
    func interfaceFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(InterfaceFontModifier(size: size, weight: weight, design: design))
    }
}
struct ZoomedWorkspace<Content: View>: View {
    @EnvironmentObject private var appearance: HomeAppearance
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .environment(\.interfaceFontSize, 13)
            .font(.system(size: 13))
    }
}
