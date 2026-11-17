import Cocoa

/// Scrolls an `AXScrollArea` by setting its scroll bars' value (0...1), one set per frame when smooth.
@MainActor
final class ScrollBarScroller {
    let scrollArea: AXElement
    private var horizontalTask: Task<Void, Never>?
    private var verticalTask: Task<Void, Never>?

    init(_ scrollArea: AXElement) {
        self.scrollArea = scrollArea
    }

    var frame: CGRect? { try? scrollArea.attribute(.frame) }
    var hasVerticalScrollBar: Bool { verticalScrollBar != nil }
    private var verticalScrollBar: AXElement? { try? scrollArea.attribute(.verticalScrollBar) }
    private var horizontalScrollBar: AXElement? { try? scrollArea.attribute(.horizontalScrollBar) }

    /// Bounds of the target and the content frame, measured again.
    typealias Measure = @MainActor () -> (bounds: CGRect, contentFrame: CGRect)?

    /// Puts `bounds` (screen coordinates) `options.padding` below the scroll area's top unless visible; `remeasure` corrects it once scrolled.
    func scroll(to bounds: CGRect, contentFrame: CGRect, options: ScrollOptions, remeasure: Measure? = nil) {
        guard let scrollAreaFrame = frame else {
            Log.scroll.debug("scroll to \(bounds): missing scroll area frame")
            return
        }
        let padding = min(CGFloat(options.padding), scrollAreaFrame.height / 2)
        guard bounds.size != .zero, !scrollAreaFrame.insetBy(dx: 0, dy: padding).contains(bounds) else {
            Log.scroll.debug("scroll to \(bounds): already visible")
            return
        }

        // Left alone while the start of the target is in view horizontally.
        let horizontallyVisible =
            bounds.minX >= scrollAreaFrame.minX && min(bounds.maxX, bounds.minX + scrollAreaFrame.width) <= scrollAreaFrame.maxX
        if !horizontallyVisible, let scrollBar = horizontalScrollBar {
            let value = Self.scrollValue(
                offset: bounds.origin.x - contentFrame.origin.x,
                scrollableLength: contentFrame.width - scrollAreaFrame.width
            )
            Log.scroll.debug("horizontal scroll → \(value) (smooth: \(options.smooth))")
            horizontalTask?.cancel()
            horizontalTask = set(scrollBar, to: value, options: options)
        }
        if let scrollBar = verticalScrollBar {
            let value = Self.scrollValue(
                offset: (bounds.origin.y - padding) - contentFrame.origin.y,
                scrollableLength: contentFrame.height - scrollAreaFrame.height
            )
            Log.scroll.debug("vertical scroll → \(value) (smooth: \(options.smooth))")
            verticalTask?.cancel()
            verticalTask = set(scrollBar, to: value, options: options, correctingTo: padding, remeasure: remeasure)
        }
    }

    nonisolated static func scrollValue(offset: CGFloat, scrollableLength: CGFloat) -> CGFloat {
        guard scrollableLength.isNormal, scrollableLength > 0 else { return 0 }
        return (offset / scrollableLength).clamped(to: 0...1)
    }

    /// TextKit 2 estimates the height of text not laid out yet (a far scroll lands hundreds of points off): measure again and nudge.
    private func correct(_ scrollBar: AXElement, padding: CGFloat, remeasure: Measure) async {
        for _ in 0..<3 {
            // Other apps apply a set asynchronously.
            guard (try? await Task.sleep(seconds: 0.05)) != nil,
                let scrollAreaFrame = frame, let measured = remeasure(),
                let current: CGFloat = try? scrollBar.attribute(.value)
            else { return }
            let scrollableLength = measured.contentFrame.height - scrollAreaFrame.height
            let offset = measured.bounds.minY - (scrollAreaFrame.minY + padding)
            guard abs(offset) > 1, scrollableLength > 0 else { return }
            let value = (current + offset / scrollableLength).clamped(to: 0...1)
            guard value != current else { return }
            Log.scroll.debug("correcting vertical scroll by \(offset) pt → \(value)")
            try? scrollBar.set(.value, to: value)
        }
    }

    private func set(
        _ scrollBar: AXElement, to target: CGFloat, options: ScrollOptions, correctingTo padding: CGFloat = 0, remeasure: Measure? = nil
    ) -> Task<Void, Never>? {
        guard options.smooth, let current: CGFloat = try? scrollBar.attribute(.value) else {
            try? scrollBar.set(.value, to: target)
            guard let remeasure else { return nil }
            return Task { await correct(scrollBar, padding: padding, remeasure: remeasure) }
        }

        let frameInterval = 1.0 / options.updateRate
        let totalFrames = Int(options.duration / frameInterval)
        let step = (target - current) / CGFloat(totalFrames)

        return Task {
            for index in 1...max(totalFrames, 1) {
                // Throws only when a newer scroll cancelled this one.
                guard (try? await Task.sleep(seconds: frameInterval)) != nil else { return }
                let value = index >= totalFrames ? target : current + (step * CGFloat(index))
                do {
                    try scrollBar.set(.value, to: value)
                } catch {
                    return  // element went away
                }
            }
            if let remeasure { await correct(scrollBar, padding: padding, remeasure: remeasure) }
        }
    }
}
