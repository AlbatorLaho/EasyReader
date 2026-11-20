import Cocoa

// Tagged PDFs: selecting leaves through a `PageSelector`.
extension PDFReadableElement {
    /// Every text leaf of a page, also those left out of `text`: what a `PageSelector` locates.
    struct SelectorLeaf {
        let element: AXElement
        let value: String
        let isSettable: Bool
    }

    /// Tagged PDFs: a leaf whose selected range runs on through the rest of the page's text.
    struct PageSelector {
        let element: AXElement
        /// Where the leaves after it start, relative to it.
        let starts: [AXElement: Int]
        /// The page's text from the selector's start.
        let text: NSString
    }

    /// One selection set: `range` on `element` should select `expected`.
    struct Target {
        let element: AXElement
        let range: CFRange
        let expected: String
    }

    /// Through a `PageSelector`, also selects what's between the parts; nil if that has letters (leaf misplaced).
    func target(of piece: SelectionStep) -> Target? {
        guard let first = piece.parts.first else { return nil }
        if leaves[first.leaf].isSettable {
            return Target(element: first.element, range: first.range, expected: string(in: piece.range))
        }
        guard let selector = selector(ofPage: leaves[first.leaf].page) else { return nil }
        var ranges: [NSRange] = []
        for part in piece.parts {
            guard let start = selector.starts[part.element] else { return nil }
            ranges.append(NSRange(location: start + part.range.location, length: part.range.length))
        }
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            guard next.location >= NSMaxRange(previous),
                !selector.text.substring(with: NSRange(location: NSMaxRange(previous), length: next.location - NSMaxRange(previous)))
                    .contains(where: \.isLetter)
            else { return nil }
        }
        let range = NSRange(location: ranges[0].location, length: NSMaxRange(ranges[ranges.count - 1]) - ranges[0].location)
        guard NSMaxRange(range) <= selector.text.length else { return nil }
        return Target(
            element: selector.element, range: CFRange(location: range.location, length: range.length),
            expected: selector.text.substring(with: range))
    }

    /// Measured once by selecting from a candidate to the page's end (on screen only), then collapsed.
    func selector(ofPage page: Int) -> PageSelector? {
        if let measured = pageSelectors[page] { return measured }
        guard let texts = selectorLeaves[page], selectorFailures[page, default: 0] < Self.maxSelectorAttempts else { return nil }
        var selector: PageSelector?
        var isVisible = visiblePages().contains(page)
        for (index, candidate) in texts.enumerated() where candidate.isSettable {
            if !isVisible {
                try? candidate.element.perform(.scrollToVisible)
                isVisible = true
            }
            guard (try? candidate.element.set(.selectedTextRange, to: CFRange(location: 0, length: 1 << 20))) != nil,
                let pageText = try? handle.attribute(.selectedText), !pageText.isEmpty
            else { continue }
            let following = texts[index...]
            var starts: [AXElement: Int] = [:]
            for (text, start) in zip(following, Self.starts(of: following.map(\.value), in: pageText)) {
                if let start { starts[text.element] = start }
            }
            Log.accessibility.debug("pdf: page \(page): selector found \(starts.count) of \(following.count) leaves")
            selector = PageSelector(element: candidate.element, starts: starts, text: pageText as NSString)
            try? candidate.element.set(.selectedTextRange, to: CFRange(location: 0, length: 0))
            reportAfterSet = try? handle.attribute(.selectedText)
            break
        }
        if let selector { pageSelectors[page] = selector } else { selectorFailures[page, default: 0] += 1 }
        return selector
    }

    /// Each value searched for just after the previous one (page text also has separators and list labels).
    nonisolated static func starts(of values: [String], in text: String) -> [Int?] {
        let text = text as NSString
        var cursor = 0
        return values.map { value in
            guard !value.isEmpty else { return nil }
            let window = NSRange(location: cursor, length: min(value.utf16.count + 32, text.length - cursor))
            guard window.length > 0 else { return nil }
            let found = text.range(of: value, options: .literal, range: window)
            guard found.location != NSNotFound else { return nil }
            cursor = found.location + found.length
            return found.location
        }
    }
}
