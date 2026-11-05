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
    private var horizontalScrollTask: Task<Void, Never>?
    private var verticalScrollTask: Task<Void, Never>?

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
              let elementFrame: CGRect = try? handle.attribute(.frame),
              let scrollAreaFrame: CGRect = try? scrollArea?.attribute(.frame)
        else {
            Log.scroll.debug("scroll to \(selection): missing bounds, frame, or scroll area")
            return
        }
        let contentFrame = self.contentFrame(elementFrame: elementFrame, scrollAreaFrame: scrollAreaFrame)

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
                horizontalScrollTask?.cancel()
                horizontalScrollTask = lerpScroll(for: horizontalScrollBar, to: scrollValue, options: options)
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
                verticalScrollTask?.cancel()
                verticalScrollTask = lerpScroll(for: verticalScrollBar, to: scrollValue, options: options)
            } else {
                try? verticalScrollBar.setAttribute(.value, value: scrollValue)
            }
        }
    }

    /// The scrollable content's rect. AppKit's `NSTextView` reports its full (document-sized) frame, but some
    /// text areas (e.g. SwiftUI's `TextEditor`) report only their visible part, which made every scroll go to
    /// the top. Then fall back to the bounds of the whole text, which track the scroll position.
    private func contentFrame(elementFrame: CGRect, scrollAreaFrame: CGRect) -> CGRect {
        guard elementFrame.height <= scrollAreaFrame.height || elementFrame.width <= scrollAreaFrame.width,
              let length = fullText?.utf16.count, length > 0,
              let textBounds: CGRect = try? handle.parameterizedAttribute(
                  .boundsForRangeParameterized, param: CFRange(location: 0, length: length)),
              textBounds.size != .zero
        else { return elementFrame }
        let contentFrame = elementFrame.union(textBounds)
        Log.scroll.debug("element frame \(elementFrame) not document-sized; using text bounds → \(contentFrame)")
        return contentFrame
    }

    /// Scroll bar value (0...1) that puts `offset` at the top/left. Padding can push the offset below 0
    /// near the start, and content near the end can't scroll any further than 1.
    static func scrollValue(offset: CGFloat, scrollableLength: CGFloat) -> CGFloat {
        guard scrollableLength.isNormal, scrollableLength > 0 else { return 0 }
        return min(max(offset / scrollableLength, 0), 1)
    }

    private func lerpScroll(for scrollBar: UIElement, to target: CGFloat, options: ScrollOptions) -> Task<Void, Never>? {
        guard let current: CGFloat = try? scrollBar.attribute(.value) else {
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
