import SwiftUI

/// The prototype's cat mark, drawn with the active palette rather than a fixed purple tile.
struct WorkspaceBrandMark: View {
    @Environment(\.appThemeID) private var themeID
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 64, y: size.height / 64)
            let outline = Color(red: 0.36, green: 0.30, blue: 0.40)
            let cream = Color(red: 1, green: 0.973, blue: 0.953)
            let pink = Color(red: 0.95, green: 0.72, blue: 0.80)
            context.fill(Path(roundedRect: CGRect(x: 1, y: 1, width: 62, height: 62), cornerRadius: 20), with: .color(ThemeColor.primary))
            var ears = Path()
            ears.move(to: CGPoint(x: 14, y: 27)); ears.addLine(to: CGPoint(x: 13, y: 13))
            ears.addQuadCurve(to: CGPoint(x: 17, y: 11), control: CGPoint(x: 13, y: 9)); ears.addLine(to: CGPoint(x: 29, y: 20))
            ears.move(to: CGPoint(x: 35, y: 20)); ears.addLine(to: CGPoint(x: 47, y: 11))
            ears.addQuadCurve(to: CGPoint(x: 51, y: 13), control: CGPoint(x: 51, y: 9)); ears.addLine(to: CGPoint(x: 50, y: 27))
            context.fill(ears, with: .color(cream)); context.stroke(ears, with: .color(outline), lineWidth: 1.6)
            var face = Path()
            face.move(to: CGPoint(x: 12, y: 34))
            face.addCurve(to: CGPoint(x: 32, y: 18), control1: CGPoint(x: 12, y: 23), control2: CGPoint(x: 20, y: 18))
            face.addCurve(to: CGPoint(x: 52, y: 34), control1: CGPoint(x: 44, y: 18), control2: CGPoint(x: 52, y: 23))
            face.addLine(to: CGPoint(x: 52, y: 37))
            face.addCurve(to: CGPoint(x: 34, y: 53), control1: CGPoint(x: 52, y: 47), control2: CGPoint(x: 45, y: 53))
            face.addLine(to: CGPoint(x: 29, y: 53)); face.addLine(to: CGPoint(x: 21, y: 58)); face.addLine(to: CGPoint(x: 22, y: 51))
            face.addCurve(to: CGPoint(x: 12, y: 37), control1: CGPoint(x: 15, y: 49), control2: CGPoint(x: 12, y: 44)); face.closeSubpath()
            context.fill(face, with: .color(cream)); context.stroke(face, with: .color(outline), lineWidth: 1.6)
            for x in [19.5, 44.5] { context.fill(Path(ellipseIn: CGRect(x: x - 4.2, y: 35.2, width: 8.4, height: 5.6)), with: .color(pink)) }
            for x in [24.0, 40.0] {
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: 28.8, width: 5, height: 6.4)), with: .color(Color(red: 0.28, green: 0.22, blue: 0.32)))
                context.fill(Path(ellipseIn: CGRect(x: x - 0.1, y: 30.2, width: 1.6, height: 1.6)), with: .color(.white))
            }
            var mouth = Path(); mouth.move(to: CGPoint(x: 27, y: 39))
            mouth.addQuadCurve(to: CGPoint(x: 32, y: 39), control: CGPoint(x: 29.5, y: 43.5)); mouth.addQuadCurve(to: CGPoint(x: 37, y: 39), control: CGPoint(x: 34.5, y: 43.5))
            context.stroke(mouth, with: .color(outline), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        }.id(themeID).accessibilityHidden(true)
    }
}
