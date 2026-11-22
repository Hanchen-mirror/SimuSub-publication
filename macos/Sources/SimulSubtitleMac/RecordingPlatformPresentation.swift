import SwiftUI

@MainActor
final class CreatorSearchState: ObservableObject {
    @Published var platform: LivePlatform = .bilibili
    @Published var query = ""
    @Published var resultsVisible = false
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
        case .live: "直播中"; case .offline: "未开播"; case .upcoming: "等待开播"
        case .unknown: "待检查"; case .error: "检查失败"; case .confirming: "确认下播中"
        }
    }
    var color: Color {
        switch self {
        case .live: .green; case .offline: .secondary; case .upcoming, .confirming: .orange
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
