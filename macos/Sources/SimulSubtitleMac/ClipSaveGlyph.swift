import SwiftUI

/// A diskette distinguishes saving the project from importing media and exporting a clip.
struct ClipSaveGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3, y: 2))
        path.addLine(to: CGPoint(x: 13, y: 2))
        path.addLine(to: CGPoint(x: 17, y: 6))
        path.addLine(to: CGPoint(x: 17, y: 16))
        path.addQuadCurve(to: CGPoint(x: 16, y: 17), control: CGPoint(x: 17, y: 17))
        path.addLine(to: CGPoint(x: 3, y: 17))
        path.addQuadCurve(to: CGPoint(x: 2, y: 16), control: CGPoint(x: 2, y: 17))
        path.addLine(to: CGPoint(x: 2, y: 3))
        path.addQuadCurve(to: CGPoint(x: 3, y: 2), control: CGPoint(x: 2, y: 2))
        path.closeSubpath()
        path.move(to: CGPoint(x: 5, y: 2))
        path.addLine(to: CGPoint(x: 5, y: 7))
        path.addLine(to: CGPoint(x: 12, y: 7))
        path.addLine(to: CGPoint(x: 12, y: 2))
        path.move(to: CGPoint(x: 5, y: 17))
        path.addLine(to: CGPoint(x: 5, y: 11))
        path.addLine(to: CGPoint(x: 14, y: 11))
        path.addLine(to: CGPoint(x: 14, y: 17))
        return path.applying(CGAffineTransform(scaleX: rect.width / 19, y: rect.height / 19))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
