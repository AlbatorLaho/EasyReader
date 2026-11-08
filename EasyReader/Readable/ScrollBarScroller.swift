//
//  ScrollBarScroller.swift
//  EasyReader
//

import AXSwift
import Cocoa

/// Scrolls an `AXScrollArea` by setting its scroll bars' `AXValue` (0...1 of the scrollable length), animated when
/// `ScrollOptions.smooth`. Used for text areas and for web areas whose browser exposes the page's scroll bars
/// (WebKit). Each set is applied asynchronously by the target app, so the animation is a series of sets, one per frame.
@MainActor
final class ScrollBarScroller {
    let scrollArea: UIElement
    private var horizontalTask: Task<Void, Never>?
    private var verticalTask: Task<Void, Never>?

    init(_ scrollArea: UIElement) {
        self.scrollArea = scrollArea
    }

    var frame: CGRect? { try? scrollArea.attribute(.frame) }
    var hasVerticalScrollBar: Bool { verticalScrollBar != nil }
    private var verticalScrollBar: UIElement? { try? scrollArea.attribute(.verticalScrollBar) }
    private var horizontalScrollBar: UIElement? { try? scrollArea.attribute(.horizontalScrollBar) }

    /// Scrolls so that `bounds` (screen coordinates, like all AX frames) sits `options.padding` below the top (and at
    /// the left) of the scroll area, unless it's already visible. `contentFrame` is the scrollable content's frame.
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

        if let scrollBar = horizontalScrollBar {
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

    /// Scroll bar value (0...1) that puts `offset` at the top/left. Padding can push the offset below 0
    /// near the start, and content near the end can't scroll any further than 1.
    nonisolated static func scrollValue(offset: CGFloat, scrollableLength: CGFloat) -> CGFloat {
        guard scrollableLength.isNormal, scrollableLength > 0 else { return 0 }
        return min(max(offset / scrollableLength, 0), 1)
    }

    /// Sets `scrollBar` to `target`, at once or (smooth) animated over `options.duration`.
    private func set(_ scrollBar: UIElement, to target: CGFloat, options: ScrollOptions) -> Task<Void, Never>? {
        guard options.smooth, let current: CGFloat = try? scrollBar.attribute(.value) else {
            try? scrollBar.setAttribute(.value, value: target)
            return nil
        }

        let frameInterval = 1.0 / options.updateRate
        let totalFrames = Int(options.duration / frameInterval)
        let step = (target - current) / CGFloat(totalFrames)
        let frameNanoseconds = UInt64(frameInterval * 1_000_000_000)

        return Task {
            for frame in 0...max(totalFrames, 0) {
                // Throws only when cancelled by a newer scroll.
                guard (try? await Task.sleep(nanoseconds: frameNanoseconds)) != nil else { return }
                let value = frame >= totalFrames ? target : current + (step * CGFloat(frame))
                do {
                    try scrollBar.setAttribute(.value, value: value)
                } catch {
                    return  // element went away
                }
            }
        }
    }
}
