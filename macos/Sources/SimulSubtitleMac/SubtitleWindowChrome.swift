import AppKit
import SwiftUI

enum SubtitleDensity: String {
    case regular, compact, bubble
    static func forSize(_ size: CGSize) -> Self {
        if size.width < 360 || size.height < 40 { return .bubble }
        return size.height < 80 ? .compact : .regular
    }
}

/// Track the whole nonactivating panel even while another app is frontmost.
/// SwiftUI onHover can miss this surface when the native resize layer is above it.
struct SubtitlePointerTracking: NSViewRepresentable {
    @Binding var isInside: Bool
    func makeNSView(context: Context) -> TrackingView { TrackingView(isInside: $isInside) }
    func updateNSView(_ view: TrackingView, context: Context) { view.isInside = $isInside }

    final class TrackingView: NSView {
        var isInside: Binding<Bool>
        private var area: NSTrackingArea?
        private var trackedBounds: NSRect?
        init(isInside: Binding<Bool>) {
            self.isInside = isInside
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Hover state redraws must not replace the area or resample the
            // pointer; only geometry changes need a new initial containment check.
            guard area == nil || trackedBounds != bounds else { return }
            trackedBounds = bounds
            if let area { removeTrackingArea(area) }
            let tracking = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .enabledDuringMouseDrag], owner: self)
            addTrackingArea(tracking)
            area = tracking
            // Initialize after layout, including windows opened under the pointer
            // and bounds changed by a resize, without mutating SwiftUI during layout.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let inside = self.window.map {
                    $0.isVisible && self.bounds.contains(self.convert($0.mouseLocationOutsideOfEventStream, from: nil))
                } ?? false
                self.setInside(inside)
            }
        }
        override func mouseMoved(with event: NSEvent) { setInside(bounds.contains(convert(event.locationInWindow, from: nil))) }
        override func mouseEntered(with event: NSEvent) { setInside(true) }
        override func mouseExited(with event: NSEvent) { setInside(false) }
        private func setInside(_ value: Bool) {
            if isInside.wrappedValue != value { isInside.wrappedValue = value }
        }
    }
}

/// WindowServer owns the drag. A SwiftUI local-coordinate drag moves its own
/// coordinate space on each event and can feed that movement back into the next
/// translation, causing the small floating window to jitter or leave trails.
struct SubtitleBubbleInteraction: NSViewRepresentable {
    let controller: SubtitlePanelController
    func makeNSView(context: Context) -> DragView { DragView(controller: controller) }
    func updateNSView(_ view: DragView, context: Context) { }

    final class DragView: NSView {
        let controller: SubtitlePanelController
        private var downEvent: NSEvent?
        private var handedOffDrag = false
        init(controller: SubtitlePanelController) {
            self.controller = controller
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(L10n.text("展开字幕"))
            toolTip = "展开字幕 · 拖动移动位置"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            trace("down")
            downEvent = event
            handedOffDrag = false
        }
        override func mouseDragged(with event: NSEvent) {
            trace("dragged")
            guard controller.isBubble, !handedOffDrag, let downEvent else { return }
            handedOffDrag = true
            // This returns immediately and WindowServer may consume mouseUp.
            // Never interpret its return as a completed click.
            window?.performDrag(with: downEvent)
        }
        override func mouseUp(with event: NSEvent) {
            trace("up handedOff=\(handedOffDrag)")
            if !handedOffDrag { controller.restoreFromBubble() }
            downEvent = nil
        }
        override func accessibilityPerformPress() -> Bool { trace("AX press"); controller.restoreFromBubble(); return true }
        private func trace(_ value: String) {
            if CommandLine.arguments.contains("--subtitle-panel-check") { NSLog("Bubble pointer: %@", value) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            for (title, action) in [("展开字幕", #selector(expand)), ("返回首页", #selector(home)), ("关闭字幕并停止监听", #selector(close))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }
        @objc private func expand() { controller.restoreFromBubble() }
        @objc private func home() { controller.returnHome() }
        @objc private func close() { controller.closeSubtitles() }
    }
}

/// AppKit's own traffic-light controls, with ordinary close/minimize/zoom actions.
/// The nonactivating panel remains borderless so its full-screen eligibility and
/// compact content geometry do not depend on a separate title bar.
struct SubtitleNativeControls: NSViewRepresentable {
    var onZoom: () -> Void
    var onClose: () -> Void
    func makeNSView(context: Context) -> NativeControlsView { NativeControlsView(onZoom: onZoom, onClose: onClose) }
    func updateNSView(_ view: NativeControlsView, context: Context) { view.onZoom = onZoom; view.onClose = onClose }

    final class NativeControlsView: NSView {
        var onZoom: () -> Void
        var onClose: () -> Void
        private(set) var buttons: [NSButton] = []
        init(onZoom: @escaping () -> Void, onClose: @escaping () -> Void) {
            self.onZoom = onZoom
            self.onClose = onClose
            super.init(frame: NSRect(x: 0, y: 0, width: 66, height: 26))
            let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            let names = ["关闭字幕并停止监听", "最小化到程序坞", "放大／恢复字幕窗口"]
            for (index, kind) in kinds.enumerated() {
                guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.setFrameOrigin(NSPoint(x: 4 + index * 20, y: 6))
                button.isEnabled = true
                button.toolTip = names[index]
                button.setAccessibilityLabel(names[index])
                button.setAccessibilityIdentifier("subtitle.window.\(index)")
                button.target = self
                button.action = [#selector(closeWindow), #selector(minimizeWindow), #selector(zoomWindow)][index]
                addSubview(button)
                buttons.append(button)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func closeWindow() { onClose() }
        @objc private func minimizeWindow() { window?.miniaturize(nil) }
        @objc private func zoomWindow() { onZoom() }
    }
}

struct SubtitleResizeSurface: NSViewRepresentable {
    @ObservedObject var controller: SubtitlePanelController
    func makeNSView(context: Context) -> ResizeView { ResizeView(controller: controller) }
    func updateNSView(_ view: ResizeView, context: Context) { view.window?.invalidateCursorRects(for: view) }

    final class ResizeView: NSView {
        struct Edges: OptionSet {
            let rawValue: Int
            static let left = Self(rawValue: 1), right = Self(rawValue: 2)
            static let bottom = Self(rawValue: 4), top = Self(rawValue: 8)
        }
        let controller: SubtitlePanelController
        private var tracking: NSTrackingArea?
        private var activeEdges: Edges = []
        private var initialFrame = NSRect.zero
        private var initialMouse = NSPoint.zero

        init(controller: SubtitlePanelController) { self.controller = controller; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func edges(at point: NSPoint) -> Edges {
            var edges: Edges = []
            if point.x < 6 { edges.insert(.left) }
            if point.x > bounds.width - 6 { edges.insert(.right) }
            if point.y < 6 { edges.insert(.bottom) }
            if point.y > bounds.height - 6 { edges.insert(.top) }
            if point.x < 12 && point.y < 12 { edges.formUnion([.left, .bottom]) }
            if point.x < 12 && point.y > bounds.height - 12 { edges.formUnion([.left, .top]) }
            if point.x > bounds.width - 12 && point.y < 12 { edges.formUnion([.right, .bottom]) }
            if point.x > bounds.width - 12 && point.y > bounds.height - 12 { edges.formUnion([.right, .top]) }
            return edges
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !controller.isBubble else { return nil }
            return edges(at: point).isEmpty ? nil : self
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self)
            tracking = area
            addTrackingArea(area)
        }
        override func mouseMoved(with event: NSEvent) {
            let hovered = !edges(at: convert(event.locationInWindow, from: nil)).isEmpty
            if controller.isResizeHover != hovered { controller.isResizeHover = hovered }
        }
        override func mouseExited(with event: NSEvent) { controller.isResizeHover = false }
        override func resetCursorRects() {
            guard !controller.isBubble else { return }
            let w = bounds.width, h = bounds.height, edge: CGFloat = 6, corner: CGFloat = 12
            let diagonalA = diagonalCursor("arrow.up.left.and.arrow.down.right")
            let diagonalB = diagonalCursor("arrow.up.right.and.arrow.down.left")
            addCursorRect(NSRect(x: 0, y: corner, width: edge, height: max(0, h - corner * 2)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: w - edge, y: corner, width: edge, height: max(0, h - corner * 2)), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: corner, y: 0, width: max(0, w - corner * 2), height: edge), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: corner, y: h - edge, width: max(0, w - corner * 2), height: edge), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: 0, y: h - corner, width: corner, height: corner), cursor: diagonalA)
            addCursorRect(NSRect(x: w - corner, y: 0, width: corner, height: corner), cursor: diagonalA)
            addCursorRect(NSRect(x: 0, y: 0, width: corner, height: corner), cursor: diagonalB)
            addCursorRect(NSRect(x: w - corner, y: h - corner, width: corner, height: corner), cursor: diagonalB)
        }
        private func diagonalCursor(_ symbol: String) -> NSCursor {
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return .crosshair }
            image.size = NSSize(width: 18, height: 18)
            return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
        }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            activeEdges = edges(at: convert(event.locationInWindow, from: nil))
            initialFrame = window.frame
            initialMouse = NSEvent.mouseLocation
            controller.beginUserResize()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let delta = NSPoint(x: NSEvent.mouseLocation.x - initialMouse.x, y: NSEvent.mouseLocation.y - initialMouse.y)
            var frame = initialFrame
            if activeEdges.contains(.left) { frame.origin.x += delta.x; frame.size.width -= delta.x }
            if activeEdges.contains(.right) { frame.size.width += delta.x }
            if activeEdges.contains(.bottom) { frame.origin.y += delta.y; frame.size.height -= delta.y }
            if activeEdges.contains(.top) { frame.size.height += delta.y }
            if frame.width < 48 { if activeEdges.contains(.left) { frame.origin.x = initialFrame.maxX - 48 }; frame.size.width = 48 }
            if frame.height < 32 { if activeEdges.contains(.bottom) { frame.origin.y = initialFrame.maxY - 32 }; frame.size.height = 32 }
            window.setFrame(frame, display: true)
        }
        override func mouseUp(with event: NSEvent) { activeEdges = []; controller.finishUserResize() }
    }
}
