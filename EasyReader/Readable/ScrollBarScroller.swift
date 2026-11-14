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

    /// Puts `bounds` (screen coordinates) `options.padding` below the top of the scroll area, unless already visible.
    func scroll(to bounds: CGRect, contentFrame: CGRect, options: ScrollOptions) {
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
            verticalTask = set(scrollBar, to: value, options: options)
        }
    }

    nonisolated static func scrollValue(offset: CGFloat, scrollableLength: CGFloat) -> CGFloat {
        guard scrollableLength.isNormal, scrollableLength > 0 else { return 0 }
        return min(max(offset / scrollableLength, 0), 1)
    }

    private func set(_ scrollBar: AXElement, to target: CGFloat, options: ScrollOptions) -> Task<Void, Never>? {
        guard options.smooth, let current: CGFloat = try? scrollBar.attribute(.value) else {
            try? scrollBar.set(.value, to: target)
            return nil
        }

        let frameInterval = 1.0 / options.updateRate
        let totalFrames = Int(options.duration / frameInterval)
        let step = (target - current) / CGFloat(totalFrames)
        let frameNanoseconds = UInt64(frameInterval * 1_000_000_000)

        return Task {
            for index in 1...max(totalFrames, 1) {
                // Throws only when a newer scroll cancelled this one.
                guard (try? await Task.sleep(nanoseconds: frameNanoseconds)) != nil else { return }
                let value = index >= totalFrames ? target : current + (step * CGFloat(index))
                do {
                    try scrollBar.set(.value, to: value)
                } catch {
                    return  // element went away
                }
            }
        }
    }
}
