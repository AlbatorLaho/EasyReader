import Cocoa

/// A click-through window highlighting text where the app won't let us select it. Re-polls the rects while shown.
@MainActor
final class HighlightOverlay {
    private var window: NSWindow?
    private var refresh: Task<Void, Never>?
    private var rects: (() -> [CGRect]?)?
    private var probe: (() -> CGRect?)?
    private var shown: [CGRect] = []

    /// Rects are re-polled this often (several AX calls per line), the probe (one) every tick.
    private static let refreshInterval = 0.25
    private static let probeInterval = 1.0 / 30

    var isVisible: Bool { window?.isVisible == true }

    /// `rects`: screen coordinates, top-left origin (nil hides); `probe`: a cheap rect moving with the text, so a scroll is followed within a tick.
    func show(_ rects: @escaping () -> [CGRect]?, probe: (() -> CGRect?)? = nil) {
        self.rects = rects
        self.probe = probe
        update()
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            var lastProbe = self?.probe?()
            var sinceUpdate = 0.0
            while !Task.isCancelled {
                let interval = self?.probe == nil ? Self.refreshInterval : Self.probeInterval
                try? await Task.sleep(seconds: interval)
                guard let self, !Task.isCancelled else { return }
                sinceUpdate += interval
                let probed = probe?()
                guard probed != lastProbe || sinceUpdate >= Self.refreshInterval - 0.001 else { continue }
                lastProbe = probed
                sinceUpdate = 0
                update()
            }
        }
    }

    func hide() {
        refresh?.cancel()
        refresh = nil
        rects = nil
        probe = nil
        shown = []
        window?.orderOut(nil)
    }

    /// Chromium gives a zero-size rect at the web area's origin while it has no character layout.
    // A zero-width character (a collapsed space) still has its line's height.
    static func hasSize(_ rect: CGRect) -> Bool { rect.width >= 1 || rect.height >= 1 }

    /// One rect per line of `range` in `leaf`: `AXBoundsForRange` gives the union of all lines.
    static func lineRects(of leaf: AXElement, _ range: Selection) -> [CGRect] {
        func bounds(_ lower: Int, _ upper: Int) -> CGRect? {
            guard let rect = try? leaf.attribute(.boundsForRange, for: CFRange(location: lower, length: upper - lower)), hasSize(rect)
            else { return nil }
            return rect
        }
        var rects: [CGRect] = []
        var lower = range.lowerBound
        while lower < range.upperBound, rects.count < 50 {
            guard let first = bounds(lower, lower + 1), let whole = bounds(lower, range.upperBound) else { break }
            if whole.height < first.height * 1.5 {
                rects.append(whole)
                break
            }
            // Binary search for the first character on the next line.
            var low = lower + 1
            var high = range.upperBound
            while low < high {
                let middle = (low + high) / 2
                if let rect = bounds(middle, middle + 1), rect.height >= 1, rect.midY <= first.maxY {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if let line = bounds(lower, low) { rects.append(line) }
            lower = low
        }
        return rects
    }

    private func update() {
        guard let rects = rects?(), !rects.isEmpty, let screen = NSScreen.screens.first else {
            shown = []
            window?.orderOut(nil)
            return
        }
        guard rects != shown || !isVisible else { return }
        shown = rects
        // AX rects have their origin at the top left of the main screen; AppKit at its bottom left.
        let flipped = rects.map { CGRect(x: $0.minX, y: screen.frame.maxY - $0.maxY, width: $0.width, height: $0.height) }
        let frame = flipped.reduce(flipped[0]) { $0.union($1) }.insetBy(dx: -2, dy: -2)
        let window = self.window ?? makeWindow()
        window.setFrame(frame, display: false)
        let view = window.contentView as! HighlightView
        view.rects = flipped.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        view.needsDisplay = true
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.contentView = HighlightView()
        self.window = window
        return window
    }
}

private final class HighlightView: NSView {
    var rects: [CGRect] = []

    override func draw(_ dirtyRect: NSRect) {
        NSColor.findHighlightColor.withAlphaComponent(0.35).setFill()
        for rect in rects {
            NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
    }
}
