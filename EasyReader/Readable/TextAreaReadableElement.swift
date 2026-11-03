//
//  TextAreaReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa
import AXSwift

extension ReadableElement.Role {
    static let textArea = Self(kAXTextAreaRole)
//    static let textArea: Self = "AXTextArea"
}

final class TextAreaReadableElement: ReadableElement {
    private let scrollArea: UIElement?
    private var horizontalScrollTimer: Timer?
    private var verticalScrollTimer: Timer?

    override var fullText: String? { try? handle.attribute(.value) }
    override var selectedText: String? { try? handle.attribute(.selectedText) }
    override var selection: Selection? {
        get {
            guard let range: CFRange = try? handle.attribute(.selectedTextRange) else { return nil }
            return Selection(range)
        }
        set {
            guard let newSelection = newValue else { return }
            try? handle.setAttribute(.selectedTextRange, value: CFRange(newSelection))
        }
    }

    required init(_ element: UIElement) {
        scrollArea = try? element.parent(with: .scrollArea)
        super.init(element)
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let selectionBounds: CGRect = try? handle.parameterizedAttribute(.boundsForRangeParameterized, param: CFRange(selection)),
              let contentFrame: CGRect = try? handle.attribute(.frame),
              let scrollAreaFrame: CGRect = try? scrollArea?.attribute(.frame)
        else {
            Log.scroll.debug("scroll to \(selection): missing bounds, frame, or scroll area")
            return
        }

        let padding = min(CGFloat(options.padding), scrollAreaFrame.height / 2)
        guard selectionBounds.size != .zero, !scrollAreaFrame.insetBy(dx: 0, dy: padding).contains(selectionBounds) else {
            Log.scroll.debug("scroll to \(selection): already visible (bounds \(selectionBounds))")
            return
        }

        if let horizontalScrollBar: UIElement = try? scrollArea?.attribute(.horizontalScrollBar) {
            let scrollValue = Self.scrollValue(
                offset: selectionBounds.origin.x - contentFrame.origin.x,
                scrollableLength: contentFrame.width - scrollAreaFrame.width
            )
            Log.scroll.debug("horizontal scroll → \(scrollValue) (smooth: \(options.smooth))")
            if options.smooth {
                horizontalScrollTimer?.invalidate()
                horizontalScrollTimer = lerpScroll(for: horizontalScrollBar, to: scrollValue, options: options)
            } else {
                try? horizontalScrollBar.setAttribute(.value, value: scrollValue)
            }
        }
        if let verticalScrollBar: UIElement = try? scrollArea?.attribute(.verticalScrollBar) {
            let scrollValue = Self.scrollValue(
                offset: (selectionBounds.origin.y - padding) - contentFrame.origin.y,
                scrollableLength: contentFrame.height - scrollAreaFrame.height
            )
            Log.scroll.debug("vertical scroll → \(scrollValue) (smooth: \(options.smooth))")
            if options.smooth {
                verticalScrollTimer?.invalidate()
                verticalScrollTimer = lerpScroll(for: verticalScrollBar, to: scrollValue, options: options)
            } else {
                try? verticalScrollBar.setAttribute(.value, value: scrollValue)
            }
        }
    }

    /// Scroll bar value (0...1) that puts `offset` at the top/left. Padding can push the offset below 0
    /// near the start, and content near the end can't scroll any further than 1.
    static func scrollValue(offset: CGFloat, scrollableLength: CGFloat) -> CGFloat {
        guard scrollableLength.isNormal, scrollableLength > 0 else { return 0 }
        return min(max(offset / scrollableLength, 0), 1)
    }

    private func lerpScroll(for scrollBar: UIElement, to target: CGFloat, options: ScrollOptions) -> Timer? {
        guard let current: CGFloat = try? scrollBar.attribute(.value) else {
            try? scrollBar.setAttribute(.value, value: target)
            return nil
        }

        let frameInterval = 1.0 / options.updateRate
        let totalFrames = Int(options.duration / frameInterval)
        let step = (target - current) / CGFloat(totalFrames)
        var currentFrame = 0

        return Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { timer in
            let value: CGFloat
            if currentFrame >= totalFrames {
                timer.invalidate()
                value = target
            } else {
                value = current + (step * CGFloat(currentFrame))
            }
            do {
                try scrollBar.setAttribute(.value, value: value)
            } catch {
                timer.invalidate()  // element went away
            }
            currentFrame += 1
        }
    }
}
