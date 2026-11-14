import Cocoa

final class TextAreaReadableElement: ReadableElement {
    private let scroller: ScrollBarScroller?

    override var fullText: String? { try? handle.attribute(.value) }
    override var selectedText: String? { try? handle.attribute(.selectedText) }
    override var selection: Selection? {
        get {
            guard let range = try? handle.attribute(.selectedTextRange) else { return nil }
            return Selection(range)
        }
        set {
            guard let newSelection = newValue else { return }
            try? handle.set(.selectedTextRange, to: CFRange(newSelection))
        }
    }

    required init(_ element: AXElement) {
        scroller = (try? element.parent(with: .scrollArea)).map(ScrollBarScroller.init)
        super.init(element)
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let scroller,
            let selectionBounds = try? handle.attribute(.boundsForRange, for: CFRange(selection)),
            let elementFrame = try? handle.attribute(.frame),
            let scrollAreaFrame = scroller.frame
        else {
            Log.scroll.debug("scroll to \(selection): missing bounds, frame, or scroll area")
            return
        }
        scroller.scroll(
            to: selectionBounds, contentFrame: contentFrame(elementFrame: elementFrame, scrollAreaFrame: scrollAreaFrame), options: options)
    }

    /// SwiftUI's TextEditor reports only its visible rect as its frame; an `NSTextView` is as tall as its text (wraps to the width).
    nonisolated static func showsOnlyVisibleRect(elementFrame: CGRect, scrollAreaFrame: CGRect) -> Bool {
        elementFrame.height <= scrollAreaFrame.height
    }

    // Only then: the whole text's bounds (fetches all of it) give the document's frame.
    private func contentFrame(elementFrame: CGRect, scrollAreaFrame: CGRect) -> CGRect {
        guard Self.showsOnlyVisibleRect(elementFrame: elementFrame, scrollAreaFrame: scrollAreaFrame),
            let length = fullText?.utf16.count, length > 0,
            let textBounds = try? handle.attribute(.boundsForRange, for: CFRange(location: 0, length: length)),
            textBounds.size != .zero
        else { return elementFrame }
        let contentFrame = elementFrame.union(textBounds)
        Log.scroll.debug("element frame \(elementFrame) not document-sized; using text bounds → \(contentFrame)")
        return contentFrame
    }
}
