import AppKit
import SwiftUI

/// Holds the user's reading position independently of SwiftUI's layout passes.
/// A changing document height is not a scroll gesture.
struct SubtitleHistoryScroll: NSViewRepresentable {
    let latestID: UUID?
    let size: CGSize

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.update(latestID: latestID, viewport: size)
    }

    final class Anchor: NSView {
        private weak var scroll: NSScrollView?
        private var lastID: UUID?
        private var viewport = CGSize.zero
        private var following = true
        private var readingOffset: CGFloat = 0
        private var liveScrolling = false
        private var adjustingOffset = false
        private var queued = false
        private var lastClipSize = CGSize.zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        func update(latestID: UUID?, viewport: CGSize) {
            attach()
            guard lastID != latestID || self.viewport != viewport else { return }
            lastID = latestID
            self.viewport = viewport
            scheduleAlignment()
        }

        private func attach() {
            let next = enclosingScrollView
            guard next !== scroll else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            scroll = next
            guard let next, let document = next.documentView else { return }
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
            following = maximum - readingOffset <= 2
        }

        @objc private func clipChanged(_ note: Notification) {
            guard !adjustingOffset, let scroll else { return }
            let size = scroll.contentView.bounds.size
            if size != lastClipSize {
                lastClipSize = size
                scheduleAlignment()
                return
            }
            if liveScrolling { rememberPosition(); return }
            // Non-gesture mouse wheels, scrollbar clicks and keyboard scrolling
            // do not consistently send the live-scroll notification sequence.
            guard let event = NSApp.currentEvent, event.window === scroll.window else { return }
            switch event.type {
            case .scrollWheel, .keyDown: rememberPosition()
            case .leftMouseDown, .leftMouseDragged:
                if let scroller = scroll.verticalScroller,
                   scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) {
                    rememberPosition()
                }
            default: break
            }
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
            guard !liveScrolling, let scroll, let document = scroll.documentView else { return }
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
