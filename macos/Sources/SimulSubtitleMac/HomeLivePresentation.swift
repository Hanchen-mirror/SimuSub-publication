import SwiftUI

@MainActor
final class HomeLivePresentation: ObservableObject {
    @Published var platform: LivePlatform = .bilibili
    @Published private(set) var searchVisible = true
    @Published var query = ""
    @Published var resultsVisible = false
    @Published private(set) var accountPlatform: LivePlatform?
    private var accountDismissal: Task<Void, Never>?
    func showAccounts(_ platform: LivePlatform) {
        accountDismissal?.cancel(); accountPlatform = platform
    }
    func leaveAccounts() {
        accountDismissal?.cancel()
        accountDismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            guard !Task.isCancelled else { return }; self?.accountPlatform = nil
        }
    }
    func closeAccounts() { accountDismissal?.cancel(); accountDismissal = nil; accountPlatform = nil }
    @Published var draggingCreator: UUID?
    @Published var dropTarget: UUID?
    func select(_ platform: LivePlatform) {
        if self.platform != platform { query = "" }
        if accountPlatform != platform { closeAccounts() }
        self.platform = platform; searchVisible = true; resultsVisible = false
    }
    func hideSearch() { closeAccounts(); searchVisible = false; resultsVisible = false }
    func showSearch() { searchVisible = true }
}

/// Balanced rows: a partial last row is centered, without placeholder cells.
struct CreatorGridMetrics {
    let tile: CGFloat
    let columns: Int
    let gap: CGFloat = 22
    init(width: CGFloat, height: CGFloat = 500, count: Int) {
        let available = max(1, width), minimum: CGFloat = 104
        let maximum = min(CGFloat(300), max(CGFloat(144), min(available * 0.27, height * 0.58)))
        let maximumColumns = max(1, Int((available + gap) / (minimum + gap)))
        if count <= 12 {
            var bestSide: CGFloat = 0, bestColumns = 1
            for candidate in 1...max(1, min(max(1, count), maximumColumns)) {
                let rowCount = Int(ceil(Double(max(1, count)) / Double(candidate)))
                let across = (available - CGFloat(candidate - 1) * gap) / CGFloat(candidate)
                let down = (max(1, height) - 24 - CGFloat(rowCount - 1) * gap) / CGFloat(rowCount) - 60
                let side = min(maximum, across, down)
                if side > bestSide { bestSide = side; bestColumns = candidate }
            }
            if bestSide >= minimum {
                columns = bestColumns; tile = bestSide
            } else {
                columns = max(1, min(max(1, count), maximumColumns))
                tile = min(maximum, max(minimum, (available - CGFloat(columns - 1) * gap) / CGFloat(columns)))
            }
        } else {
            columns = max(1, min(count, Int((available + gap) / (154 + gap))))
            tile = min(164, max(minimum, (available - CGFloat(columns - 1) * gap) / CGFloat(columns)))
        }
    }
    func rows(count: Int) -> [Range<Int>] {
        stride(from: 0, to: count, by: columns).map { $0..<min(count, $0 + columns) }
    }
}

enum CreatorBadge: Equatable {
    case live, offline, upcoming, unknown, error, confirming
    init(_ creator: WatchedCreator) {
        if creator.lastError != nil { self = .error }
        else if creator.stableState == .live && creator.offlineConfirmations == 1 { self = .confirming }
        else {
            switch creator.snapshot.state {
            case .live: self = .live
            case .offline: self = .offline
            case .upcoming: self = .upcoming
            case .unknown: self = .unknown
            }
        }
    }
    var title: String {
        switch self {
        case .live: "LIVE"; case .offline: "OFFLINE"; case .upcoming: "UPCOMING"
        case .unknown: "UNKNOWN"; case .error: "ERROR"; case .confirming: "CHECKING"
        }
    }
    var color: Color {
        switch self {
        case .live: .green; case .offline: .red; case .upcoming, .confirming: .orange
        case .unknown: .secondary; case .error: .orange
        }
    }
}

/// Brand marks are drawn as vectors so resizing never substitutes a generic
/// gamepad/TV symbol. Reference paths and CC0 notice ship in BrandIcons/.
struct PlatformLogo: View {
    let platform: LivePlatform
    @Environment(\.appThemeID) private var appThemeID
    var body: some View {
        let _ = appThemeID
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Group {
                switch platform {
                case .bilibili: BilibiliMark().fill(Color(red: 0, green: 0.66, blue: 0.84))
                case .youtube:
                    ZStack {
                        RoundedRectangle(cornerRadius: side * 0.18).fill(Color(red: 1, green: 0.12, blue: 0.22))
                            .frame(height: side * 0.72)
                        Path { path in
                            path.move(to: CGPoint(x: side * 0.41, y: side * 0.32))
                            path.addLine(to: CGPoint(x: side * 0.41, y: side * 0.68))
                            path.addLine(to: CGPoint(x: side * 0.71, y: side * 0.5)); path.closeSubpath()
                        }.fill(.white)
                    }
                case .twitch: TwitchMark().fill(Color(red: 0.64, green: 0.42, blue: 0.98), style: FillStyle(eoFill: true))
                }
            }.frame(width: side, height: side)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityHidden(true)
    }
}

private struct BilibiliMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(Path(roundedRect: CGRect(x: 1.333, y: 5.986, width: 21.334, height: 15.36), cornerRadius: 4).strokedPath(StrokeStyle(lineWidth: 2.666)))
        var antenna = Path()
        antenna.move(to: CGPoint(x: 5.867, y: 2.64)); antenna.addLine(to: CGPoint(x: 9.65, y: 6.3))
        antenna.move(to: CGPoint(x: 18.133, y: 2.64)); antenna.addLine(to: CGPoint(x: 14.35, y: 6.3))
        path.addPath(antenna.strokedPath(StrokeStyle(lineWidth: 2.6, lineCap: .round)))
        path.addRoundedRect(in: CGRect(x: 6.667, y: 11.1, width: 2.666, height: 3.85), cornerSize: CGSize(width: 1.3, height: 1.3))
        path.addRoundedRect(in: CGRect(x: 14.667, y: 11.1, width: 2.666, height: 3.85), cornerSize: CGSize(width: 1.3, height: 1.3))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).translatedBy(x: 0, y: 0))
    }
}
private struct TwitchMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func polygon(_ values: [(CGFloat, CGFloat)]) {
            path.move(to: CGPoint(x: values[0].0, y: values[0].1))
            for point in values.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
        polygon([(6,0),(1.714,4.286),(1.714,19.714),(6.857,19.714),(6.857,24),(11.143,19.714),(14.571,19.714),(22.286,12),(22.286,0)])
        polygon([(20.571,11.143),(17.143,14.571),(13.714,14.571),(10.714,17.571),(10.714,14.571),(6.857,14.571),(6.857,1.714),(20.571,1.714)])
        path.addRect(CGRect(x: 11.571, y: 4.714, width: 1.715, height: 5.143))
        path.addRect(CGRect(x: 16.286, y: 4.714, width: 1.714, height: 5.143))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}
