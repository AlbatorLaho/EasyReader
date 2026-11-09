//
//  PageLeaves.swift
//  EasyReader
//

import Cocoa

/// Chromium only: a web page's text leaves (`AXStaticText`) in document order, located in the page text.
///
/// Chromium converts offsets to markers anchored on the web area itself, so their bounds are the whole page and
/// `AXUIElementForTextMarker` returns the web area: neither highlighting nor scrolling can use them. Leaf elements have
/// both (`AXBoundsForRange` with offsets in the leaf, `AXScrollToVisible`).
///
/// The list comes in one call (a search predicate: ~50 ms for 12k leaves on a long Wikipedia page). A leaf's offset is
/// found by matching its text in the page text right after (or before) a neighbor whose offset is known: one AX call per
/// leaf, so only leaves near the reading position are fetched. Only the first offset is measured through text markers,
/// which costs time proportional to the offset (~150 ms at the end of a long page).
@MainActor
final class PageLeaves {
    struct Leaf {
        let index: Int
        let element: AXElement
        /// The leaf's text in the page text (empty if it couldn't be located).
        let range: Selection
        /// Where `range` starts in the leaf's own text (`AXValue`, the offsets `AXBoundsForRange` takes): leading
        /// whitespace the page text collapsed.
        let valueOffset: Int
    }

    /// The page text the offsets refer to.
    let text: String
    private let utf16: [UInt16]
    private let elements: [AXElement]
    /// Measures the offset of an element's first character in the page text the slow way (through text markers).
    private let measure: (AXElement) -> Int?
    /// Each leaf's text as it may appear in the page text (see `forms(of:)`).
    private var forms: [[Form]?]
    private var starts: [Int?]
    /// The last leaf looked up: the next lookup is usually close by.
    private var cursor: Int?

    /// How far apart leaves may be in the page text (U+FFFC for images and controls in between).
    private static let maxGap = 512

    var count: Int { elements.count }

    init?(webArea: AXElement, text: String, measure: @escaping (AXElement) -> Int?) {
        let elements = ((try? webArea.attribute(.uiElementsForSearchPredicate, for: .staticText)) ?? []).compactMap(\.element)
        guard !elements.isEmpty else { return nil }
        self.text = text
        utf16 = Array(text.utf16)
        self.elements = elements
        self.measure = measure
        forms = Array(repeating: nil, count: elements.count)
        starts = Array(repeating: nil, count: elements.count)
    }

    func leaf(at index: Int) -> Leaf? {
        guard elements.indices.contains(index), let start = start(of: index) else { return nil }
        let form = form(of: index, at: start)
        return Leaf(
            index: index, element: elements[index], range: Selection(start..<start + (form?.text.count ?? 0)),
            valueOffset: form?.lead ?? 0)
    }

    /// The leaf holding the character at `offset`, or the first one after it (`offset` in a gap between leaves).
    func leaf(containing offset: Int) -> Leaf? {
        guard var index = cursor ?? seed(for: offset) else { return nil }
        if let start = start(of: index), abs(offset - start) > 20_000, let seeded = seed(for: offset) { index = seeded }
        while index > 0, let start = start(of: index), start > offset { index -= 1 }
        while index + 1 < count, let next = start(of: index + 1), next <= offset { index += 1 }
        if let start = start(of: index), offset >= start + length(of: index), index + 1 < count { index += 1 }
        cursor = index
        return leaf(at: index)
    }

    /// The leaves overlapping `selection`, each with the part of `selection` it holds.
    func leaves(in selection: Selection) -> [(leaf: Leaf, part: Selection)] {
        guard var leaf = leaf(containing: selection.lowerBound) else { return [] }
        var result: [(Leaf, Selection)] = []
        while leaf.range.lowerBound < selection.upperBound, result.count < 1000 {
            let lower = max(selection.lowerBound, leaf.range.lowerBound)
            let upper = min(selection.upperBound, leaf.range.upperBound)
            if lower < upper { result.append((leaf, Selection(lower..<upper))) }
            guard let next = self.leaf(at: leaf.index + 1) else { break }
            leaf = next
        }
        return result
    }

    /// The element of the last leaf looked up, to start from the same place in a new list after the page changed.
    var cursorElement: AXElement? { cursor.map { elements[$0] } }

    /// Starts the next lookup at `element` (a leaf near the reading position), saving a search.
    func moveCursor(to element: AXElement) {
        if let index = index(of: element), start(of: index) != nil { cursor = index }
    }

    func index(of element: AXElement) -> Int? {
        if let cursor, elements[cursor] == element { return cursor }
        return elements.firstIndex(of: element)
    }

    /// The first leaf (at least partly) inside `visible` (screen coordinates, top-left origin). Chromium reports leaves
    /// outside the viewport with zero height, clipped to its top or bottom edge, so this is a binary search.
    func firstVisible(in visible: CGRect) -> Leaf? {
        func frame(_ index: Int) -> CGRect? {
            try? elements[index].attribute(.frame)
        }
        func isAbove(_ index: Int) -> Bool {
            guard let frame = frame(index) else { return true }
            return frame.maxY <= visible.minY + 1 || (frame.height < 1 && frame.minY <= visible.minY + 1)
        }
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isAbove(middle) { low = middle + 1 } else { high = middle }
        }
        // Skip hidden leaves (zero height) right at the top.
        for index in low..<min(low + 20, count) {
            if let frame = frame(index), frame.height >= 1, visible.intersects(frame) {
                cursor = index
                return leaf(at: index)
            }
        }
        return nil
    }

    // MARK: Offsets

    /// A leaf's text as it may appear in the page text (UTF-16), and where that starts in its `AXValue`.
    private struct Form {
        let text: [UInt16]
        let lead: Int
    }

    /// The leaf's text, then (if different) without surrounding whitespace: Chromium's page text drops the space a line
    /// wraps at (a leaf " like " after a link at the end of a line reads "like " there).
    private func forms(of index: Int) -> [Form] {
        if let forms = forms[index] { return forms }
        let string = (try? elements[index].attribute(.value)) ?? ""
        var result = [Form(text: Array(string.utf16), lead: 0)]
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != string, let range = string.range(of: trimmed) {
            result.append(Form(text: Array(trimmed.utf16), lead: string[..<range.lowerBound].utf16.count))
        }
        forms[index] = result
        return result
    }

    /// The form of leaf `index` that appears in the page text at `offset`, if any (`exact`: only its full text).
    private func form(of index: Int, at offset: Int, exact: Bool = false) -> Form? {
        forms(of: index).prefix(exact ? 1 : 2).first { form in
            utf16.matches(form.text, at: offset)
        }
    }

    private func length(of index: Int) -> Int {
        guard let start = starts[index] else { return 0 }
        return form(of: index, at: start)?.text.count ?? 0
    }

    private func matches(_ index: Int, at offset: Int, exact: Bool = false) -> Bool {
        form(of: index, at: offset, exact: exact) != nil
    }

    /// Trimmed forms are short and common ("A", "("): only accept them this close to where the leaf is expected.
    private static let maxTrimmedDistance = 8

    private func start(of index: Int) -> Int? {
        if let start = starts[index] { return start }
        // Walk from the nearest leaf whose offset is known.
        let known = (1...300).lazy.flatMap { [index - $0, index + $0] }.first {
            self.elements.indices.contains($0) && self.starts[$0] != nil
        }
        guard let known else { return measuredStart(of: index) }
        if known < index {
            for next in known + 1...index where starts[next] == nil {
                let previous = starts[next - 1]! + length(of: next - 1)
                starts[next] = find(next, from: previous) ?? previous
            }
        } else {
            for next in (index..<known).reversed() where starts[next] == nil {
                let following = starts[next + 1]!
                starts[next] = findBackward(next, before: following) ?? following
            }
        }
        return starts[index]
    }

    /// The offset of leaf `index` measured through text markers, checked against its text.
    private func measuredStart(of index: Int) -> Int? {
        guard let measured = measure(elements[index]) else { return nil }
        if matches(index, at: measured) {
            starts[index] = measured
        } else {
            // Markers at node boundaries can be off by a character or so (and Chromium measures its first leaf as
            // the whole page).
            let near = (1...64).lazy.flatMap { [measured - $0, measured + $0] }.first { self.matches(index, at: $0) }
            guard let found = near else { return nil }
            starts[index] = found
        }
        return starts[index]
    }

    /// Picks a leaf near `offset` by binary search on measured offsets (each costs time proportional to the offset).
    private func seed(for offset: Int) -> Int? {
        var low = 0
        var high = count - 1
        var best: Int?
        for _ in 0..<40 where low <= high {
            let middle = (low + high) / 2
            guard let start = starts[middle] ?? measuredStart(of: middle) else {
                // Not in the page text (hidden?): try its neighbor.
                if middle + 1 <= high { low = middle + 1 } else { high = middle - 1 }
                continue
            }
            if start <= offset {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
            if abs(start - offset) < 2000 { return middle }
        }
        return best ?? (starts.firstIndex { $0 != nil })
    }

    private func find(_ index: Int, from offset: Int) -> Int? {
        let forms = forms(of: index)
        guard !forms[0].text.isEmpty else { return offset }
        let firsts = Set(forms.map { $0.text[0] })
        let last = min(offset + Self.maxGap, utf16.count - 1)
        guard offset <= last else { return nil }
        for start in offset...last where firsts.contains(utf16[start]) {
            if matches(index, at: start, exact: start - offset > Self.maxTrimmedDistance) { return start }
        }
        return nil
    }

    private func findBackward(_ index: Int, before offset: Int) -> Int? {
        let forms = forms(of: index)
        guard !forms[0].text.isEmpty else { return offset }
        let first = max(0, offset - forms[0].text.count - Self.maxGap)
        let last = offset - 1
        guard first <= last else { return nil }
        for start in (first...last).reversed() {
            if let form = form(of: index, at: start, exact: offset - start - forms[0].text.count > Self.maxTrimmedDistance),
                start + form.text.count <= offset
            {
                return start
            }
        }
        return nil
    }
}
