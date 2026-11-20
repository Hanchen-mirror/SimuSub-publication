import SwiftUI

/// A narrow highlight crosses the glyphs, with a short rest between passes.
struct TextSheen: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.simuSubReduceMotion) private var appReduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active && !systemReduceMotion && !appReduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let band = min(64, max(18, width * 0.32))
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 1.8
                        let ink: Color = scheme == .dark ? .white : .black
                        LinearGradient(colors: [.clear, ink.opacity(0.22), ink.opacity(0.85), ink.opacity(0.22), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: (width + band) * min(phase, 1) - band)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct SimuSubReduceMotionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var simuSubReduceMotion: Bool {
        get { self[SimuSubReduceMotionKey.self] }
        set { self[SimuSubReduceMotionKey.self] = newValue }
    }
}
