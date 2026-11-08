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
    private let scroller: ScrollBarScroller?

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
        scroller = (try? element.parent(with: .scrollArea)).map(ScrollBarScroller.init)
        super.init(element)
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let scroller,
              let selectionBounds: CGRect = try? handle.parameterizedAttribute(.boundsForRangeParameterized, param: CFRange(selection)),
              let elementFrame: CGRect = try? handle.attribute(.frame),
              let scrollAreaFrame = scroller.frame
        else {
            Log.scroll.debug("scroll to \(selection): missing bounds, frame, or scroll area")
            return
        }
        let contentFrame = self.contentFrame(elementFrame: elementFrame, scrollAreaFrame: scrollAreaFrame)
        scroller.scroll(to: selectionBounds, contentFrame: contentFrame, options: options)
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
}
