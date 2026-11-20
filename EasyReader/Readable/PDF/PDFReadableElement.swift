import Cocoa
import Defaults

/// A PDF in PDFKit's `PDFView` (Preview): `AXPage`s down to `AXStaticText` leaves, of which a window of loaded pages is joined into blocks.
final class PDFReadableElement: ReadableElement {
    /// A leaf as laid out in `text`.
    struct PlacedLeaf {
        let element: AXElement
        let page: Int
        /// In `keptLeaves[page]`: identifies the leaf across layouts.
        let index: Int
        var offset: Int
        let length: Int
        /// In-leaf offsets of the line breaks that became spaces.
        let lineBreaks: [Int]
        let isSettable: Bool
        let startsBlock: Bool

        var end: Int { offset + length }
    }

    /// A leaf as read from its page (headers/footers, footnotes and blank leaves left out).
    struct KeptLeaf {
        let element: AXElement
        /// Flattened: line breaks → spaces, hyphenation → word joiners.
        let utf16: [UInt16]
        let lineBreaks: [Int]
        let isSettable: Bool
        /// The nearest ancestor with several children (the paragraph in tagged PDFs).
        let group: AXElement?
        let info: LeafStyle
        /// The size most of the leaf is in (`font(of:utf16:)`), for telling small print.
        let bodySize: CGFloat?
        /// Begins with a footnote mark.
        let isMarked: Bool
        /// A frameless header/footer candidate kept: left out once its key is confirmed (`confirmedMarginKeys`).
        let marginKey: String?
    }

    /// A text leaf found depth first.
    struct RawLeaf {
        let element: AXElement
        let value: String
        /// Nearest ancestor with several children.
        let group: AXElement?
        let inHeading: Bool
    }

    /// Identifies an offset across layouts: leaf index in `keptLeaves[page]` plus offset in the leaf.
    private struct Anchor {
        let page: Int
        let index: Int
        let delta: Int
    }

    struct FontRun {
        let range: NSRange
        let fontSize: CGFloat?
    }

    struct LeafStyle {
        var text: String
        var fontSize: CGFloat?
        var isBold: Bool?
        var isHeading = false
        var isSingleLine: Bool { !text.contains(where: \.isNewline) }
    }

    /// How a leaf's text continues from the previous leaf's.
    enum Join: Equatable {
        case none
        case space
        /// `keepsHyphen`: not a word without it ("self-aware").
        case hyphen(keepsHyphen: Bool)
    }

    /// A unit's part in one leaf.
    struct LeafSlice {
        /// Index in `leaves`, valid until the next layout.
        let leaf: Int
        let element: AXElement
        let lineBreaks: [Int]
        let range: CFRange
    }

    /// Consecutive parts of a unit selected by one `Target`.
    struct SelectionStep {
        /// Offset in the unit.
        let start: Int
        let parts: [LeafSlice]
        /// In `text`.
        let range: Selection
    }

    nonisolated static let wordJoiner: UInt16 = 0x2060

    private var loadedPageElements: [AXElement] = []
    // Not cached while empty: read during document load.
    var pages: [AXElement] {
        if loadedPageElements.isEmpty { loadedPageElements = (try? handle.attribute(.children)) ?? [] }
        return loadedPageElements
    }
    private let scroller: ScrollBarScroller?
    /// nil until reading starts.
    var loadedPages: Range<Int>?
    /// More than this many loaded pages: the window is cut back around the tracked unit (each layout covers every loaded page).
    static let maxLoadedPages = 12
    var loadedPageCount: Int { loadedPages?.count ?? 0 }
    var keptLeaves: [Int: [KeptLeaf]] = [:]
    var selectorLeaves: [Int: [SelectorLeaf]] = [:]
    var pageSelectors: [Int: PageSelector] = [:]
    /// Pages whose selector couldn't be measured, by attempts: given up after `maxSelectorAttempts`.
    var selectorFailures: [Int: Int] = [:]
    static let maxSelectorAttempts = 2
    /// Spell-checking language for dehyphenation; nil = the spell checker's (tests pin English).
    static var spellingLanguage: String?
    var leaves: [PlacedLeaf] = []
    var text = ""
    var textLength = 0
    /// What we set or last took from the user (PDFKit can't select every leaf).
    private var tracked: Selection?
    /// Reports that aren't a new user selection: the one last taken and the one right after our last set.
    private var consumedReport: String?
    var reportAfterSet: String?
    /// A unit spanning leaves, selected piece by piece as it's read.
    private var pieces: [SelectionStep] = []
    private var selectedPiece = 0
    var markerCache: [AXElement: [NSRange]] = [:]
    var runCache: [AXElement: [FontRun]] = [:]
    /// Footnote leaves left out of `text`, by page; pages the user selected in a footnote of keep them instead.
    var footnoteLeaves: [Int: [AXElement]] = [:]
    var pagesReadingFootnotes: Set<Int> = []
    /// The marks (`footnoteLabels(ofLine:)`) the footnotes on each page start with; empty if the body has none of them.
    var footnoteLabels: [Int: Set<String>] = [:]
    /// Each page's possible running headers/footers, kept across windows.
    var pageMarginKeys: [Int: MarginKeys] = [:]
    /// Keys confirmed in the margin by frame on any page so far: frameless candidates matching one are skipped.
    var confirmedMarginKeys: Set<String> = []
    private lazy var overlay = HighlightOverlay()
    private(set) var isHighlighting = false
    /// `cleanUpPDFText` when made (each start): skip headers/footers, footnotes and their marks.
    let cleansUp: Bool

    required init(_ element: AXElement) {
        scroller = (try? element.parent(with: .scrollArea)).map(ScrollBarScroller.init)
        cleansUp = Defaults[.cleanUpPDFText]
        super.init(element)
    }

    override var fullText: String? {
        prepare()
        extendAroundTracked()
        return text
    }

    // Loads the first page: wrapping around after the end reads the document from its start, not the window's.
    override var contentStart: Int {
        if loadedPages?.lowerBound != 0 { load(page: 0) }
        return 0
    }

    /// Footnote marks become word joiners so they aren't read.
    override var selectedText: String? {
        prepare()
        guard let tracked else { return nil }
        var utf16 = Array(string(in: tracked).utf16)
        for part in parts(of: tracked) {
            let leaf = leaves[part.leaf]
            let partRange = part.range.location..<part.range.location + part.range.length
            for marker in markers(of: leaf) {
                let marker = marker.location..<marker.location + marker.length
                for index in marker.clamped(to: partRange) {
                    let position = leaf.offset + index - tracked.lowerBound
                    if utf16.indices.contains(position) { utf16[position] = Self.wordJoiner }
                }
            }
        }
        return String(decoding: utf16, as: UTF16.self)
    }

    override var selection: Selection? {
        get {
            if loadedPages == nil {
                prepare()
            } else if let report = newUserSelection() {
                consumedReport = report
                let kept = loadedPages.flatMap { window in tracked.map { (window, anchors(of: $0), isHighlighting) } }
                if let user = locate(report) {
                    Log.accessibility.debug("pdf: user selected \(user)")
                    tracked = user
                    highlight(nil)
                } else if tracked == nil, let (window, anchors, wasHighlighting) = kept {
                    // Locating moved the window away from the unit being read.
                    loadedPages = nil
                    setWindow(window)
                    tracked = selection(between: anchors)
                    if wasHighlighting { highlight(tracked) }
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
        // Include the line break after the block, so a unit ending at its end finds the next one from there.
        return Selection(leaves[first].offset..<min(leaves[last].end + 1, textLength))
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let leaf = leaf(containing: selection.lowerBound) else { return }
        // Off-screen pages have no character bounds.
        if !isOnScreen(leaf) { try? leaf.element.perform(.scrollToVisible) }
        guard let scroller,
            let bounds = parts(of: selection).lazy.compactMap(Self.firstLineRect(of:)).first,
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

    /// Starts at the user's selection, else at the visible top.
    private func prepare() {
        guard loadedPages == nil else { return }
        let report = try? handle.attribute(.selectedText)
        consumedReport = report
        if let report, !report.isEmpty, let user = locate(report) {
            Log.accessibility.debug("pdf: starting at user selection \(user)")
            tracked = user
            return
        }
        let visible = visiblePages()
        let page = visible.first ?? 0
        load(page: page)
        var top = visibleTop(page: page)
        // Only a sliver of the first page shows, none of its text.
        if top == nil, visible.count > 1 {
            setWindow(page..<visible[1] + 1)
            top = visibleTop(page: visible[1])
        }
        tracked = top ?? Selection(0..<0)
        Log.accessibility.debug("pdf: starting at visible top \(String(describing: tracked)) of page \(page)")
    }

    /// Keeps the tracked unit's neighboring pages loaded (to join text across pages), and more while nothing readable follows or precedes it.
    private func extendAroundTracked() {
        guard let loaded = loadedPages else { return }
        let page = tracked.flatMap { leaf(containing: $0.lowerBound)?.page } ?? loaded.lowerBound
        let near = max(page - 1, 0)..<min(page + 2, pages.count)
        var window = min(loaded.lowerBound, near.lowerBound)..<max(loaded.upperBound, near.upperBound)
        if window.count > Self.maxLoadedPages {
            let isBehindLarger = near.lowerBound - window.lowerBound >= window.upperBound - near.upperBound
            window = isBehindLarger ? near.lowerBound..<window.upperBound : window.lowerBound..<near.upperBound
            if window.count > Self.maxLoadedPages { window = near }
        }
        setWindow(window)
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

    /// Extends the window when `page` is near, else starts a new one there (offsets start over).
    private func ensureLoaded(page: Int) {
        if let loaded = loadedPages, loaded.lowerBound - 3 <= page, page < loaded.upperBound + 3 {
            setWindow(min(loaded.lowerBound, page)..<max(loaded.upperBound, page + 1))
        } else {
            load(page: page)
        }
    }

    private func load(page: Int) {
        keptLeaves = [:]
        loadedPages = nil
        tracked = nil
        highlight(nil)
        setWindow(page..<page + 1)
    }

    /// Re-lays out the text, keeping `tracked` and its pieces on the same text.
    func setWindow(_ window: Range<Int>) {
        guard window != loadedPages else { return }
        let anchors = tracked.map(anchors(of:))
        for page in window where keptLeaves[page] == nil {
            (keptLeaves[page], selectorLeaves[page]) = leaves(ofPage: page)
        }
        keptLeaves = keptLeaves.filter { window.contains($0.key) }
        selectorLeaves = selectorLeaves.filter { window.contains($0.key) }
        loadedPages = window
        layout()
        if let restored = anchors.flatMap(selection(between:)) { tracked = restored }
        // Their parts index the old `leaves`.
        if !pieces.isEmpty {
            let rebuilt = tracked.flatMap(pieces(for:)) ?? []
            pieces = rebuilt.count == pieces.count ? rebuilt : []
        }
    }

    private func anchors(of selection: Selection) -> (lower: Anchor?, upper: Anchor?) {
        (anchor(at: selection.lowerBound), anchor(at: selection.upperBound))
    }

    private func selection(between anchors: (lower: Anchor?, upper: Anchor?)) -> Selection? {
        guard let lower = anchors.lower.map(offset(of:)) else { return nil }
        return Selection(lower..<max(lower, anchors.upper.map(offset(of:)) ?? lower))
    }

    private func anchor(at offset: Int) -> Anchor? {
        guard let leaf = leaf(containing: offset) else { return nil }
        return Anchor(page: leaf.page, index: leaf.index, delta: min(offset - leaf.offset, leaf.length))
    }

    private func offset(of anchor: Anchor) -> Int {
        if let leaf = leaves.first(where: { $0.page == anchor.page && $0.index == anchor.index }) { return leaf.offset + anchor.delta }
        // Its leaf was left out since (a header confirmed later): the next leaf's start.
        return leaves.first { ($0.page, $0.index) > (anchor.page, anchor.index) }?.offset ?? textLength
    }

    // MARK: Leaves

    /// The leaf holding `offset`, or the separator after it.
    private func leafIndex(containing offset: Int) -> Int? {
        guard offset >= 0, offset <= textLength else { return nil }
        var low = 0
        var high = leaves.count
        while low < high {
            let mid = (low + high) / 2
            if leaves[mid].offset <= offset { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    private func leaf(containing offset: Int) -> PlacedLeaf? {
        leafIndex(containing: offset).map { leaves[$0] }
    }

    /// Non-empty parts (or the empty start).
    private func parts(of selection: Selection) -> [LeafSlice] {
        guard let first = leafIndex(containing: selection.lowerBound) else { return [] }
        var parts: [LeafSlice] = []
        for (index, leaf) in leaves.enumerated().dropFirst(first) {
            guard leaf.offset < selection.upperBound || parts.isEmpty else { break }
            let lower = selection.lowerBound.clamped(to: leaf.offset...leaf.end)
            let upper = selection.upperBound.clamped(to: lower...leaf.end)
            guard upper > lower || parts.isEmpty else { continue }
            parts.append(
                LeafSlice(leaf: index, element: leaf.element, lineBreaks: leaf.lineBreaks, range: CFRange(location: lower - leaf.offset, length: upper - lower))
            )
        }
        // Starts on the separator before the next leaf.
        if parts.count > 1, parts[0].range.length == 0 { parts.removeFirst() }
        return parts
    }

    func visiblePages() -> [Int] {
        // AXVisibleChildren fails until AXChildren was read.
        let pages = pages
        if let visible = try? handle.attribute(.visibleChildren), !visible.isEmpty {
            return visible.compactMap { pages.firstIndex(of: $0) }
        }
        guard let scrollFrame = scroller?.frame else { return [] }
        return pages.indices.filter { index in
            (try? pages[index].attribute(.frame)).map { $0.intersects(scrollFrame) } ?? false
        }
    }

    private func isOnScreen(_ leaf: PlacedLeaf) -> Bool {
        visiblePages().contains(leaf.page)
    }

    /// The first character on screen on `page`, as an empty selection.
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

    /// The container's selected text, if the user selected something new.
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

    /// From the visible leaf reporting a selected range, else where `report` first occurs on the visible pages.
    func locate(_ report: String, inFootnotes: Bool = true) -> Selection? {
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
        if inFootnotes, let page = footnotePages(on: visible, where: Self.reportsSelection).first {
            return readFootnotes(on: page, locating: report)
        }
        // Our text differs where lines and leaves are joined: search for the first line.
        let firstLine = report.prefix { !$0.isNewline && $0 != "-" }
        let needle = firstLine.isEmpty ? report : String(firstLine)
        guard let first = visible.first, let last = visible.last else { return nil }
        let pageLeaves = leaves.filter { (first...last).contains($0.page) }
        guard let lower = pageLeaves.first?.offset, let upper = pageLeaves.last?.end else { return nil }
        let found = (text as NSString).range(of: needle, options: .literal, range: NSRange(location: lower, length: upper - lower))
        guard found.location != NSNotFound else {
            let needle = Self.comparable(report)
            // A short or repeated text is more likely a stale selection elsewhere in the document.
            if inFootnotes, Self.isDistinctive(report) {
                let pages = footnotePages(on: visible, where: { Self.comparable(try $0.attribute(.value) ?? "").contains(needle) })
                if pages.count == 1 { return readFootnotes(on: pages[0], locating: report) }
            }
            Log.accessibility.debug("pdf: user selection not found on visible pages \(visible)")
            return nil
        }
        return Selection(found.location..<Self.end(of: report, in: text, from: found.location))
    }

    /// Selects the first piece (the rest follow in `didReach(_:)`), else highlights.
    private func apply(_ selection: Selection) {
        pieces = []
        guard let pieces = pieces(for: selection) else {
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

    /// nil if it has no text or a page can't select.
    private func pieces(for selection: Selection) -> [SelectionStep]? {
        let parts = parts(of: selection).filter { part in
            part.range.length == 0
                || hasText(in: leaves[part.leaf].offset + part.range.location..<leaves[part.leaf].offset + part.range.location + part.range.length)
        }
        guard !parts.isEmpty else { return nil }
        return pieces(of: parts, in: selection)
    }

    /// A selectable leaf's part alone; consecutive non-selectable ones on a page together. nil if a page can't select.
    private func pieces(of parts: [LeafSlice], in selection: Selection) -> [SelectionStep]? {
        var pieces: [SelectionStep] = []
        for part in parts {
            let leaf = leaves[part.leaf]
            let start = leaf.offset + part.range.location
            let range = Selection(start..<start + part.range.length)
            if !leaf.isSettable {
                guard selectorLeaves[leaf.page]?.contains(where: \.isSettable) == true else { return nil }
                if let last = pieces.last, let lastLeaf = last.parts.last.map({ leaves[$0.leaf] }), !lastLeaf.isSettable,
                    lastLeaf.page == leaf.page
                {
                    pieces[pieces.count - 1] = SelectionStep(
                        start: last.start, parts: last.parts + [part], range: Selection(last.range.lowerBound..<range.upperBound))
                    continue
                }
            }
            pieces.append(SelectionStep(start: start - selection.lowerBound, parts: [part], range: range))
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

    /// Compares the selected text with the piece's: the readback length is garbage.
    private func select(_ piece: SelectionStep) -> Bool {
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
        // Ours replaced the user's selection: selecting that text again is new.
        consumedReport = nil
        return true
    }

    private func highlight(_ selection: Selection?) {
        let parts = selection.map { self.parts(of: $0) } ?? []
        guard !parts.isEmpty else {
            isHighlighting = false
            overlay.hide()
            return
        }
        isHighlighting = true
        show(
            overlay, rects: { parts.flatMap(Self.lineRects(of:)) },
            firstCharacter: { parts.first.map { ($0.element, $0.range.location) } })
    }

    func highlightRects(for selection: Selection) -> [CGRect] {
        parts(of: selection).flatMap(Self.lineRects(of:))
    }

    /// One per line; empty off screen.
    private static func lineRects(of part: LeafSlice) -> [CGRect] {
        lineRanges(of: part).compactMap { bounds(of: part.element, $0) }
    }

    private static func firstLineRect(of part: LeafSlice) -> CGRect? {
        lineRanges(of: part).lazy.compactMap { bounds(of: part.element, $0) }.first
    }

    private static func bounds(of element: AXElement, _ range: CFRange) -> CGRect? {
        guard let rect = try? element.attribute(.boundsForRange, for: range), HighlightOverlay.hasSize(rect) else { return nil }
        return rect
    }

    private static func lineRanges(of part: LeafSlice) -> [CFRange] {
        var lines: [CFRange] = []
        var start = part.range.location
        let end = part.range.location + part.range.length
        for lineBreak in part.lineBreaks where lineBreak >= start && lineBreak < end {
            if lineBreak > start { lines.append(CFRange(location: start, length: lineBreak - start)) }
            start = lineBreak + 1
        }
        if end > start { lines.append(CFRange(location: start, length: end - start)) }
        return lines
    }
}
