import SwiftUI

/// The sidebar, rail, and top bar share the cat's silhouette and its five pairs of poses.
struct WorkspaceNavigationGlyph: View {
    let item: WorkspaceDestination
    let selected: Bool
    var side: CGFloat = 24

    var body: some View {
        Group {
            if item == .home {
                Image(systemName: "square.grid.2x2").font(.system(size: 16, weight: .medium))
            } else {
                Canvas { context, size in
                    context.scaleBy(x: size.width / 32, y: size.height / 32)
                    let drawing = CatDrawing(context: context, ink: selected ? ThemeColor.primaryInk : ThemeColor.muted,
                                             paper: selected ? ThemeColor.selection : ThemeColor.sidebar)
                    switch item {
                    case .subtitle: drawing.subtitles(speaking: selected)
                    case .recording: drawing.recording(closed: selected)
                    case .clips: drawing.homework(writing: selected)
                    case .services: drawing.thinking(idea: selected)
                    case .settings: drawing.repair(working: selected)
                    case .home: break
                    }
                }
            }
        }.frame(width: side, height: side).accessibilityHidden(true)
    }
}

private struct CatDrawing {
    var context: GraphicsContext
    let ink: Color
    let paper: Color
    private typealias Point = CGPoint

    private func line(_ path: Path, width: CGFloat = 1.85) {
        context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
    private func line(_ points: [(CGFloat, CGFloat)], width: CGFloat = 1.85) {
        var path = Path()
        path.addLines(points.map { Point(x: $0.0, y: $0.1) })
        line(path, width: width)
    }
    private func shape(_ path: Path) {
        context.fill(path, with: .color(paper))
        line(path)
    }
    private func dot(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
        context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius)), with: .color(ink))
    }

    // One continuous contour joins the pointed ears, cheeks, and off-centre speech tail.
    private func head(x: CGFloat, y: CGFloat, scale: CGFloat = 1, tilt: Double = 0,
                      gaze: CGPoint = .zero, speaking: Bool = false) {
        var cat = self
        cat.context.translateBy(x: x, y: y)
        cat.context.rotate(by: .degrees(tilt))
        cat.context.scaleBy(x: scale, y: scale)
        var contour = Path()
        contour.move(to: Point(x: -9, y: -1))
        contour.addLine(to: Point(x: -9.2, y: -8.3))
        contour.addQuadCurve(to: Point(x: -8, y: -8.9), control: Point(x: -9.2, y: -9.7))
        contour.addLine(to: Point(x: -3.7, y: -5.7))
        contour.addQuadCurve(to: Point(x: 3.5, y: -5.7), control: Point(x: 0, y: -6.7))
        contour.addLine(to: Point(x: 8, y: -8.9))
        contour.addQuadCurve(to: Point(x: 9.1, y: -8.1), control: Point(x: 9.4, y: -9.8))
        contour.addLine(to: Point(x: 9.1, y: -1))
        contour.addQuadCurve(to: Point(x: 2, y: 6.6), control: Point(x: 10.1, y: 6))
        contour.addLine(to: Point(x: -0.8, y: 6.8))
        contour.addLine(to: Point(x: -5.2, y: 9.6))
        contour.addLine(to: Point(x: -5, y: 6.2))
        contour.addQuadCurve(to: Point(x: -9, y: -1), control: Point(x: -10.1, y: 4.7))
        contour.closeSubpath()
        cat.shape(contour)
        cat.dot(-4 + gaze.x, -1.6 + gaze.y, 1.15)
        cat.dot(4 + gaze.x, -1.6 + gaze.y, 1.15)
        if speaking {
            cat.context.fill(Path(ellipseIn: CGRect(x: -1.35, y: 0.8, width: 3.6, height: 4)), with: .color(ink))
        } else {
            var mouth = Path()
            mouth.move(to: Point(x: -1.55, y: 1.55))
            mouth.addQuadCurve(to: Point(x: 1.55, y: 1.55), control: Point(x: 0, y: 3.2))
            cat.line(mouth, width: 1.4)
        }
    }

    func subtitles(speaking: Bool) {
        head(x: speaking ? 12.6 : 15.5, y: speaking ? 16 : 17.5, scale: 1.15,
             tilt: speaking ? -6 : 0, gaze: speaking ? Point(x: 0.4, y: -0.4) : .zero, speaking: speaking)
        if speaking {
            line([(25, 14), (28.5, 11.5)])
            line([(26, 18), (30, 18)])
            line([(25, 22), (28.2, 24.3)])
        }
    }

    func recording(closed: Bool) {
        head(x: 15.1, y: closed ? 20.7 : 21.5, scale: 0.87, tilt: closed ? 4 : -6)
        var board = self
        board.context.translateBy(x: 10, y: closed ? 8 : 10.8)
        board.context.rotate(by: .degrees(closed ? 3 : -3))
        board.shape(Path(roundedRect: CGRect(x: 0, y: 0, width: 17.5, height: 4.1), cornerRadius: 1.2))
        var arm = board
        if !closed { arm.context.rotate(by: .degrees(-19)) }
        arm.shape(Path(roundedRect: CGRect(x: 0, y: -3, width: 17.5, height: 3.2), cornerRadius: 0.8))
        for x in [CGFloat(4.5), 10, 15.5] { arm.line([(x, -2.6), (x - 1.7, -0.2)], width: 1.4) }
        if closed {
            line([(26.8, 4.4), (28.3, 2)])
            line([(28.5, 7.2), (30.4, 6.2)])
        }
    }

    func homework(writing: Bool) {
        head(x: 11.7, y: writing ? 14.4 : 12.8, scale: 0.92, tilt: writing ? 17 : 8, gaze: Point(x: 0.6, y: 1))
        var page = Path()
        page.addLines([Point(x: 5, y: 22), Point(x: 20, y: 21.6), Point(x: 25.5, y: 27.6), Point(x: 3, y: 29)])
        page.closeSubpath()
        shape(page)
        if writing { line([(8.2, 25.8), (12, 25.8), (13.7, 24.7)], width: 1.4) }
        var pen = self
        pen.context.translateBy(x: writing ? 16.2 : 22.8, y: writing ? 25.1 : 20.4)
        pen.context.rotate(by: .degrees(writing ? 38 : 14))
        var nib = Path()
        nib.addLines([Point(x: 0, y: 0), Point(x: -1.65, y: -3.3), Point(x: -1.65, y: -14),
                      Point(x: 1.65, y: -14), Point(x: 1.65, y: -3.3)])
        nib.closeSubpath()
        pen.shape(nib)
        pen.shape(Path(roundedRect: CGRect(x: -3.3, y: -8, width: 4.5, height: 3.8), cornerRadius: 1.8))
    }

    func thinking(idea: Bool) {
        head(x: idea ? 12.1 : 12.8, y: idea ? 20.4 : 18.9, scale: 0.96, tilt: idea ? -6 : 9,
             gaze: Point(x: 0.7, y: -0.8))
        if idea {
            var bulb = Path()
            bulb.move(to: Point(x: 21.6, y: 12.7))
            bulb.addQuadCurve(to: Point(x: 19.8, y: 8.6), control: Point(x: 21.5, y: 11.3))
            bulb.addCurve(to: Point(x: 28.1, y: 7.4), control1: Point(x: 17.6, y: 2.5), control2: Point(x: 28.1, y: 1.9))
            bulb.addQuadCurve(to: Point(x: 26.2, y: 12.7), control: Point(x: 28.4, y: 9.9))
            bulb.closeSubpath()
            shape(bulb)
            line([(22.6, 15.2), (25.1, 15.2)], width: 1.6)
            line([(17.7, 3.6), (16.6, 2.2)], width: 1.5)
            line([(28.8, 3.1), (30, 1.9)], width: 1.5)
        } else {
            shape(Path(ellipseIn: CGRect(x: 14.3, y: 21.7, width: 5, height: 4.4)))
            dot(21.5, 10.5, 1.05)
            dot(24.5, 7.7, 1.4)
            shape(Path(ellipseIn: CGRect(x: 25.1, y: 2.4, width: 4.4, height: 4.1)))
        }
    }

    func repair(working: Bool) {
        head(x: working ? 10.8 : 13.1, y: working ? 17.6 : 15.7, scale: 0.9, tilt: working ? -8 : 13,
             gaze: Point(x: 0.9, y: working ? -0.5 : 0.9))
        if working {
            var wrench = Path()
            wrench.move(to: Point(x: 17.5, y: 26.4))
            wrench.addLine(to: Point(x: 23.5, y: 14.8))
            wrench.addQuadCurve(to: Point(x: 24.4, y: 5.7), control: Point(x: 18.3, y: 10.3))
            wrench.addLine(to: Point(x: 24.3, y: 10))
            wrench.addLine(to: Point(x: 27.1, y: 11.1))
            wrench.addLine(to: Point(x: 29.8, y: 8.2))
            wrench.addQuadCurve(to: Point(x: 26.4, y: 16.2), control: Point(x: 31, y: 14.7))
            wrench.addLine(to: Point(x: 20.4, y: 27.9))
            wrench.addQuadCurve(to: Point(x: 17.5, y: 26.4), control: Point(x: 17.1, y: 29.5))
            wrench.closeSubpath()
            shape(wrench)
            shape(Path(roundedRect: CGRect(x: 16.3, y: 20.4, width: 4.8, height: 3.3), cornerRadius: 1.6))
        } else {
            // The raised lid sits behind the front of the toolbox.
            var lid = Path()
            lid.addLines([Point(x: 9, y: 21.8), Point(x: 8.3, y: 18.2), Point(x: 25.6, y: 15.7), Point(x: 27, y: 20.7)])
            lid.closeSubpath()
            shape(lid)
            shape(Path(roundedRect: CGRect(x: 7.5, y: 21, width: 20, height: 7.5), cornerRadius: 1.7))
            line([(15.9, 22.1), (15.9, 24.3), (19.1, 24.3)], width: 1.5)
        }
    }
}
