import AppKit
import SwiftUI

/// Holds the user's reading position independently of SwiftUI's layout passes.
/// A changing document height is not a scroll gesture.
struct SubtitleHistoryScroll: NSViewRepresentable {
    let latestID: UUID?
    let size: CGSize
    let rowHeight: CGFloat

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.update(latestID: latestID, viewport: size, rowHeight: rowHeight)
    }

    final class Anchor: NSView {
        private weak var scroll: NSScrollView?
        private var lastID: UUID?
        private var viewport = CGSize.zero
        private var following = true
        private var readingOffset: CGFloat = 0
        private var rowHeight: CGFloat = 1
        private var gestureStart: CGFloat?
        private var settleTask: DispatchWorkItem?
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
            guard next !== scroll else { return }
            let center = NotificationCenter.default
            center.removeObserver(self)
            settleTask?.cancel()
            gestureStart = nil
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
            settleAfterWheel()
        }

        private func rememberPosition() {
            guard !adjustingOffset, let scroll, let document = scroll.documentView else { return }
            let bounds = scroll.contentView.bounds
            let maximum = max(0, document.bounds.height - bounds.height)
            let y = min(maximum, max(0, bounds.minY))
            if gestureStart == nil { gestureStart = following ? maximum : readingOffset }
            readingOffset = document.isFlipped ? y : maximum - y
            following = maximum - readingOffset <= 2
            if !liveScrolling { settleAfterWheel() }
        }

        // Let native scrolling and momentum run freely. When the user rests,
        // settle on a cue boundary without pinning them back to the newest cue.
        private func settleAfterWheel() {
            settleTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                guard let self, !self.liveScrolling, let start = self.gestureStart,
                      let scroll = self.scroll, let document = scroll.documentView else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.settleAfterWheel()
                    return
                }
                self.gestureStart = nil
                guard !self.following else { return }
                let row = self.rowHeight
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                var target = (self.readingOffset / row).rounded() * row
                // A single wheel notch must also advance a line.
                if abs(target - start) < 1 && abs(self.readingOffset - start) >= 1 {
                    target += self.readingOffset > start ? row : -row
                }
                self.readingOffset = min(maximum, max(0, target))
                self.following = maximum - self.readingOffset <= 2
                self.align()
            }
            settleTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(170), execute: task)
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
