import Cocoa
import Defaults

/// A PDF in PDFKit's `PDFView` (Preview): the `AXGroup` holding an `AXPage` per page, down to `AXStaticText` leaves.
/// Text = leaves of a window of loaded pages, joined into blocks; headers, footers and footnotes left out (`cleanUpPDFText`).
final class PDFReadableElement: ReadableElement {
    /// A leaf as laid out in `text`.
    private struct Leaf {
        let element: AXElement
        let page: Int
        /// In `pageLeaves[page]`: identifies the leaf across layouts.
        let index: Int
        var offset: Int
        let length: Int
        /// In-leaf offsets of the line breaks that became spaces.
        let lineBreaks: [Int]
        let isSettable: Bool
        let startsBlock: Bool

        var end: Int { offset + length }
    }

    /// A leaf as read from its page (headers/footers and blank leaves left out).
    private struct PageLeaf {
        let element: AXElement
        /// Flattened: line breaks → spaces, hyphenation → word joiners.
        let units: [UInt16]
        let lineBreaks: [Int]
        let isSettable: Bool
        /// The nearest ancestor with several children (the paragraph in tagged PDFs).
        let group: AXElement?
        let info: LeafInfo
        /// The size most of the leaf is in (`font(of:units:)`), for telling small print.
        let bodySize: CGFloat?
        /// Begins with a footnote mark.
        let isMarked: Bool
        /// A frameless header/footer candidate kept: left out once its key is confirmed (`confirmedMarginKeys`).
        let marginKey: String?
    }

    /// A text leaf found depth first.
    private struct StaticText {
        let element: AXElement
        let value: String
        /// Nearest ancestor with several children.
        let group: AXElement?
        let inHeading: Bool
    }

    /// Identifies an offset across layouts: leaf index in `pageLeaves[page]` plus offset in the leaf.
    private struct Anchor {
        let page: Int
        let index: Int
        let delta: Int
    }

    struct FontRun {
        let range: NSRange
        let fontSize: CGFloat?
    }

    struct LeafInfo {
        var text: String
        var fontSize: CGFloat?
        var isBold: Bool?
        var isHeading = false
        var isSingleLine: Bool { !text.contains("\n") }
    }

    /// How a leaf's text continues from the previous leaf's.
    enum Join: Equatable {
        /// A new block.
        case none
        case space
        /// `keepsHyphen`: not a word without it ("self-aware").
        case hyphen(keepsHyphen: Bool)
    }

    /// A unit's part in one leaf.
    private struct Part {
        /// Index in `leaves`, valid until the next layout.
        let leaf: Int
        let element: AXElement
        let lineBreaks: [Int]
        let range: CFRange
    }

    /// Every text leaf of a page, also those left out of `text`: what a `PageSelector` locates.
    private struct PageText {
        let element: AXElement
        let value: String
        let isSettable: Bool
    }

    /// Tagged PDFs: a leaf whose selected range runs on through the rest of the page's text.
    private struct PageSelector {
        let element: AXElement
        /// Where the leaves after it start, relative to it.
        let starts: [AXElement: Int]
        /// The page's text from the selector's start.
        let text: NSString
    }

    /// One selection set: `range` on `element` should select `expected`.
    private struct Target {
        let element: AXElement
        let range: CFRange
        let expected: String
    }

    /// Consecutive parts of a unit selected by one `Target`.
    private struct Piece {
        /// Offset in the unit.
        let start: Int
        let parts: [Part]
        /// In `text`.
        let range: Selection
    }

    nonisolated static let wordJoiner: UInt16 = 0x2060

    private lazy var pages: [AXElement] = (try? handle.attribute(.children)) ?? []
    private let scroller: ScrollBarScroller?
    /// nil until reading starts.
    private var loadedPages: Range<Int>?
    /// More than this many loaded pages: the window is cut back around the tracked unit (each layout covers every loaded page).
    static let maxLoadedPages = 12
    var loadedPageCount: Int { loadedPages?.count ?? 0 }
    private var pageLeaves: [Int: [PageLeaf]] = [:]
    private var pageTexts: [Int: [PageText]] = [:]
    /// `.some(nil)`: the page has none that works.
    private var pageSelectors: [Int: PageSelector?] = [:]
    private var leaves: [Leaf] = []
    private var text = ""
    private var textLength = 0
    /// What we set or last took from the user (PDFKit can't select every leaf).
    private var tracked: Selection?
    /// Reports that aren't a new user selection: the one last taken and the one right after our last set.
    private var consumedReport: String?
    private var reportAfterSet: String?
    /// A unit spanning leaves, selected piece by piece as it's read.
    private var pieces: [Piece] = []
    private var selectedPiece = 0
    private var markerCache: [AXElement: [NSRange]] = [:]
    private var runCache: [AXElement: [FontRun]] = [:]
    /// Footnote leaves left out of `text`, by page; pages the user selected in a footnote of keep them instead.
    private var footnoteLeaves: [Int: [AXElement]] = [:]
    private var pagesReadingFootnotes: Set<Int> = []
    /// The marks (`footnoteLabels(ofLine:)`) the footnotes on each page start with; empty if the body has none of them.
    private var footnoteLabels: [Int: Set<String>] = [:]
    /// Each page's possible running headers/footers, kept across windows.
    private var pageMarginKeys: [Int: MarginKeys] = [:]
    /// Keys confirmed in the margin by frame on any page so far: frameless candidates matching one are skipped.
    private var confirmedMarginKeys: Set<String> = []
    private lazy var overlay = HighlightOverlay()
    private(set) var isHighlighting = false
    /// `cleanUpPDFText` when made (each start): skip headers/footers, footnotes and their marks.
    private let cleansUp: Bool

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

    /// Footnote marks become word joiners so they aren't read.
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
        // Include the line break after the block, so a unit ending at its end finds the next one from there
        return Selection(leaves[first].offset..<min(leaves[last].end + 1, textLength))
    }

    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let leaf = leaf(containing: selection.lowerBound) else { return }
        // Off-screen pages have no character bounds
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
        let page = visiblePages().first ?? 0
        load(page: page)
        tracked = visibleTop(page: page) ?? Selection(0..<0)
        Log.accessibility.debug("pdf: starting at visible top \(String(describing: tracked)) of page \(page)")
    }

    /// Keeps the pages next to the tracked unit's loaded (to join text across pages), and more while nothing readable
    /// follows or precedes it.
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

    /// Extends the window when `page` is near, else starts a new one there (offsets start over).
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

    /// Re-lays out the text, keeping `tracked` and its pieces on the same text.
    func setWindow(_ window: Range<Int>) {
        guard window != loadedPages else { return }
        let anchors = tracked.map { (anchor(at: $0.lowerBound), anchor(at: $0.upperBound)) }
        for page in window where pageLeaves[page] == nil {
            (pageLeaves[page], pageTexts[page]) = leaves(ofPage: page)
        }
        pageLeaves = pageLeaves.filter { window.contains($0.key) }
        pageTexts = pageTexts.filter { window.contains($0.key) }
        loadedPages = window
        layout()
        if let (lower, upper) = anchors, let lower = lower.map(offset(of:)) {
            tracked = Selection(lower..<max(lower, upper.map(offset(of:)) ?? lower))
        }
        // Their parts index the old `leaves`
        if !pieces.isEmpty {
            let rebuilt = tracked.flatMap(pieces(for:)) ?? []
            pieces = rebuilt.count == pieces.count ? rebuilt : []
        }
    }

    private func anchor(at offset: Int) -> Anchor? {
        guard let leaf = leaf(containing: offset) else { return nil }
        return Anchor(page: leaf.page, index: leaf.index, delta: min(offset - leaf.offset, leaf.length))
    }

    private func offset(of anchor: Anchor) -> Int {
        if let leaf = leaves.first(where: { $0.page == anchor.page && $0.index == anchor.index }) { return leaf.offset + anchor.delta }
        // Its leaf was left out since (a header confirmed later): the next leaf's start
        return leaves.first { ($0.page, $0.index) > (anchor.page, anchor.index) }?.offset ?? textLength
    }

    // MARK: Text

    /// Blocks joined by line breaks; smaller leaves met while a sentence runs on (footnotes, captions) go after its block.
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
            if !units.isEmpty { Self.appendSeparator(join, before: leaf.units, to: &units) }
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
                if let key = leaf.marginKey, confirmedMarginKeys.contains(key) {
                    Log.accessibility.debug("pdf: page \(page): skipping header/footer confirmed since \(leaf.info.text)")
                    continue
                }
                // Deferring stops at the page after the open sentence's.
                if let previous, Self.runsOn(previous.info), page <= previousPage + 1 {
                    if Self.isSmaller(leaf.bodySize, than: previous.bodySize) {
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

    private nonisolated static func appendSeparator(_ join: Join, before next: [UInt16], to units: inout [UInt16]) {
        switch join {
            case .none: units.append(0x0A)
            case .space:
                // No space before closing punctuation ("Wheel" "." → "Wheel⁠.")
                let startsWithPunctuation = next.first.flatMap(Unicode.Scalar.init).map {
                    CharacterSet(charactersIn: ".,;:!?)]}”’").contains($0)
                }
                units.append(startsWithPunctuation == true ? wordJoiner : 0x20)
            case .hyphen(let keepsHyphen):
                var end = units.count - 1
                while end >= 0, isBlank(units[end]) {
                    units[end] = wordJoiner
                    end -= 1
                }
                if !keepsHyphen, end >= 0, units[end] == 0x2D { units[end] = wordJoiner }
                units.append(wordJoiner)
        }
    }

    /// Depth first, without running headers/footers (a frameless one must match one confirmed by frame on any page).
    private func leaves(ofPage page: Int) -> ([PageLeaf], [PageText]) {
        guard pages.indices.contains(page) else { return ([], []) }
        let statics = staticTexts(ofPage: page)
        let candidates = cleansUp ? marginCandidates(statics, page: page) : [:]
        var nearbyKeys: Set<String> = []
        if cleansUp {
            setMarginKeys(MarginKeys(candidates, statics: statics), ofPage: page)
            let nearby = (max(page - 2, 0)...min(page + 2, pages.count - 1)).filter { $0 != page }.map(marginKeys(ofPage:))
            nearbyKeys = Set(nearby.flatMap(\.all))
        }
        var leaves: [PageLeaf] = []
        var texts: [PageText] = []
        for (index, staticText) in statics.enumerated() {
            let (element, value, group, inHeading) = (staticText.element, staticText.value, staticText.group, staticText.inHeading)
            let isSettable = element.isSettable(.selectedTextRange)
            texts.append(PageText(element: element, value: value, isSettable: isSettable))
            let (flat, lineBreaks) = Self.flattened(value)
            let rule = Self.ruleLength(value)
            var units = Array(flat.utf16)
            units.replaceSubrange(..<rule, with: repeatElement(0x20, count: rule))
            guard units.contains(where: { !Self.isBlank($0) }) else { continue }
            if let candidate = candidates[index], (candidate.inMargin ? nearbyKeys : confirmedMarginKeys).contains(candidate.key) {
                Log.accessibility.debug("pdf: page \(page): skipping header/footer \(flat)")
                continue
            }
            Self.dehyphenate(&units, lineBreaks: lineBreaks, isWord: Self.isWord)
            if let lineBreak = Self.headingEnd(of: element, units: units, lineBreaks: lineBreaks) { units[lineBreak] = 0x0A }
            let font = Self.font(of: element, units: units)
            let text = String(repeating: " ", count: rule) + (String(value.utf16.dropFirst(rule)) ?? "")
            leaves.append(
                PageLeaf(
                    element: element, units: units, lineBreaks: lineBreaks,
                    isSettable: isSettable, group: group,
                    info: LeafInfo(text: text, fontSize: font.size, isBold: font.isBold, isHeading: inHeading),
                    bodySize: font.bodySize, isMarked: font.startsSuperscript || Self.startsWithMark(text),
                    marginKey: candidates[index].flatMap { $0.inMargin ? nil : $0.key }))
        }
        guard cleansUp else { return (leaves, texts) }
        let pageFrame = try? pages[page].attribute(.frame)
        let footnotes = Self.footnoteStart(leaves.map { ($0.bodySize, $0.units.count, $0.isMarked) }) { index in
            guard let pageFrame, let frame = try? leaves[index].element.attribute(.frame), !frame.isEmpty, frame.minY.isFinite
            else { return nil }
            return frame.minY > pageFrame.midY
        }
        let labels = Set(
            leaves[footnotes...].flatMap { leaf in
                leaf.info.text.split(whereSeparator: \.isNewline).enumerated().flatMap { line, text in
                    (line == 0 && leaf.isMarked) || Self.startsWithMark(String(text)) ? Self.footnoteLabels(ofLine: String(text)) : []
                }
            })
        // Small print that only looks marked (table rows, numbered steps) has no matching mark in the body
        let isConfirmed = footnotes < leaves.count && hasMark(in: leaves[..<footnotes], labels: labels)
        footnoteLabels[page] = isConfirmed ? labels : []
        if isConfirmed, !pagesReadingFootnotes.contains(page) {
            footnoteLeaves[page] = leaves[footnotes...].map(\.element)
            Log.accessibility.debug("pdf: page \(page): skipping \(leaves.count - footnotes) footnote leaves")
            leaves.removeSubrange(footnotes...)
        }
        return (leaves, texts)
    }

    /// Text leaves depth first.
    private func staticTexts(ofPage page: Int) -> [StaticText] {
        var statics: [StaticText] = []
        var stack: [(AXElement, AXElement?, Bool)] = [(pages[page], nil, false)]
        while let (element, group, inHeading) = stack.popLast() {
            let role = try? element.role()
            guard role == .staticText else {
                let children = (try? element.attribute(.children)) ?? []
                let childGroup = children.count > 1 ? element : group
                stack += children.reversed().map { ($0, childGroup, role == .heading) }
                continue
            }
            statics.append(StaticText(element: element, value: (try? element.attribute(.value)) ?? "", group: group, inHeading: inHeading))
        }
        return statics
    }

    /// Possible running headers/footers by index in `statics`: single short lines in the top or bottom margin, or
    /// (no frame) among the page's first or last two lines.
    private func marginCandidates(_ statics: [StaticText], page: Int) -> [Int: (key: String, inMargin: Bool)] {
        let pageFrame = try? pages[page].attribute(.frame)
        let nonBlank = statics.indices.filter { statics[$0].value.contains { !$0.isWhitespace } }
        let edges = Set(nonBlank.prefix(2) + nonBlank.suffix(2))
        var candidates: [Int: (key: String, inMargin: Bool)] = [:]
        for index in nonBlank {
            let value = statics[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.contains(where: \.isNewline), value.count <= 80 else { continue }
            if let pageFrame, let frame = try? statics[index].element.attribute(.frame), !frame.isEmpty, frame.minY.isFinite {
                if Self.isInMargin(frame, of: pageFrame) { candidates[index] = (Self.marginKey(value), true) }
            } else if edges.contains(index) {
                candidates[index] = (Self.marginKey(value), false)
            }
        }
        return candidates
    }

    /// A page's margin candidates' keys: all, and those confirmed in the margin by their frame.
    private struct MarginKeys {
        var all: Set<String> = []
        var confirmed: Set<String> = []
        /// A candidate that had no frame (page off screen): the keys are computed again once it has one.
        var frameless: AXElement?

        init(_ candidates: [Int: (key: String, inMargin: Bool)], statics: [StaticText]) {
            for (index, candidate) in candidates {
                all.insert(candidate.key)
                if candidate.inMargin { confirmed.insert(candidate.key) } else { frameless = statics[index].element }
            }
        }
    }

    private func marginKeys(ofPage page: Int) -> MarginKeys {
        if let keys = pageMarginKeys[page], !(keys.frameless.map(Self.hasFrame) ?? false) { return keys }
        let statics = staticTexts(ofPage: page)
        let keys = MarginKeys(marginCandidates(statics, page: page), statics: statics)
        setMarginKeys(keys, ofPage: page)
        return keys
    }

    private func setMarginKeys(_ keys: MarginKeys, ofPage page: Int) {
        pageMarginKeys[page] = keys
        confirmedMarginKeys.formUnion(keys.confirmed)
    }

    private static func hasFrame(_ element: AXElement) -> Bool {
        guard let frame = try? element.attribute(.frame) else { return false }
        return !frame.isEmpty && frame.minY.isFinite
    }

    /// Page numbers (digits, roman numerals) normalized, so "Page 3 of 9" and "xii" match on other pages.
    nonisolated static func marginKey(_ text: String) -> String {
        var key = text.lowercased()
        for pattern in [#"\d+"#, #"\b[ivxlcdm]{1,6}\b"#] {
            key = key.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Where the footnotes start: the first marked leaf among the trailing leaves in a font smaller than the page's
    /// body text, unless `isLow` says it's in the upper half (nil: unknown). `leaves.count` if none.
    nonisolated static func footnoteStart(_ leaves: [(fontSize: CGFloat?, length: Int, isMarked: Bool)], isLow: (Int) -> Bool?) -> Int {
        guard let body = dominantSize(leaves.map { ($0.fontSize, $0.length) }) else { return leaves.count }
        var start = leaves.count
        while start > 0, isSmaller(leaves[start - 1].fontSize, than: body) { start -= 1 }
        return leaves.indices[start...].first { leaves[$0].isMarked && isLow($0) != false } ?? leaves.count
    }

    /// The mark a footnote starts with, digits as ASCII: "12. Text" → "12", "[3]" → "3", "¹Text" → "1", "a Jer." → "a",
    /// "†Text" → "†".
    nonisolated static func footnoteLabel(_ text: String) -> String? {
        let start = text.drop { $0.isWhitespace || $0 == "[" || $0 == "(" }
        let digits = start.prefix { $0.wholeNumberValue != nil }
        if !digits.isEmpty { return digits.map { String($0.wholeNumberValue!) }.joined() }
        let symbols = start.prefix { "*†‡§¶".contains($0) }
        if !symbols.isEmpty { return String(symbols) }
        return start.first.flatMap { $0.isLowercase ? String($0) : nil }
    }

    /// `footnoteLabel`, and for scripture ("19 a Text", "1 1a Text") the letter too: the body marks are letters.
    nonisolated static func footnoteLabels(ofLine text: String) -> [String] {
        guard let label = footnoteLabel(text) else { return [] }
        let verse = #"^\s*\d{1,3}\s*\d{0,3}\s*([a-z])(?:\s|$)"#
        guard let match = text.range(of: verse, options: .regularExpression) else { return [label] }
        let letter = text[match].last { $0.isLetter }.map(String.init)
        return [label] + (letter.map { [$0] } ?? [])
    }

    /// Whether a footnote label is a mark in the body: glued to the text, a leaf of its own, else a small font run.
    private func hasMark(in body: ArraySlice<PageLeaf>, labels: Set<String>) -> Bool {
        if body.contains(where: { leaf in labels.contains { Self.hasGluedMark($0, in: leaf.info.text) } }) { return true }
        if body.contains(where: { labels.contains($0.info.text.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return true }
        return body.contains { leaf in
            leaf.isSettable
                && !Self.markerRanges(fontRuns(of: leaf.element, length: leaf.units.count), in: leaf.info.text, labels: labels).isEmpty
        }
    }

    /// A digit or symbol label glued to a word's end: "ruling.12 Next", "boxes*", not "Form 1212" (letters can't be told).
    nonisolated static func hasGluedMark(_ label: String, in text: String) -> Bool {
        guard !label.isEmpty, !label.contains(where: \.isLetter) else { return false }
        let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let ascii = String(text.map { char in superscripts.firstIndex(of: char).map { Character(String($0)) } ?? char })
        let pattern = #"(?<=[\p{L}.,;:?!)\]”’"])"# + NSRegularExpression.escapedPattern(for: label) + #"(?=[\s\p{P}\p{S}]|$)"#
        return ascii.range(of: pattern, options: .regularExpression) != nil
    }

    /// UTF-16 length of the rule lines ("——————", "____") a leaf starts with, as before footnotes: no words to read.
    nonisolated static func ruleLength(_ text: String) -> Int {
        let rule = #"^(?:\s*(?:[-‐‑‒–—―⸺⸻_─━][ \t]*){2,}(?:\R|$))+"#
        return text.range(of: rule, options: .regularExpression).map { text.utf16.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
    }

    /// "1 Text", "12. Text", "[3]", "(4)", "a Jer. 5:3", "*Text", "¹Text".
    nonisolated static func startsWithMark(_ text: String) -> Bool {
        let mark = #"^\s*(?:(?:\d{1,3}|[a-z]|\[\d{1,3}\]|\(\d{1,3}\))[.):]?(?:\s|$)|[*†‡§¶¹²³⁰⁴-⁹])"#
        return text.range(of: mark, options: .regularExpression) != nil
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

    /// In-leaf ranges of footnote marks; only selectable leaves have font info.
    private func markers(of leaf: Leaf) -> [NSRange] {
        if let cached = markerCache[leaf.element] { return cached }
        let labels = footnoteLabels[leaf.page] ?? []
        let runs = leaf.isSettable && !labels.isEmpty ? fontRuns(of: leaf.element, length: leaf.length) : []
        let markers = runs.isEmpty ? [] : Self.markerRanges(runs, in: string(in: Selection(leaf.offset..<leaf.end)), labels: labels)
        if markerCache.count > 2000 { markerCache = [:] }
        markerCache[leaf.element] = markers
        return markers
    }

    /// A leaf's font sizes by run (one AX call, ~50 ms), cached.
    private func fontRuns(of element: AXElement, length: Int) -> [FontRun] {
        if let cached = runCache[element] { return cached }
        var runs: [FontRun] = []
        if let string = try? element.attribute(.attributedStringForRange, for: CFRange(location: 0, length: length))?.string {
            string.enumerateAttribute(.axFont, in: NSRange(location: 0, length: string.length)) {
                font, range, _ in
                runs.append(FontRun(range: range, fontSize: (font as? [String: Any]).flatMap(Self.fontSize(in:))))
            }
        }
        if runCache.count > 2000 { runCache = [:] }
        runCache[element] = runs
        return runs
    }

    /// Runs of 1–3 alphanumerics or `*†‡§¶` under 75% of the leaf's dominant font size, trimmed.
    /// Only marks matching one of `labels` (the page's footnotes) count: exponents, units and endnote numbers are read.
    nonisolated static func markerRanges(_ runs: [FontRun], in text: String, labels: Set<String>) -> [NSRange] {
        guard let body = dominantSize(runs.map { ($0.fontSize, $0.range.length) }) else { return [] }
        let text = text as NSString
        let markChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*†‡§¶"))
        return runs.compactMap { run in
            guard let size = run.fontSize, size < body * 0.75, NSMaxRange(run.range) <= text.length else { return nil }
            let mark = text.substring(with: run.range)
            let trimmed = mark.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...3).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy(markChars.contains),
                footnoteLabel(trimmed).map(labels.contains) == true
            else { return nil }
            let inner = (mark as NSString).range(of: trimmed)
            return NSRange(location: run.range.location + inner.location, length: inner.length)
        }
    }

    nonisolated static func isInMargin(_ frame: CGRect, of pageFrame: CGRect) -> Bool {
        guard !frame.isEmpty, frame.minY.isFinite, !pageFrame.isEmpty else { return false }
        let margin = pageFrame.height * 0.08
        return frame.maxY <= pageFrame.minY + margin || frame.minY >= pageFrame.maxY - margin
    }

    /// Size: max of first/middle char; body size: median with the last; bold: all three; superscript: first <75% of middle.
    private static func font(of element: AXElement, units: [UInt16])
        -> (size: CGFloat?, bodySize: CGFloat?, isBold: Bool?, startsSuperscript: Bool)
    {
        let fonts = [units.count / 2, 0, units.lastIndex { !isBlank($0) } ?? 0].map { font(of: element, at: $0) }
        let startsSuperscript = fonts[1]?.size.map { first in fonts[0]?.size.map { first < $0 * 0.75 } ?? false } ?? false
        return (fonts.prefix(2).compactMap { $0?.size }.max(), bodySize(fonts.map { $0?.size }), isBold(fonts), startsSuperscript)
    }

    /// The median of the middle, first and last characters' sizes; else the middle's.
    nonisolated static func bodySize(_ sizes: [CGFloat?]) -> CGFloat? {
        let known = sizes.compactMap { $0 }.sorted()
        return known.count == 3 ? known[1] : sizes.first.flatMap { $0 } ?? known.first
    }

    private static func font(of element: AXElement, at index: Int) -> (size: CGFloat?, name: String?)? {
        guard let string = try? element.attribute(.attributedStringForRange, for: CFRange(location: index, length: 1))?.string,
            string.length > 0,
            let font = string.attribute(.axFont, at: 0, effectiveRange: nil) as? [String: Any]
        else { return nil }
        return (fontSize(in: font), font["AXFontName"] as? String)
    }

    /// nil if any font name is unknown.
    private static func isBold(_ fonts: [(size: CGFloat?, name: String?)?]) -> Bool? {
        let names = fonts.map { $0?.name }
        return names.contains(nil) ? nil : names.allSatisfy { isBold(fontName: $0!) }
    }

    /// The line break ending a heading the leaf starts with: up to 3 lines bold (start and end) or larger, before a
    /// line that isn't and starts with a capital.
    private static func headingEnd(of element: AXElement, units: [UInt16], lineBreaks: [Int]) -> Int? {
        var lineStart = 0
        for lineBreak in lineBreaks.prefix(3) {
            guard let lineEnd = units[lineStart..<lineBreak].lastIndex(where: { !isBlank($0) }),
                let next = units[(lineBreak + 1)...].firstIndex(where: { !isBlank($0) }),
                Unicode.Scalar(units[next]).map(CharacterSet.uppercaseLetters.contains) == true
            else { return nil }
            let line = [lineStart, lineEnd].map { font(of: element, at: $0) }
            let after = font(of: element, at: next)
            let lineSize = line.compactMap { $0?.size }.min()
            if isSmaller(after?.size, than: lineSize) || (isBold(line) == true && isBold([after]) == false) { return lineBreak }
            // Only a bold heading runs on to more lines
            guard isBold(line) == true, isBold([after]) == true else { return nil }
            lineStart = lineBreak + 1
        }
        return nil
    }

    /// PostScript names carry the weight: "Arial-BoldMT", "ABCDEF+Inter-SemiBold", "Arial-Black".
    nonisolated static func isBold(fontName: String) -> Bool {
        let name = fontName.lowercased()
        return ["bold", "black", "heavy"].contains { name.contains($0) }
    }

    // PDFKit vends AXFontSize as a string ("10.296")
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

    /// Line breaks → spaces (same UTF-16 length), with their offsets.
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

    /// Letter-hyphen-break-lowercase: the break (and the hyphen, if the joined word is one) become word joiners.
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

    /// Continues when `previous` ends mid-sentence in about the same font, unless it's a heading (`AXHeading`, one
    /// title-case line, or bold before regular text; each before a capital).
    nonisolated static func join(_ previous: LeafInfo, _ next: LeafInfo, isWord: (String) -> Bool) -> Join {
        guard !previous.isHeading, endsMidSentence(previous.text),
            !isSmaller(next.fontSize, than: previous.fontSize), !isSmaller(previous.fontSize, than: next.fontSize),
            let first = next.text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .none }
        if CharacterSet.uppercaseLetters.contains(first),
            (previous.isSingleLine && isTitleCase(previous.text)) || (previous.isBold == true && next.isBold == false)
        {
            return .none
        }
        let end = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if end.hasSuffix("-"), CharacterSet.lowercaseLetters.contains(first) {
            let before = end.dropLast().reversed().prefix { $0.isLetter }
            let after = next.text.drop { $0.isWhitespace }.prefix { $0.isLetter }
            if !before.isEmpty { return .hyphen(keepsHyphen: !isWord(String(before.reversed()) + after)) }
        }
        return .space
    }

    /// A sentence is open at the end of `leaf` (smaller text after it is deferred).
    nonisolated static func runsOn(_ leaf: LeafInfo) -> Bool {
        !leaf.isHeading && endsMidSentence(leaf.text) && !(leaf.isSingleLine && isTitleCase(leaf.text))
    }

    nonisolated static func endsMidSentence(_ text: String) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'”’»)]}").union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "\u{2060}"))
        guard let last = text.unicodeScalars.last(where: { !closing.contains($0) }) else { return false }
        return !".!?…:".unicodeScalars.contains(last)
    }

    /// Words of 4+ letters all capitalized: "PRESENT CODE — ACTIVITY", "Quality of Life".
    nonisolated static func isTitleCase(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }.filter { $0.count >= 4 }
        return !words.isEmpty && words.allSatisfy { $0.first?.isUppercase == true }
    }

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

    // PDFKit's reports keep line breaks and hyphens and drop trailing whitespace
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

    private func leaf(containing offset: Int) -> Leaf? {
        leafIndex(containing: offset).map { leaves[$0] }
    }

    /// Non-empty parts (or the empty start).
    private func parts(of selection: Selection) -> [Part] {
        guard let first = leafIndex(containing: selection.lowerBound) else { return [] }
        var parts: [Part] = []
        for (index, leaf) in leaves.enumerated().dropFirst(first) {
            guard leaf.offset < selection.upperBound || parts.isEmpty else { break }
            let lower = selection.lowerBound.clamped(to: leaf.offset...leaf.end)
            let upper = selection.upperBound.clamped(to: lower...leaf.end)
            guard upper > lower || parts.isEmpty else { continue }
            parts.append(
                Part(leaf: index, element: leaf.element, lineBreaks: leaf.lineBreaks, range: CFRange(location: lower - leaf.offset, length: upper - lower)))
        }
        // Starts on the separator before the next leaf
        if parts.count > 1, parts[0].range.length == 0 { parts.removeFirst() }
        return parts
    }

    private func visiblePages() -> [Int] {
        // AXVisibleChildren fails until AXChildren was read
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
    private func locate(_ report: String, inFootnotes: Bool = true) -> Selection? {
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
        // Our text differs where lines and leaves are joined: search for the first line
        let firstLine = report.prefix { !$0.isNewline && $0 != "-" }
        let needle = firstLine.isEmpty ? report : String(firstLine)
        guard let first = visible.first, let last = visible.last else { return nil }
        let pageLeaves = leaves.filter { (first...last).contains($0.page) }
        guard let lower = pageLeaves.first?.offset, let upper = pageLeaves.last?.end else { return nil }
        let found = (text as NSString).range(of: needle, options: .literal, range: NSRange(location: lower, length: upper - lower))
        guard found.location != NSNotFound else {
            let needle = Self.comparable(report)
            // A short or repeated text is more likely a stale selection elsewhere in the document
            if inFootnotes, Self.isDistinctive(report) {
                let pages = footnotePages(on: visible, where: { Self.comparable(try $0.attribute(.value) ?? "").contains(needle) })
                if pages.count == 1 { return readFootnotes(on: pages[0], locating: report) }
            }
            Log.accessibility.debug("pdf: user selection not found on visible pages \(visible)")
            return nil
        }
        return Selection(found.location..<Self.end(of: report, in: text, from: found.location))
    }

    /// The page of each skipped footnote leaf on the visible pages matching `predicate`.
    private func footnotePages(on visible: [Int], where predicate: (AXElement) throws -> Bool) -> [Int] {
        visible.flatMap { page in (footnoteLeaves[page] ?? []).filter { (try? predicate($0)) == true }.map { _ in page } }
    }

    /// At least 2 words and 12 letters.
    nonisolated static func isDistinctive(_ report: String) -> Bool {
        report.split { !$0.isLetter && !$0.isNumber }.count >= 2 && report.filter(\.isLetter).count >= 12
    }

    /// Non-selectable (tagged) leaves report a range regardless; PDFKit reports none as `NSNotFound`.
    private static func reportsSelection(_ leaf: AXElement) throws -> Bool {
        guard leaf.isSettable(.selectedTextRange), let range = try leaf.attribute(.selectedTextRange) else { return false }
        return range.location != kCFNotFound && range.location != NSNotFound
    }

    /// Puts the page's footnotes in the text, then locates the user's selection again.
    private func readFootnotes(on page: Int, locating report: String) -> Selection? {
        Log.accessibility.debug("pdf: user selected in a footnote on page \(page): reading the page's footnotes")
        pagesReadingFootnotes.insert(page)
        footnoteLeaves[page] = nil
        pageLeaves[page] = nil
        if let window = loadedPages {
            loadedPages = nil
            setWindow(window)
        }
        return locate(report, inFootnotes: false)
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
    private func pieces(for selection: Selection) -> [Piece]? {
        let parts = parts(of: selection).filter { part in
            part.range.length == 0
                || hasText(in: leaves[part.leaf].offset + part.range.location..<leaves[part.leaf].offset + part.range.location + part.range.length)
        }
        guard !parts.isEmpty else { return nil }
        return pieces(of: parts, in: selection)
    }

    /// A selectable leaf's part alone; consecutive non-selectable ones on a page together. nil if a page can't select.
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

    /// Checks the piece's text got selected.
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

    /// Through a `PageSelector`, also selects what's between the parts; nil if that has letters (leaf misplaced).
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

    /// Measured once by selecting from a candidate to the page's end (on screen only), then collapsed.
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

    private func highlight(_ selection: Selection?) {
        let parts = selection.map { self.parts(of: $0) } ?? []
        guard !parts.isEmpty else {
            isHighlighting = false
            overlay.hide()
            return
        }
        isHighlighting = true
        overlay.show { [weak self] in
            guard let self, app?.isActive != false else { return nil }
            return parts.flatMap(Self.lineRects(of:))
        }
    }

    func highlightRects(for selection: Selection) -> [CGRect] {
        parts(of: selection).flatMap(Self.lineRects(of:))
    }

    /// One per line; empty off screen.
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

extension NSAttributedString.Key {
    fileprivate static let axFont = Self("AXFont")
}
