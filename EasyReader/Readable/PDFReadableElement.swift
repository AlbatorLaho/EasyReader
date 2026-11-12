//
//  PDFReadableElement.swift
//  EasyReader
//

import Cocoa

/// A PDF shown by PDFKit's `PDFView` (Preview and other apps): an `AXGroup`/`AXSharedDocumentContainer` (the focused
/// element) holding an `AXPage` per page, whose `AXGroup`s lead down to `AXStaticText` leaves.
///
/// - Text: the leaves in page order, without page headers and footers (`leaves(ofPage:)`). Line breaks inside a leaf
///   become spaces, words hyphenated at a line end word joiners (same UTF-16 length, so offsets map straight back to
///   the leaf). Leaves are grouped into text blocks (`textBlock(containing:)`, joined by line breaks), so units stay in
///   a block (`layout()`):
///   - A leaf ending mid-sentence continues in the next one in about the same font (next line, column or page; see
///     `join(_:_:isWord:)`). Leaves in a smaller font in between (footnotes, captions) are put after the block.
///   - Tagged PDFs split paragraphs at inline spans (footnote marks, styled runs), each a leaf that can't be selected.
///     Such leaves under the same parent group (the nearest ancestor with several children) form one block too.
///
///   Units in selectable leaves (untagged PDFs: a paragraph, column, line or text run; also headings of tagged PDFs) are
///   selected; one spanning leaves piece by piece as it's read. Tagged PDFs' other leaves can't be selected themselves,
///   but their page's selectable leaves (`PageSelector`) select by offset in the whole page's text. Units on a page
///   with neither are highlighted by a `HighlightOverlay`.
///
///   All pages are listed at once, but fetching all their text takes long (795 pages, 6000 leaves: 25 s), so only a
///   window of pages is loaded: around where reading starts, then extended as reading nears either end of it.
/// - Selection: set on the leaf (`AXSelectedTextRange`, exact; tagged PDFs: on the page's `PageSelector`). PDFKit ignores it on pages that aren't on screen, so the
///   leaf is scrolled into view first. The user's selection: its text is the container's `AXSelectedText` (without
///   trailing whitespace), its start the `AXSelectedTextRange` of the leaf holding it (other leaves report `NSNotFound`;
///   the reported length is unreliable). PDFKit's AX doesn't see selections made with `PDFView.setCurrentSelection`.
/// - Scrolling: the scroll area's scroll bar (`ScrollBarScroller`); the container's frame is document-sized.
final class PDFReadableElement: ReadableElement {
    /// A leaf as laid out in `text`.
    private struct Leaf {
        let element: AXElement
        let page: Int
        /// Index in `pageLeaves[page]` (identifies the leaf when the text is laid out again).
        let index: Int
        /// Offset of the leaf's text in `text`.
        var offset: Int
        let length: Int
        /// Offsets (in the leaf) of the line breaks that became spaces.
        let lineBreaks: [Int]
        let isSettable: Bool
        /// Whether a text block starts here (else the leaf continues the previous one, after a space).
        let startsBlock: Bool

        var end: Int { offset + length }
    }

    /// A leaf as read from its page (page headers/footers and blank leaves left out).
    private struct PageLeaf {
        let element: AXElement
        /// The flattened text (line breaks → spaces, hyphenation → word joiners), as UTF-16.
        let units: [UInt16]
        let lineBreaks: [Int]
        let isSettable: Bool
        /// The nearest ancestor with several children (a leaf's paragraph in tagged PDFs).
        let group: AXElement?
        let info: LeafInfo
    }

    /// What decides whether a leaf continues the previous one's text.
    struct LeafInfo {
        var text: String
        var fontSize: CGFloat?
        var isHeading = false
        var isSingleLine: Bool { !text.contains("\n") }
    }

    /// How a leaf's text continues from the previous leaf's.
    enum Join: Equatable {
        /// A new text block.
        case none
        case space
        /// A word hyphenated at the end of the previous leaf: word joiners in place of the separator and the hyphen
        /// (unless `keepsHyphen`: not a word without it, e.g. "self-aware").
        case hyphen(keepsHyphen: Bool)
    }

    /// A unit's part in one leaf: what the overlay highlights (by leaf, as loading earlier pages shifts offsets).
    private struct Part {
        /// Index in `leaves` (valid until the text is laid out again).
        let leaf: Int
        let element: AXElement
        let lineBreaks: [Int]
        let range: CFRange
    }

    /// Every text leaf of a page in reading order (also the blank ones, headers, footers and footnotes left out of the
    /// text): how a `PageSelector` finds where leaves start in the page's text.
    private struct PageText {
        let element: AXElement
        let value: String
        let isSettable: Bool
    }

    /// Tagged PDFs: a selectable leaf of a page (PDFKit's text nodes: headings, list labels, some empty ones) whose
    /// selected range isn't clamped to the leaf but goes on through the page's text (clamped to the page), and where
    /// the page's leaves after it start, relative to it (measured by selecting to the page's end once).
    private struct PageSelector {
        let element: AXElement
        let starts: [AXElement: Int]
        /// The page's text from the selector's start.
        let text: NSString
    }

    /// What one selection set selects: `range` in `element`'s selected text range, which should select `expected`.
    private struct Target {
        let element: AXElement
        let range: CFRange
        let expected: String
    }

    /// A piece of a unit selected at once: its parts (consecutive, on one page, all selectable by one `Target`).
    private struct Piece {
        /// Where it starts in the unit.
        let start: Int
        let parts: [Part]
        /// Its range in `text`.
        let range: Selection
    }

    nonisolated static let wordJoiner: UInt16 = 0x2060

    private lazy var pages: [AXElement] = (try? handle.attribute(.children)) ?? []
    private let scroller: ScrollBarScroller?
    /// Pages whose leaves are in `leaves` and `text`; nil until reading starts.
    private var loadedPages: Range<Int>?
    private var pageLeaves: [Int: [PageLeaf]] = [:]
    private var pageTexts: [Int: [PageText]] = [:]
    /// Measured page selectors (nil: the page has none that works); kept as long as the element.
    private var pageSelectors: [Int: PageSelector?] = [:]
    private var leaves: [Leaf] = []
    private var text = ""
    private var textLength = 0
    /// The selection EasyReader set or last took from the user (PDFKit can't select every leaf).
    private var tracked: Selection?
    /// The container's selected text when the user's selection was taken, and right after the last selection set: while
    /// it reports one of these (or the tracked unit's text), the user hasn't selected anything new.
    private var consumedReport: String?
    private var reportAfterSet: String?
    /// The pieces of a unit selected piece by piece as it's read, and the one selected.
    private var pieces: [Piece] = []
    private var selectedPiece = 0
    /// Footnote marks found in each leaf (fetched when a unit in it is first read).
    private var markerCache: [AXElement: [NSRange]] = [:]
    private lazy var overlay = HighlightOverlay()
    /// Whether the overlay is showing (the tracked unit can't be selected).
    private(set) var isHighlighting = false

    required init(_ element: AXElement) {
        scroller = (try? element.parent(with: .scrollArea)).map(ScrollBarScroller.init)
        super.init(element)
    }

    override var fullText: String? {
        prepare()
        extendAroundTracked()
        return text
    }

    /// The tracked unit's text, with footnote marks (`markers(of:)`) replaced by word joiners so they aren't read.
    override var selectedText: String? {
        prepare()
        guard let tracked else { return nil }
        var units = Array(string(in: tracked).utf16)
        for part in parts(of: tracked) {
            let leaf = leaves[part.leaf]
            let partRange = part.range.location..<part.range.location + part.range.length
            for marker in markers(of: leaf) {
                let marker = marker.location..<marker.location + marker.length
                for index in marker.clamped(to: partRange) {
                    let unit = leaf.offset + index - tracked.lowerBound
                    if units.indices.contains(unit) { units[unit] = Self.wordJoiner }
                }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    override var selection: Selection? {
        get {
            if loadedPages == nil {
                prepare()
            } else if let report = newUserSelection() {
                consumedReport = report
                if let user = locate(report) {
                    Log.accessibility.debug("pdf: user selected \(user)")
                    tracked = user
                    highlight(nil)
                }
            }
            return tracked
        }
        set {
            guard let newValue else { return }
            prepare()
            tracked = newValue
            apply(newValue)
        }
    }

    override func textBlock(containing offset: Int) -> Selection? {
        guard var first = leafIndex(containing: offset) else { return nil }
        while first > 0, !leaves[first].startsBlock { first -= 1 }
        var last = first
        while last + 1 < leaves.count, !leaves[last + 1].startsBlock { last += 1 }
        // The line break after a block belongs to it, so a unit ending at the block's end finds the next one from there.
        return Selection(leaves[first].offset..<min(leaves[last].end + 1, textLength))
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let leaf = leaf(containing: selection.lowerBound) else { return }
        // Characters on pages off screen have no bounds.
        if !isOnScreen(leaf) { try? leaf.element.perform(.scrollToVisible) }
        guard let scroller,
            let bounds = parts(of: selection).lazy.compactMap({ Self.lineRects(of: $0).first }).first,
            let contentFrame = try? handle.attribute(.frame)
        else {
            Log.scroll.debug("pdf: scroll to \(selection): no bounds or scroll area, scrolling the leaf into view")
            try? leaf.element.perform(.scrollToVisible)
            return
        }
        scroller.scroll(to: bounds, contentFrame: contentFrame, options: options)
    }

    override func endReading() {
        highlight(nil)
    }

    // MARK: Window of pages

    /// Loads the page where reading starts and takes the user's selection, or else the top of the visible part.
    private func prepare() {
        guard loadedPages == nil else { return }
        let report = try? handle.attribute(.selectedText)
        consumedReport = report
        if let report, !report.isEmpty, let user = locate(report) {
            Log.accessibility.debug("pdf: starting at user selection \(user)")
            tracked = user
            return
        }
        let page = visiblePages().first ?? 0
        load(page: page)
        tracked = visibleTop(page: page) ?? Selection(0..<0)
        Log.accessibility.debug("pdf: starting at visible top \(String(describing: tracked)) of page \(page)")
    }

    /// Keeps the pages next to the tracked unit's loaded (text running on from one page to the next is joined), and
    /// further ones while nothing readable follows (or precedes) it.
    private func extendAroundTracked() {
        guard let loaded = loadedPages else { return }
        let page = tracked.flatMap { leaf(containing: $0.lowerBound)?.page } ?? loaded.lowerBound
        setWindow(min(loaded.lowerBound, max(page - 1, 0))..<max(loaded.upperBound, min(page + 2, pages.count)))
        for _ in 0..<20 {
            guard let loaded = loadedPages, loaded.upperBound < pages.count, let tracked,
                !hasText(in: min(tracked.upperBound, textLength)..<textLength)
            else { break }
            setWindow(loaded.lowerBound..<loaded.upperBound + 1)
        }
        for _ in 0..<20 {
            guard let loaded = loadedPages, loaded.lowerBound > 0, let tracked,
                !hasText(in: 0..<min(tracked.lowerBound, textLength))
            else { break }
            setWindow(loaded.lowerBound - 1..<loaded.upperBound)
        }
    }

    private func hasText(in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return utf16[start..<end].contains { !Self.isBlank($0) }
    }

    private nonisolated static func isBlank(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0xFFFC || unit == 0xA0 || unit == wordJoiner
    }

    /// Makes `page` loaded: extends the window when it's near, else starts a new window there (offsets start over).
    private func ensureLoaded(page: Int) {
        if let loaded = loadedPages, loaded.lowerBound - 3 <= page, page < loaded.upperBound + 3 {
            setWindow(min(loaded.lowerBound, page)..<max(loaded.upperBound, page + 1))
        } else {
            load(page: page)
        }
    }

    private func load(page: Int) {
        pageLeaves = [:]
        loadedPages = nil
        tracked = nil
        highlight(nil)
        setWindow(page..<page + 1)
    }

    /// Loads `window`'s pages and lays out the text again; the tracked selection stays on the same text.
    private func setWindow(_ window: Range<Int>) {
        guard window != loadedPages else { return }
        let anchors = tracked.map { (anchor(at: $0.lowerBound), anchor(at: $0.upperBound)) }
        for page in window where pageLeaves[page] == nil {
            (pageLeaves[page], pageTexts[page]) = leaves(ofPage: page)
        }
        pageLeaves = pageLeaves.filter { window.contains($0.key) }
        pageTexts = pageTexts.filter { window.contains($0.key) }
        loadedPages = window
        layout()
        if let (lower, upper) = anchors, let lower = lower.flatMap(offset(of:)) {
            tracked = Selection(lower..<max(lower, upper.flatMap(offset(of:)) ?? lower))
        }
    }

    /// Where `offset` is, by leaf (page and index in it) and offset in the leaf.
    private func anchor(at offset: Int) -> (page: Int, index: Int, delta: Int)? {
        guard let leaf = leaf(containing: offset) else { return nil }
        return (leaf.page, leaf.index, min(offset - leaf.offset, leaf.length))
    }

    private func offset(of anchor: (page: Int, index: Int, delta: Int)) -> Int? {
        leaves.first { $0.page == anchor.page && $0.index == anchor.index }.map { $0.offset + anchor.delta }
    }

    // MARK: Text

    /// Lays out the loaded pages' leaves as `text`: blocks joined by line breaks, leaves within a block by spaces (see
    /// `join(_:_:isWord:)`). While a sentence runs on, leaves in a smaller font (footnotes, captions) are put after the
    /// block, so it continues in the next column or page.
    private func layout() {
        var units: [UInt16] = []
        var laidOut: [Leaf] = []
        var previous: PageLeaf?
        var previousPage = 0
        var deferred: [(page: Int, index: Int)] = []

        func emit(page: Int, index: Int) {
            let leaf = pageLeaves[page]![index]
            var join = Join.none
            if let previous {
                join = Self.join(previous.info, leaf.info, isWord: Self.isWord)
                if join == .none, !previous.isSettable, !leaf.isSettable, leaf.group != nil, leaf.group == previous.group {
                    join = .space
                }
            }
            if !units.isEmpty {
                switch join {
                    case .none: units.append(0x0A)
                    case .space:
                        // No space before closing punctuation ("Wheel" "." → "Wheel⁠.").
                        let startsWithPunctuation = leaf.units.first.flatMap(Unicode.Scalar.init).map {
                            CharacterSet(charactersIn: ".,;:!?)]}”’").contains($0)
                        }
                        units.append(startsWithPunctuation == true ? Self.wordJoiner : 0x20)
                    case .hyphen(let keepsHyphen):
                        var end = units.count - 1
                        while end >= 0, Self.isBlank(units[end]) {
                            units[end] = Self.wordJoiner
                            end -= 1
                        }
                        if !keepsHyphen, end >= 0, units[end] == 0x2D { units[end] = Self.wordJoiner }
                        units.append(Self.wordJoiner)
                }
            }
            laidOut.append(
                Leaf(
                    element: leaf.element, page: page, index: index, offset: units.count, length: leaf.units.count,
                    lineBreaks: leaf.lineBreaks, isSettable: leaf.isSettable, startsBlock: units.isEmpty || join == .none))
            units += leaf.units
            previous = leaf
            previousPage = page
        }
        func flush() {
            for (page, index) in deferred { emit(page: page, index: index) }
            deferred = []
        }

        for page in loadedPages ?? 0..<0 {
            for (index, leaf) in (pageLeaves[page] ?? []).enumerated() {
                // Deferring stops at the page after the open sentence's.
                if let previous, Self.runsOn(previous.info), page <= previousPage + 1 {
                    if Self.isSmaller(leaf.info.fontSize, than: previous.info.fontSize) {
                        deferred.append((page, index))
                        continue
                    }
                    if Self.join(previous.info, leaf.info, isWord: Self.isWord) == .none { flush() }
                } else {
                    flush()
                }
                emit(page: page, index: index)
                if !Self.runsOn(leaf.info) { flush() }
            }
        }
        flush()
        leaves = laidOut
        textLength = units.count
        text = String(decoding: units, as: UTF16.self)
    }

    /// The page's leaves, depth first, without page headers and footers (a single short line in the top or bottom
    /// margin: running titles, page numbers).
    private func leaves(ofPage page: Int) -> ([PageLeaf], [PageText]) {
        guard pages.indices.contains(page) else { return ([], []) }
        let pageFrame = try? pages[page].attribute(.frame)
        var leaves: [PageLeaf] = []
        var texts: [PageText] = []
        // Each element with the nearest ancestor that has several children, and whether its parent is a heading.
        var stack: [(AXElement, AXElement?, Bool)] = [(pages[page], nil, false)]
        while let (element, group, inHeading) = stack.popLast() {
            let role = try? element.role()
            guard role == .staticText else {
                let children = (try? element.attribute(.children)) ?? []
                let childGroup = children.count > 1 ? element : group
                stack += children.reversed().map { ($0, childGroup, role == .heading) }
                continue
            }
            let value: String = (try? element.attribute(.value)) ?? ""
            let isSettable = element.isSettable(.selectedTextRange)
            texts.append(PageText(element: element, value: value, isSettable: isSettable))
            let (flat, lineBreaks) = Self.flattened(value)
            guard flat.utf16.contains(where: { !Self.isBlank($0) }) else { continue }
            if lineBreaks.isEmpty, flat.count <= 80, let pageFrame, let frame = try? element.attribute(.frame),
                Self.isInMargin(frame, of: pageFrame)
            {
                Log.accessibility.debug("pdf: page \(page): skipping header/footer \(flat)")
                continue
            }
            var units = Array(flat.utf16)
            Self.dehyphenate(&units, lineBreaks: lineBreaks, isWord: Self.isWord)
            leaves.append(
                PageLeaf(
                    element: element, units: units, lineBreaks: lineBreaks,
                    isSettable: isSettable, group: group,
                    info: LeafInfo(text: value, fontSize: Self.fontSize(of: element, length: units.count), isHeading: inHeading)))
        }
        let footnotes = Self.footnoteStart(leaves.map { ($0.info.fontSize, $0.units.count) }) { index in
            guard let pageFrame, let frame = try? leaves[index].element.attribute(.frame), !frame.isEmpty, frame.minY.isFinite
            else { return nil }
            return frame.minY > pageFrame.midY
        }
        if footnotes < leaves.count {
            Log.accessibility.debug("pdf: page \(page): skipping \(leaves.count - footnotes) footnote leaves")
            leaves.removeSubrange(footnotes...)
        }
        return (leaves, texts)
    }

    /// Where the page's footnotes start: the leaves at the end of the page (reading order) in a font clearly smaller
    /// than the page's body text (the size most of its characters have), not in the upper half of the page (`isLow`;
    /// nil when unknown). `leaves.count` if there are none.
    nonisolated static func footnoteStart(_ leaves: [(fontSize: CGFloat?, length: Int)], isLow: (Int) -> Bool?) -> Int {
        guard let body = dominantSize(leaves) else { return leaves.count }
        var start = leaves.count
        while start > 0, isSmaller(leaves[start - 1].fontSize, than: body), isLow(start - 1) != false { start -= 1 }
        return start
    }

    /// The font size most characters have.
    nonisolated static func dominantSize(_ runs: [(fontSize: CGFloat?, length: Int)]) -> CGFloat? {
        var lengths: [Int: (size: CGFloat, length: Int)] = [:]
        for run in runs {
            guard let size = run.fontSize else { continue }
            let key = Int((size * 10).rounded())
            lengths[key] = (size, (lengths[key]?.length ?? 0) + run.length)
        }
        return lengths.values.max { $0.length < $1.length }?.size
    }

    /// The footnote marks in `leaf` (in-leaf ranges): short superscript runs. Only selectable leaves have font
    /// information (in tagged PDFs, marks are leaves of their own).
    private func markers(of leaf: Leaf) -> [NSRange] {
        if let cached = markerCache[leaf.element] { return cached }
        var runs: [(range: NSRange, fontSize: CGFloat?)] = []
        if leaf.isSettable,
            let string = try? leaf.element.attribute(.attributedStringForRange, for: CFRange(location: 0, length: leaf.length))?
                .string
        {
            string.enumerateAttribute(NSAttributedString.Key("AXFont"), in: NSRange(location: 0, length: string.length)) {
                font, range, _ in
                runs.append((range, (font as? [String: Any]).flatMap(Self.fontSize(in:))))
            }
        }
        let markers = runs.isEmpty ? [] : Self.markerRanges(runs, in: string(in: Selection(leaf.offset..<leaf.end)))
        if markerCache.count > 2000 { markerCache = [:] }
        markerCache[leaf.element] = markers
        return markers
    }

    /// Footnote marks among a leaf's font runs: 1–3 letters, digits or `*†‡§¶` in a font under 75% of the leaf's body
    /// text size (superscripts), without the whitespace around them.
    nonisolated static func markerRanges(_ runs: [(range: NSRange, fontSize: CGFloat?)], in text: String) -> [NSRange] {
        guard let body = dominantSize(runs.map { ($0.fontSize, $0.range.length) }) else { return [] }
        let text = text as NSString
        let markChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*†‡§¶"))
        return runs.compactMap { run in
            guard let size = run.fontSize, size < body * 0.75, NSMaxRange(run.range) <= text.length else { return nil }
            let mark = text.substring(with: run.range)
            let trimmed = mark.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...3).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy(markChars.contains) else { return nil }
            let inner = (mark as NSString).range(of: trimmed)
            return NSRange(location: run.range.location + inner.location, length: inner.length)
        }
    }

    /// Whether `frame` (of a leaf) lies in the top or bottom 8% of the page.
    nonisolated static func isInMargin(_ frame: CGRect, of pageFrame: CGRect) -> Bool {
        guard !frame.isEmpty, frame.minY.isFinite, !pageFrame.isEmpty else { return false }
        let margin = pageFrame.height * 0.08
        return frame.maxY <= pageFrame.minY + margin || frame.minY >= pageFrame.maxY - margin
    }

    /// The leaf's font size: the larger of its middle and first characters' (one may be a superscript).
    private static func fontSize(of element: AXElement, length: Int) -> CGFloat? {
        [length / 2, 0].compactMap { index -> CGFloat? in
            guard let string = try? element.attribute(.attributedStringForRange, for: CFRange(location: index, length: 1))?.string,
                string.length > 0,
                let font = string.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any]
            else { return nil }
            return fontSize(in: font)
        }.max()
    }

    /// The size in an `AXFont` attribute; PDFKit vends it as a string ("10.296").
    nonisolated static func fontSize(in font: [String: Any]) -> CGFloat? {
        switch font["AXFontSize"] {
            case let size as NSNumber: return CGFloat(size.doubleValue)
            case let size as String: return Double(size).map { CGFloat($0) }
            default: return nil
        }
    }

    private static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    /// `value` with its line breaks replaced by spaces (each is one UTF-16 unit, so offsets don't change), and their
    /// offsets.
    nonisolated static func flattened(_ value: String) -> (String, [Int]) {
        var units = Array(value.utf16)
        var lineBreaks: [Int] = []
        for index in units.indices where [0x0A, 0x0D, 0x0C, 0x2028, 0x2029].contains(units[index]) {
            units[index] = 0x20
            lineBreaks.append(index)
        }
        guard !lineBreaks.isEmpty else { return (value, []) }
        return (String(decoding: units, as: UTF16.self), lineBreaks)
    }

    /// Joins words hyphenated at a line break (letter, hyphen, break, lowercase letter): the break and the hyphen become
    /// word joiners (read as one word, same length), or only the break when the word isn't one without its hyphen.
    nonisolated static func dehyphenate(_ units: inout [UInt16], lineBreaks: [Int], isWord: (String) -> Bool) {
        for lineBreak in lineBreaks where lineBreak >= 2 && lineBreak + 1 < units.count {
            guard units[lineBreak - 1] == 0x2D, isLetter(units[lineBreak - 2]), isLowercase(units[lineBreak + 1]) else {
                continue
            }
            var start = lineBreak - 2
            while start > 0, isLetter(units[start - 1]) { start -= 1 }
            var end = lineBreak + 1
            while end < units.count, isLetter(units[end]) { end += 1 }
            let word = String(decoding: units[start..<lineBreak - 1] + units[lineBreak + 1..<end], as: UTF16.self)
            units[lineBreak] = wordJoiner
            if isWord(word) { units[lineBreak - 1] = wordJoiner }
        }
    }

    /// Whether `next` continues `previous`'s text (in the next line, column or page) and how.
    ///
    /// It does when `previous` ends mid-sentence (no closing `.`, `!`, `?`, `…` or `:`) and `next` is in about the same
    /// font, unless `previous` looks like a heading: in an `AXHeading`, or one line in title case followed by a capital.
    nonisolated static func join(_ previous: LeafInfo, _ next: LeafInfo, isWord: (String) -> Bool) -> Join {
        guard !previous.isHeading, endsMidSentence(previous.text),
            !isSmaller(next.fontSize, than: previous.fontSize), !isSmaller(previous.fontSize, than: next.fontSize),
            let first = next.text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .none }
        if previous.isSingleLine, isTitleCase(previous.text), CharacterSet.uppercaseLetters.contains(first) { return .none }
        let end = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if end.hasSuffix("-"), CharacterSet.lowercaseLetters.contains(first) {
            let before = end.dropLast().reversed().prefix { $0.isLetter }
            let after = next.text.drop { $0.isWhitespace }.prefix { $0.isLetter }
            if !before.isEmpty { return .hyphen(keepsHyphen: !isWord(String(before.reversed()) + after)) }
        }
        return .space
    }

    /// Whether a sentence is open at the end of `leaf`, so smaller text after it is put after the sentence's block: it
    /// ends mid-sentence and isn't a heading (in an `AXHeading`, or one line in title case).
    nonisolated static func runsOn(_ leaf: LeafInfo) -> Bool {
        !leaf.isHeading && endsMidSentence(leaf.text) && !(leaf.isSingleLine && isTitleCase(leaf.text))
    }

    nonisolated static func endsMidSentence(_ text: String) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'”’»)]}").union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "\u{2060}"))
        guard let last = text.unicodeScalars.last(where: { !closing.contains($0) }) else { return false }
        return !".!?…:".unicodeScalars.contains(last)
    }

    /// One line whose longer words (4+ letters) all start with a capital: "PRESENT CODE — ACTIVITY", "Quality of Life".
    nonisolated static func isTitleCase(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }.filter { $0.count >= 4 }
        return !words.isEmpty && words.allSatisfy { $0.first?.isUppercase == true }
    }

    /// Whether `size` is clearly smaller than `other` (both known).
    nonisolated static func isSmaller(_ size: CGFloat?, than other: CGFloat?) -> Bool {
        guard let size, let other else { return false }
        return size < other * 0.9
    }

    private nonisolated static func isLetter(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.letters.contains($0) } ?? false
    }

    private nonisolated static func isLowercase(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.lowercaseLetters.contains($0) } ?? false
    }

    /// Text compared with PDFKit's reports, which keep line breaks and hyphens and drop trailing whitespace.
    nonisolated static func comparable(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.filter { !ignoredInComparison.contains($0) }))
    }

    private nonisolated static let ignoredInComparison = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-\u{2060}\u{AD}"))

    /// Where `report` ends in `text` if it starts at `start`, compared as by `comparable` (our joins differ from PDFKit's).
    nonisolated static func end(of report: String, in text: String, from start: Int) -> Int {
        var remaining = comparable(report).unicodeScalars.count
        let utf16 = text.utf16
        guard remaining > 0, let index = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
            let scalars = index.samePosition(in: text.unicodeScalars)
        else { return min(start, utf16.count) }
        var end = start
        for scalar in text.unicodeScalars[scalars...] {
            guard remaining > 0 else { break }
            end += UTF16.width(scalar)
            if !ignoredInComparison.contains(scalar) { remaining -= 1 }
        }
        return end
    }

    private func string(in selection: Selection) -> String {
        guard let range = Range(selection, in: text) else { return "" }
        return String(text[range])
    }

    // MARK: Leaves

    /// The leaf holding UTF-16 `offset` of `text`, or the separator after it.
    private func leafIndex(containing offset: Int) -> Int? {
        guard offset >= 0, offset <= textLength else { return nil }
        // Last leaf starting at or before `offset`.
        var low = 0
        var high = leaves.count
        while low < high {
            let mid = (low + high) / 2
            if leaves[mid].offset <= offset { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    private func leaf(containing offset: Int) -> Leaf? {
        leafIndex(containing: offset).map { leaves[$0] }
    }

    /// `selection`'s non-empty parts in the leaves it covers (or its empty start).
    private func parts(of selection: Selection) -> [Part] {
        guard let first = leafIndex(containing: selection.lowerBound) else { return [] }
        var parts: [Part] = []
        for (index, leaf) in leaves.enumerated().dropFirst(first) {
            guard leaf.offset < selection.upperBound || parts.isEmpty else { break }
            let lower = min(max(selection.lowerBound, leaf.offset), leaf.end)
            let upper = min(max(selection.upperBound, lower), leaf.end)
            guard upper > lower || parts.isEmpty else { continue }
            parts.append(
                Part(leaf: index, element: leaf.element, lineBreaks: leaf.lineBreaks, range: CFRange(location: lower - leaf.offset, length: upper - lower)))
        }
        // A part made only of the start (the unit begins at the separator before the next leaf) isn't worth keeping.
        if parts.count > 1, parts[0].range.length == 0 { parts.removeFirst() }
        return parts
    }

    /// Indices of the pages on screen, in order. PDFKit fails `AXVisibleChildren` until its page elements exist (the
    /// first `AXChildren` makes them), so `pages` comes first; page frames are the fallback.
    private func visiblePages() -> [Int] {
        let pages = pages
        if let visible = try? handle.attribute(.visibleChildren), !visible.isEmpty {
            return visible.compactMap { pages.firstIndex(of: $0) }
        }
        guard let scrollFrame = scroller?.frame else { return [] }
        return pages.indices.filter { index in
            (try? pages[index].attribute(.frame)).map { $0.intersects(scrollFrame) } ?? false
        }
    }

    private func isOnScreen(_ leaf: Leaf) -> Bool {
        visiblePages().contains(leaf.page)
    }

    /// The first character on screen on `page` (loaded), as an empty selection.
    private func visibleTop(page: Int) -> Selection? {
        guard let scrollFrame = scroller?.frame else { return nil }
        for leaf in leaves where leaf.page == page {
            guard let frame = try? leaf.element.attribute(.frame), !frame.isEmpty, frame.maxY > scrollFrame.minY else { continue }
            guard frame.minY < scrollFrame.minY,
                let range = try? leaf.element.attribute(.rangeForPosition, for: CGPoint(x: frame.minX + 2, y: scrollFrame.minY + 2)),
                range.location != kCFNotFound, range.location <= leaf.length
            else { return Selection(leaf.offset..<leaf.offset) }
            return Selection(leaf.offset + range.location..<leaf.offset + range.location)
        }
        return nil
    }

    // MARK: Selection

    /// The container's selected text, if it's a selection the user made since the last one taken or set.
    private func newUserSelection() -> String? {
        guard let report = try? handle.attribute(.selectedText), !report.isEmpty,
            report != consumedReport, report != reportAfterSet, !isTrackedText(report)
        else { return nil }
        return report
    }

    private func isTrackedText(_ report: String) -> Bool {
        guard let tracked else { return false }
        return Self.comparable(report) == Self.comparable(string(in: tracked))
    }

    /// Where the user's selection (its text `report`) is: in the leaf on a visible page that reports a selected range
    /// (also leaves that can't be selected through AX), else where its text first occurs on the visible pages.
    private func locate(_ report: String) -> Selection? {
        let visible = visiblePages()
        for page in visible {
            ensureLoaded(page: page)
            for leaf in leaves where leaf.page == page {
                guard let range = try? leaf.element.attribute(.selectedTextRange),
                    range.location != kCFNotFound, range.location <= leaf.length
                else { continue }
                let start = leaf.offset + range.location
                return Selection(start..<Self.end(of: report, in: text, from: start))
            }
        }
        // Our text differs where lines and leaves are joined: search for the report's first line.
        let firstLine = report.prefix { !$0.isNewline && $0 != "-" }
        let needle = firstLine.isEmpty ? report : String(firstLine)
        guard let first = visible.first, let last = visible.last else { return nil }
        let pageLeaves = leaves.filter { (first...last).contains($0.page) }
        guard let lower = pageLeaves.first?.offset, let upper = pageLeaves.last?.end else { return nil }
        let found = (text as NSString).range(of: needle, options: .literal, range: NSRange(location: lower, length: upper - lower))
        guard found.location != NSNotFound else {
            Log.accessibility.debug("pdf: user selection not found on visible pages \(visible)")
            return nil
        }
        return Selection(found.location..<Self.end(of: report, in: text, from: found.location))
    }

    /// Selects `selection`. A unit spanning several leaves is selected piece by piece as it's read (`didReach(_:)`),
    /// starting with the first: PDFKit selects within one leaf, or through a `PageSelector` within one page. Highlights
    /// it instead when that isn't possible or the selection doesn't take.
    private func apply(_ selection: Selection) {
        pieces = []
        let parts = parts(of: selection).filter { part in
            part.range.length == 0
                || hasText(in: leaves[part.leaf].offset + part.range.location..<leaves[part.leaf].offset + part.range.location + part.range.length)
        }
        guard !parts.isEmpty, let pieces = pieces(of: parts, in: selection) else {
            highlight(selection.isEmpty ? nil : selection)
            return
        }
        selectedPiece = 0
        if select(pieces[0]) {
            self.pieces = pieces.count > 1 ? pieces : []
            highlight(nil)
        } else {
            highlight(selection.isEmpty ? nil : selection)
        }
    }

    /// `parts` grouped into pieces that can each be selected at once: a selectable leaf's part alone, consecutive parts
    /// in leaves that can't be selected on the same page together (selected through the page's `PageSelector`). nil if
    /// some part is on a page without a selectable leaf.
    private func pieces(of parts: [Part], in selection: Selection) -> [Piece]? {
        var pieces: [Piece] = []
        for part in parts {
            let leaf = leaves[part.leaf]
            let start = leaf.offset + part.range.location
            let range = Selection(start..<start + part.range.length)
            if !leaf.isSettable {
                guard pageTexts[leaf.page]?.contains(where: \.isSettable) == true else { return nil }
                if let last = pieces.last, let lastLeaf = last.parts.last.map({ leaves[$0.leaf] }), !lastLeaf.isSettable,
                    lastLeaf.page == leaf.page
                {
                    pieces[pieces.count - 1] = Piece(
                        start: last.start, parts: last.parts + [part], range: Selection(last.range.lowerBound..<range.upperBound))
                    continue
                }
            }
            pieces.append(Piece(start: start - selection.lowerBound, parts: [part], range: range))
        }
        return pieces
    }

    override func didReach(_ offset: Int) -> Selection? {
        guard let index = pieces.lastIndex(where: { $0.start <= offset }), index != selectedPiece else { return nil }
        selectedPiece = index
        let piece = pieces[index]
        Log.accessibility.debug("pdf: reading reached piece \(index) \(piece.range)")
        guard select(piece) else {
            highlight(tracked)
            pieces = []
            return nil
        }
        return piece.range
    }

    /// Selects `piece` (scrolling it into view if needed) and checks it selected the piece's text.
    private func select(_ piece: Piece) -> Bool {
        let leaf = leaves[piece.parts[0].leaf]
        if !isOnScreen(leaf) { try? leaf.element.perform(.scrollToVisible) }
        guard let target = target(of: piece) else {
            Log.accessibility.debug("pdf: no way to select \(piece.range), highlighting")
            return false
        }
        do {
            try target.element.set(.selectedTextRange, to: target.range)
        } catch {
            Log.accessibility.debug("pdf: setting selection failed (\(error)), highlighting instead")
            return false
        }
        let report = try? handle.attribute(.selectedText)
        reportAfterSet = report
        let selected = Self.comparable(report ?? "")
        guard piece.range.isEmpty || selected == Self.comparable(target.expected) else {
            Log.accessibility.debug("pdf: selected \(selected.utf16.count) chars instead of \(piece.range.count), highlighting")
            return false
        }
        return true
    }

    /// The selection to set for `piece`: its range in its leaf, or through its page's `PageSelector` (also selecting
    /// what's between its parts in the page's text: separators, verse numbers; nil if that has letters, as when a
    /// leaf was found in the wrong place).
    private func target(of piece: Piece) -> Target? {
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

    /// `page`'s `PageSelector`, measured the first time: its first selectable leaf that selects text to the page's end,
    /// where the text selected (the page's text from there) has the following leaves. The page must be on screen
    /// (PDFKit ignores selections elsewhere). Leaves the selection collapsed.
    private func selector(ofPage page: Int) -> PageSelector? {
        if let measured = pageSelectors[page] { return measured }
        guard let texts = pageTexts[page] else { return nil }
        var selector: PageSelector?
        for (index, candidate) in texts.enumerated() where candidate.isSettable {
            if !visiblePages().contains(page) { try? candidate.element.perform(.scrollToVisible) }
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
        pageSelectors[page] = .some(selector)
        return selector
    }

    /// Where each of `values` (a page's leaves in reading order) starts in `text` (the page's text from the first
    /// leaf's start), each searched for a little after the previous one (the page's text also has separators and list
    /// labels); nil if not found there (or empty).
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

    private func highlight(_ selection: Selection?) {
        guard let selection, case let parts = parts(of: selection), !parts.isEmpty else {
            isHighlighting = false
            overlay.hide()
            return
        }
        isHighlighting = true
        overlay.show { [weak self] in
            guard let self, self.app?.isActive != false else { return nil }
            return parts.flatMap(Self.lineRects(of:))
        }
    }

    /// Screen rects (top-left origin) of `selection`, one per line and leaf; what the overlay draws.
    func highlightRects(for selection: Selection) -> [CGRect] {
        parts(of: selection).flatMap(Self.lineRects(of:))
    }

    /// Screen rects (top-left origin) of `part`, one per line; empty off screen.
    private static func lineRects(of part: Part) -> [CGRect] {
        var lines: [CFRange] = []
        var start = part.range.location
        let end = part.range.location + part.range.length
        for lineBreak in part.lineBreaks where lineBreak >= start && lineBreak < end {
            if lineBreak > start { lines.append(CFRange(location: start, length: lineBreak - start)) }
            start = lineBreak + 1
        }
        if end > start { lines.append(CFRange(location: start, length: end - start)) }
        return lines.compactMap { range in
            guard let rect = try? part.element.attribute(.boundsForRange, for: range), rect.width > 0, rect.height > 0
            else { return nil }
            return rect
        }
    }
}
