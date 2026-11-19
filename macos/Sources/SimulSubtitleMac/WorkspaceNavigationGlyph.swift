import SwiftUI

/// Workspace tools use a shared 24-point drawing grid and a small solid detail
/// that remains legible when only the navigation rail is visible.
struct WorkspaceNavigationGlyph: View {
    let item: WorkspaceDestination
    let selected: Bool

    var body: some View {
        Group {
            if item == .settings || item == .home {
                Image(systemName: item == .settings ? "gearshape" : "square.grid.2x2")
                    .font(.system(size: 16, weight: .medium))
            } else {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 24, y: size.height / 24)
                    let ink = selected ? ThemeColor.primaryInk : ThemeColor.muted
                    let fill = ink.opacity(selected ? 0.25 : 0.12)
                    let pen = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    func outline(_ path: Path) {
                        context.fill(path, with: .color(fill))
                        context.stroke(path, with: .color(ink), style: pen)
                    }
                    func stroke(_ points: [CGPoint]) {
                        var path = Path()
                        path.addLines(points)
                        context.stroke(path, with: .color(ink), style: pen)
                    }
                    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
                    switch item {
                    case .subtitle:
                        // Two offset caption ribbons, one for each language.
                        outline(Path(roundedRect: CGRect(x: 2, y: 3.5, width: 16, height: 8), cornerRadius: 2.6))
                        stroke([point(6, 7.5), point(12.5, 7.5)])
                        outline(Path(roundedRect: CGRect(x: 6, y: 12.5, width: 16, height: 8), cornerRadius: 2.6))
                        stroke([point(10, 16.5), point(12, 16.5)])
                        stroke([point(15, 16.5), point(18, 16.5)])
                    case .recording:
                        // An on-air monitor with a level meter and record tally.
                        outline(Path(roundedRect: CGRect(x: 2, y: 5, width: 17, height: 15), cornerRadius: 4))
                        stroke([point(6, 12), point(6, 15)])
                        stroke([point(10, 10), point(10, 16.5)])
                        stroke([point(14, 12), point(14, 14.5)])
                        let tally = Path(ellipseIn: CGRect(x: 16, y: 2, width: 6.5, height: 6.5))
                        context.stroke(tally, with: .color(selected ? ThemeColor.selection : ThemeColor.sidebar), lineWidth: 2.4)
                        context.fill(tally, with: .color(ink))
                    case .clips:
                        // A hinged slate above a timeline with a single edit point.
                        var slate = Path()
                        slate.addLines([point(2.5, 6.5), point(19.8, 2.8), point(20.7, 7.3), point(3.4, 11)])
                        slate.closeSubpath()
                        outline(slate)
                        stroke([point(7, 5.6), point(10, 8.5)])
                        stroke([point(13.2, 4.3), point(16.2, 7.2)])
                        outline(Path(roundedRect: CGRect(x: 3, y: 11, width: 18, height: 9.5), cornerRadius: 2.4))
                        stroke([point(7, 16), point(17, 16)])
                        stroke([point(12.5, 14), point(12.5, 18)])
                    case .services:
                        // Layered model weights, with a node at the top.
                        var layer = Path()
                        layer.addLines([point(2.5, 8.2), point(12, 3), point(21.5, 8.2), point(12, 13.4)])
                        layer.closeSubpath()
                        outline(layer)
                        context.fill(Path(ellipseIn: CGRect(x: 10.3, y: 6.5, width: 3.4, height: 3.4)), with: .color(ink))
                        stroke([point(2.5, 12.6), point(12, 17.8), point(21.5, 12.6)])
                        stroke([point(2.5, 17), point(12, 22.2), point(21.5, 17)])
                    case .settings, .home:
                        break
                    }
                }
            }
        }
        .frame(width: 21, height: 21)
        .accessibilityHidden(true)
    }
}
