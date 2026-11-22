import AppKit

// Finder pins the artwork to the top-left. Extend its paper color across large displays.
// Coordinates in this design are points counted from the upper-left corner.
let width = 4096, height = 2560
func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255, alpha: alpha)
}
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: CGFloat(height) - y)
}
func label(_ text: String, _ x: CGFloat, _ top: CGFloat, _ size: CGFloat,
           _ weight: NSFont.Weight, _ ink: NSColor) {
    let style: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink
    ]
    let value = NSAttributedString(string: text, attributes: style)
    value.draw(at: NSPoint(x: x, y: CGFloat(height) - top - value.size().height))
}
func render(_ scale: Int, _ path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
        pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let colors = [color(247,245,251), color(228,218,242)]
    NSGradient(colors: colors)!.draw(from: point(0, 0), to: point(620, 134),
                                    options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])

    // Fine echo lines recall the waveform in the editor without competing with drag targets.
    for i in 0..<5 {
        let inset = CGFloat(i * 10)
        let line = NSBezierPath()
        line.move(to: point(435 + inset, -12))
        line.curve(to: point(638, 106 + inset),
                   controlPoint1: point(495 + inset, 10),
                   controlPoint2: point(508 + inset, 80 + inset))
        color(136, 111, 167, 0.12).setStroke()
        line.lineWidth = 1
        line.stroke()
    }

    label("安装 SimuSub", 43, 32, 32, .semibold, color(58, 41, 76))
    label("将 SimuSub 拖到「应用程序」，安装应用和离线字幕模型。", 45, 86,
          15, .regular, color(94, 76, 111))

    let arrow = NSBezierPath()
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: point(273, 202))
    arrow.line(to: point(344, 202))
    arrow.move(to: point(334, 192))
    arrow.line(to: point(344, 202))
    arrow.line(to: point(334, 212))
    color(130, 99, 159).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try render(1, CommandLine.arguments[1])
try render(2, CommandLine.arguments[2])
