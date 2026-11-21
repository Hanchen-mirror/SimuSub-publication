import AppKit
import SwiftUI

/// Holds the user's reading position independently of SwiftUI's layout passes.
/// A changing document height is not a scroll gesture.
struct SubtitleHistoryScroll: NSViewRepresentable {
    let latestID: UUID?
    let size: CGSize
    let rowHeight: CGFloat
    var onFollowingChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.onFollowingChanged = onFollowingChanged
        view.update(latestID: latestID, viewport: size, rowHeight: rowHeight)
    }

    final class Anchor: NSView {
        private weak var scroll: NSScrollView?
        private weak var observedDocument: NSView?
        private var lastID: UUID?
        private var viewport = CGSize.zero
        var onFollowingChanged: ((Bool) -> Void)?
        private var following = true {
            didSet {
                guard following != oldValue else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil else { return }
                    self.onFollowingChanged?(self.following)
                }
            }
        }
        private var readingOffset: CGFloat = 0
        private var rowHeight: CGFloat = 1
        private var handlingWheel = false
        private var liveScrolling = false
        private var adjustingOffset = false
        private var queued = false
        private var lastClipSize = CGSize.zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
            (window as? SubtitleFloatingPanel)?.historyAnchor = self
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        func update(latestID: UUID?, viewport: CGSize, rowHeight: CGFloat) {
            attach()
            guard lastID != latestID || self.viewport != viewport || self.rowHeight != rowHeight else { return }
            self.rowHeight = max(1, rowHeight)
            lastID = latestID
            self.viewport = viewport
            scheduleAlignment()
        }

        private func attach() {
            let next = enclosingScrollView
            let document = next?.documentView
            guard next !== scroll || document !== observedDocument else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            if let panel = scroll?.window as? SubtitleFloatingPanel, panel.historyAnchor === self { panel.historyAnchor = nil }
            liveScrolling = false
            scroll = next
            observedDocument = document
            guard let next, let document else { return }
            (next.window as? SubtitleFloatingPanel)?.historyAnchor = self
            lastClipSize = next.contentView.bounds.size
            next.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            center.addObserver(self, selector: #selector(startScroll), name: NSScrollView.willStartLiveScrollNotification, object: next)
            center.addObserver(self, selector: #selector(duringScroll), name: NSScrollView.didLiveScrollNotification, object: next)
            center.addObserver(self, selector: #selector(endScroll), name: NSScrollView.didEndLiveScrollNotification, object: next)
            center.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: next.contentView)
            center.addObserver(self, selector: #selector(documentChanged), name: NSView.frameDidChangeNotification, object: document)
            scheduleAlignment()
        }

        // Text selection and popover buttons can own the AppKit hit view over a
        // cue. Route this panel's wheel to its native scroll view exactly once.
        func handleWheel(_ event: NSEvent) -> Bool {
            guard let scroll, let window = scroll.window else { return false }
            let location = event.window == nil ? window.convertPoint(fromScreen: event.locationInWindow) : event.locationInWindow
            guard scroll.bounds.contains(scroll.convert(location, from: nil)) else { return false }
            handlingWheel = true
            scroll.scrollWheel(with: event)
            rememberPosition()
            handlingWheel = false
            return true
        }

        @objc private func startScroll(_ note: Notification) { liveScrolling = true }

        @objc private func duringScroll(_ note: Notification) { rememberPosition() }

        @objc private func endScroll(_ note: Notification) {
            rememberPosition()
            liveScrolling = false
        }

        private func rememberPosition() {
            guard !adjustingOffset, let scroll, let document = scroll.documentView else { return }
            let bounds = scroll.contentView.bounds
            let maximum = max(0, document.bounds.height - bounds.height)
            let y = min(maximum, max(0, bounds.minY))
            readingOffset = document.isFlipped ? y : maximum - y
            following = maximum - readingOffset < 0.5
        }

        @objc private func clipChanged(_ note: Notification) {
            guard !adjustingOffset, let scroll else { return }
            let size = scroll.contentView.bounds.size
            if size != lastClipSize {
                lastClipSize = size
                scheduleAlignment()
                return
            }
            if liveScrolling || handlingWheel || scroll.verticalScroller?.hitPart == .knob { rememberPosition(); return }
            // Non-gesture mouse wheels, scrollbar clicks and keyboard scrolling
            // do not consistently send the live-scroll notification sequence.
            // currentEvent can still contain the last key/wheel after it was
            // dispatched. Only input in this viewport can change reading intent.
            if let event = NSApp.currentEvent, event.window === scroll.window,
               ProcessInfo.processInfo.systemUptime - event.timestamp < 0.12 {
                let point = event.locationInWindow
                switch event.type {
                case .scrollWheel where scroll.bounds.contains(scroll.convert(point, from: nil)):
                    rememberPosition()
                    return
                case .keyDown where [116, 119, 121, 115, 125, 126].contains(event.keyCode):
                    if let responder = scroll.window?.firstResponder as? NSView,
                       responder === scroll || responder.isDescendant(of: scroll) {
                        rememberPosition()
                        return
                    }
                case .leftMouseDown, .leftMouseDragged:
                    if let scroller = scroll.verticalScroller,
                       scroller.bounds.contains(scroller.convert(point, from: nil)) {
                        rememberPosition()
                        return
                    }
                default: break
                }
            }
            // SwiftUI can reposition the clip after the document's frame has
            // settled. Restore the live cue (or the user's chosen history row).
            scheduleAlignment()
        }

        @objc private func documentChanged(_ note: Notification) { scheduleAlignment() }

        private func scheduleAlignment() {
            guard !queued else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.queued = false
                self.align()
            }
        }

        private func align() {
            attach()
            guard !liveScrolling, !handlingWheel, let scroll, scroll.verticalScroller?.hitPart != .knob,
                  let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let available = max(0, document.bounds.height - clip.bounds.height)
            let fromTop = following ? available : min(available, readingOffset)
            let target = document.isFlipped ? fromTop : available - fromTop
            guard abs(clip.bounds.minY - target) > 0.25 else { return }
            adjustingOffset = true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            scroll.reflectScrolledClipView(clip)
            adjustingOffset = false
        }
    }
}
