import SwiftUI

private struct SheenSchedule: TimelineSchedule {
    static let sweep: TimeInterval = 1.8
    static let rest: TimeInterval = 4.0
    static let cycle = sweep + rest

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        sequence(first: startDate) { date in
            let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
            let frame = mode == .lowFrequency ? 1.0 / 10 : 1.0 / 30
            // Wake once at the next sweep while the wordmark is still.
            let interval = phase < Self.sweep ? min(frame, Self.sweep - phase) : Self.cycle - phase
            return date.addingTimeInterval(max(interval, 0.000_001))
        }
    }
}

struct TextSheen: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.simuSubReduceMotion) private var appReduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if active && !systemReduceMotion && !appReduceMotion {
                TimelineView(SheenSchedule()) { timeline in
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let band = min(64, max(18, width * 0.32))
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: SheenSchedule.cycle) / SheenSchedule.sweep
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
