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
    @State private var dragLanes: [UUID: Int]?
    @State private var laneCache = TimelineLaneCache()
    private static let laneHeight: CGFloat = 34
    private static let laneStride: CGFloat = 42

    // Keep exactly overlapping duplicates individually reachable. Adjacent cuts share a lane.
    static func lanes(for ranges: [ClipRange]) -> [UUID: Int] {
        let starts = ranges.indices.sorted { a, b in
            ranges[a].start == ranges[b].start ? a < b : ranges[a].start < ranges[b].start
        }
        let ends = ranges.indices.sorted { a, b in
            ranges[a].end == ranges[b].end ? a > b : ranges[a].end < ranges[b].end
        }
        var finished = 0
        var nextLane = 0
        var free: [Int] = []
        var lanes: [UUID: Int] = [:]
        for (started, index) in starts.enumerated() {
            let range = ranges[index]
            while finished < ends.count, ranges[ends[finished]].end <= range.start {
                if let lane = lanes[ranges[ends[finished]].id] { free.append(lane) }
                finished += 1
            }
            if finished == started { // The next group can start on the first track.
                nextLane = 0
                free.removeAll(keepingCapacity: true)
            }
            if let lane = free.popLast() {
                lanes[range.id] = lane
            } else {
                lanes[range.id] = nextLane
                nextLane += 1
            }
        }
        return lanes
    }

    private var total: Double { max(0.2, duration) }
    var body: some View {
        let lanes = dragLanes ?? laneCache.lanes(for: ranges)
        let lastLane = lanes.values.max() ?? 0
        let extraHeight = CGFloat(lastLane) * Self.laneStride
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            VStack(spacing: 10) {
                HStack {
                    ForEach(0..<5) { i in
                        Text(ClipTime.label(total * Double(i) / 4).dropLast(4)).font(.system(size: 10)).monospacedDigit()
                        if i < 4 { Spacer(minLength: 0) }
                    }
                }.foregroundStyle(ThemeColor.muted)
                ZStack(alignment: .topLeading) {
                    ForEach(0...lastLane, id: \.self) { lane in
                        RoundedRectangle(cornerRadius: 6).fill(ThemeColor.control)
                            .frame(height: Self.laneHeight)
                            .offset(y: CGFloat(lane) * Self.laneStride)
                            .accessibilityHidden(true)
                    }
                    ForEach(ranges) { range in
                        segment(range, width: width, lanes: lanes)
                            .offset(y: CGFloat(lanes[range.id] ?? 0) * Self.laneStride)
                            .zIndex(range.id == selected ? 1 : 0)
                    }
                }.frame(height: Self.laneHeight + extraHeight, alignment: .topLeading)
                    .coordinateSpace(name: "timeline150")
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
        }.frame(height: 94 + extraHeight)
    }
    private func segment(_ range: ClipRange, width: CGFloat, lanes: [UUID: Int]) -> some View {
        let active = range.id == selected
        let w = max(2, width * range.duration / total)
        let x = min(width - w, width * range.start / total)
        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? ThemeColor.selection : ThemeColor.primary.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(ThemeColor.primary.opacity(active ? 1 : 0.84), lineWidth: active ? 2 : 1)
                }
            if w >= max(48, CGFloat(range.title.count) * 10 + 18) {
                Text(range.title).font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(ThemeColor.ink).lineLimit(1).allowsHitTesting(false)
            }
        }.frame(width: w, height: 34).clipped().contentShape(Rectangle())
            .onTapGesture(count: 2) { rename(range) }
            .onTapGesture { select(range) }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("timeline150")).onChanged { v in
                if dragOrigin == nil { dragOrigin = range; dragLanes = lanes; select(range) }
                guard let base = dragOrigin else { return }
                var next = base; next.start = max(0, min(total - base.duration, base.start + v.translation.width / width * total)); next.end = next.start + base.duration
                change(next, false)
            }.onEnded { v in
                guard let base = dragOrigin else { return }
                var next = base; next.start = max(0, min(total - base.duration, base.start + v.translation.width / width * total)); next.end = next.start + base.duration
                change(next, true); dragOrigin = nil; dragLanes = nil
            })
            .overlay(alignment: .leading) { if range.id == selected { handle(range, start: true, width: width, lanes: lanes) } }
            .overlay(alignment: .trailing) { if range.id == selected { handle(range, start: false, width: width, lanes: lanes) } }
            .offset(x: x)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(range.title)
            .accessibilityValue(ClipTime.label(range.start) + " – " + ClipTime.label(range.end))
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select(range) }
            .accessibilityIdentifier("clips.range." + range.id.uuidString)
            .help(range.title)
    }
    private func handle(_ range: ClipRange, start: Bool, width: CGFloat, lanes: [UUID: Int]) -> some View {
        Capsule().fill(ThemeColor.primary).frame(width: 3, height: 38).frame(width: 12).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline150")).onChanged { v in
                let delta = v.translation.width / width * total
                if dragOrigin == nil {
                    guard delta != 0 else { return }
                    dragOrigin = range
                    dragLanes = lanes
                }
                if let base = dragOrigin {
                    change(Self.resized(base, start: start, delta: delta, duration: total), false)
                }
            }.onEnded { v in
                guard let base = dragOrigin else { return }
                change(Self.resized(base, start: start, delta: v.translation.width / width * total, duration: total), true)
                dragOrigin = nil
                dragLanes = nil
            }).accessibilityLabel(L10n.text(start ? "片段起点" : "片段终点"))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                change(Self.resized(range, start: start, delta: delta, duration: total), true)
            }
    }

    static func resized(_ range: ClipRange, start: Bool, delta: Double, duration: Double) -> ClipRange {
        var next = range
        if start {
            next.start = max(max(0, range.end - 600), min(range.end - 0.2, range.start + delta))
        } else {
            next.end = min(min(duration, range.start + 600), max(range.start + 0.2, range.end + delta))
        }
        return next
    }
}

/// Playback updates at 30 Hz, but only a change to the intervals affects their tracks.
@MainActor
final class TimelineLaneCache {
    private struct Interval {
        let id: UUID
        let start: Double
        let end: Double

        init(_ range: ClipRange) {
            id = range.id
            start = range.start
            end = range.end
        }
    }
    private struct Snapshot {
        let ranges: [Interval]
        let lanes: [UUID: Int]

        func matches(_ other: [ClipRange]) -> Bool {
            ranges.elementsEqual(other) { $0.id == $1.id && $0.start == $1.start && $0.end == $1.end }
        }
    }
    private var current = Snapshot(ranges: [], lanes: [:])
    // The editor retains 40 undo steps. A restored timeline should look exactly
    // as it did at that step, including the lane of a restored deleted range.
    private var history: [Snapshot] = []

    func lanes(for ranges: [ClipRange]) -> [UUID: Int] {
        guard !current.matches(ranges) else { return current.lanes }
        let lanes: [UUID: Int]
        if let restored = history.last(where: { $0.matches(ranges) }) {
            lanes = restored.lanes
        } else {
            let previous = Dictionary(current.ranges.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var assigned: [UUID: Int] = [:]
            var occupied: [Int: [ClipRange]] = [:]
            for range in ranges {
                guard let old = previous[range.id], old.start == range.start, old.end == range.end,
                      let lane = current.lanes[range.id] else { continue }
                assigned[range.id] = lane
                occupied[lane, default: []].append(range)
            }
            if assigned.isEmpty && !ranges.contains(where: { previous[$0.id] != nil }) {
                lanes = ClipTimeline150.lanes(for: ranges)
            } else {
                for range in ranges where assigned[range.id] == nil {
                    func fits(_ lane: Int) -> Bool {
                        occupied[lane]?.contains { range.start < $0.end && $0.start < range.end } != true
                    }
                    var lane = current.lanes[range.id] ?? 0
                    if !fits(lane) {
                        lane = 0
                        while !fits(lane) { lane += 1 }
                    }
                    assigned[range.id] = lane
                    occupied[lane, default: []].append(range)
                }
                lanes = assigned
            }
        }
        history.append(current)
        if history.count > 40 { history.removeFirst() }
        current = Snapshot(ranges: ranges.map(Interval.init), lanes: lanes)
        return lanes
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
