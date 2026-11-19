import SwiftUI

/// All geometry is measured in timeline points; labels disappear before they can overflow.
struct ClipTimeline150: View {
    var ranges: [ClipRange]
    var selected: UUID
    var duration: Double
    var time: Double
    var select: (ClipRange) -> Void
    var change: (ClipRange, Bool) -> Void
    var seek: (Double) -> Void
    var rename: (ClipRange) -> Void
    @State private var dragOrigin: ClipRange?
    private var total: Double { max(0.2, duration) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            VStack(spacing: 10) {
                HStack {
                    ForEach(0..<5) { i in
                        Text(ClipTime.label(total * Double(i) / 4).dropLast(4)).font(.system(size: 10)).monospacedDigit()
                        if i < 4 { Spacer(minLength: 0) }
                    }
                }.foregroundStyle(ThemeColor.muted)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6).fill(ThemeColor.control)
                    ForEach(ranges) { range in
                        segment(range, width: width).zIndex(range.id == selected ? 1 : 0)
                    }
                }.frame(height: 34).coordinateSpace(name: "timeline150")
                GeometryReader { rail in
                    let x = max(14, min(rail.size.width - 14, rail.size.width * time / total))
                    ZStack(alignment: .leading) {
                        Capsule().fill(ThemeColor.line).frame(height: 3)
                        GalaxyPlayhead150().stroke(ThemeColor.primary, style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                            .frame(width: 28, height: 20).offset(x: x - 14)
                    }.frame(height: 24).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in seek(max(0, min(total, v.location.x / max(1, rail.size.width) * total))) })
                        .accessibilityElement().accessibilityLabel(L10n.text("播放位置"))
                        .accessibilityValue(ClipTime.label(time)).accessibilityAdjustableAction { dir in seek(max(0, min(total, time + (dir == .increment ? 0.1 : -0.1)))) }
                }.frame(height: 24)
            }
        }.frame(height: 94)
    }
    private func segment(_ range: ClipRange, width: CGFloat) -> some View {
        let w = max(2, width * range.duration / total)
        let x = width * range.start / total
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(range.id == selected ? ThemeColor.primary.opacity(0.35) : ThemeColor.soft)
            if w >= max(48, CGFloat(range.title.count) * 10 + 18) {
                Text(range.title).font(.system(size: 11)).lineLimit(1).allowsHitTesting(false)
            }
        }.frame(width: w, height: 34).clipped().contentShape(Rectangle())
            .onTapGesture(count: 2) { rename(range) }
            .onTapGesture { select(range) }
            .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                if dragOrigin == nil { dragOrigin = range; select(range) }
                guard let base = dragOrigin else { return }
                var next = base; next.start = max(0, min(total - base.duration, base.start + v.translation.width / width * total)); next.end = next.start + base.duration
                change(next, false)
            }.onEnded { v in
                guard let base = dragOrigin else { return }
                var next = base; next.start = max(0, min(total - base.duration, base.start + v.translation.width / width * total)); next.end = next.start + base.duration
                change(next, true); dragOrigin = nil
            })
            .overlay(alignment: .leading) { if range.id == selected { handle(range, start: true, width: width) } }
            .overlay(alignment: .trailing) { if range.id == selected { handle(range, start: false, width: width) } }
            .offset(x: x).accessibilityLabel(range.title).help(range.title)
    }
    private func handle(_ range: ClipRange, start: Bool, width: CGFloat) -> some View {
        Capsule().fill(ThemeColor.primary).frame(width: 3, height: 38).frame(width: 12).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline150")).onChanged { v in
                if dragOrigin == nil { dragOrigin = range }
                change(resized(dragOrigin ?? range, start: start, t: v.location.x / width * total), false)
            }.onEnded { v in
                change(resized(dragOrigin ?? range, start: start, t: v.location.x / width * total), true); dragOrigin = nil
            }).accessibilityLabel(L10n.text(start ? "片段起点" : "片段终点"))
            .accessibilityAdjustableAction { direction in
                let t = (start ? range.start : range.end) + (direction == .increment ? 0.1 : -0.1)
                change(resized(range, start: start, t: t), true)
            }
    }
    private func resized(_ range: ClipRange, start: Bool, t: Double) -> ClipRange {
        var next = range
        if start { next.start = max(max(0, range.end - 600), min(range.end - 0.2, t)) }
        else { next.end = min(min(total, range.start + 600), max(range.start + 0.2, t)) }
        return next
    }
}
struct GalaxyPlayhead150: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.width * 0.02, y: r.height * 0.35, width: r.width * 0.96, height: r.height * 0.4))
        for (x, y, s) in [(0.29, 0.39, 0.12), (0.50, 0.58, 0.09), (0.72, 0.34, 0.17)] {
            let c = CGPoint(x: r.width * x, y: r.height * y), a = r.height * s
            p.move(to: CGPoint(x: c.x, y: c.y - a)); p.addLine(to: CGPoint(x: c.x + a * 0.3, y: c.y - a * 0.3)); p.addLine(to: CGPoint(x: c.x + a, y: c.y)); p.addLine(to: CGPoint(x: c.x + a * 0.3, y: c.y + a * 0.3)); p.addLine(to: CGPoint(x: c.x, y: c.y + a)); p.addLine(to: CGPoint(x: c.x - a * 0.3, y: c.y + a * 0.3)); p.addLine(to: CGPoint(x: c.x - a, y: c.y)); p.addLine(to: CGPoint(x: c.x - a * 0.3, y: c.y - a * 0.3)); p.closeSubpath()
        }
        return p
    }
}
