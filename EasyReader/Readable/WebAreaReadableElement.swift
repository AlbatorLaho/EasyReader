//
//  WebAreaReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa

/// A web page (Safari/WebKit incl. `WKWebView`, Chromium, Firefox), read through the AX text-marker API.
///
/// Web areas have no `AXValue`/`AXSelectedTextRange`; text positions are opaque text markers instead. The page text is
/// the string between `AXStartTextMarker` and `AXEndTextMarker`, and a marker's offset is the UTF-16 length of the text
/// before it (consistent with the full text by construction). `AXTextMarkerForIndex`/`AXIndexForTextMarker` use a
/// different count (it drifts by dozens of characters on real pages), so they only seed the search for an offset's marker.
///
/// Not every browser lets AX clients change the page selection: Chromium reports the user's selection (only once its
/// full AX mode is on, see `beginReading`) but only lets AX clients set it (`AXSelectedTextMarkerRange`) in editable
/// text (by design: VoiceOver's selection changes interfered with its navigation). With the flag "Enable text editing
/// through accessibility APIs" (chrome://flags/#enable-accessibility-text-operation, off by default) it selects page
/// text through `AXTextOperation` instead; without it the selection is only tracked here: reading starts at the user's
/// selection or caret, else at the top of the visible part of the page, and continues from there, highlighted by a
/// `HighlightOverlay`. Safari/WebKit and Firefox support setting it.
///
/// Chromium also needs its page text leaves (`PageLeaves`) for highlighting, scrolling and finding the visible top, and
/// reports its text blocks (paragraphs, headings…) to the reader, as its page text has no line breaks between them.
final class WebAreaReadableElement: ReadableElement {
    /// The selection EasyReader set or last took from the browser. The browser's own report can't simply be read back:
    /// Chromium ignores selection changes (it keeps reporting the user's selection), and right after a change Safari can
    /// briefly report an in-between range.
    private var trackedSelection: Selection?
    /// The page text `trackedSelection` refers to. Pages can change a little while reading (Wikipedia in Brave: a few
    /// characters inserted before the selection), so the selection is moved to its text's new position then.
    private var trackedText: String?
    /// What the browser reported when tracking began and right after the last selection change. While it reports one of
    /// these or the tracked selection, nothing changed; anything else is a selection by the user. Compared by text near
    /// the same offset, since the page text can shift.
    private var baseline: Report?
    private var reportAfterSet: Report?

    private struct Report {
        let selection: Selection
        let string: String

        func matches(_ other: Report, tolerance: Int = 64) -> Bool {
            string == other.string && abs(selection.lowerBound - other.selection.lowerBound) <= tolerance
        }
    }

    /// Page text, kept only for the current main-actor turn: EasyReader reads it several times per unit (30 ms each on
    /// a long Chromium page), while the page may change between units.
    private var cachedText: String?

    /// App-wide AX flags this readable turned on, restored by `endReading`.
    private var enabledAppFlags: [AXAttribute<Bool>] = []
    /// Turns `enabledAppFlags` back on while reading if the app turned them off (see `watchAppFlags`).
    private var appFlagsWatch: Task<Void, Never>?

    /// Chromium (incl. Electron and Brave): ignores selection changes on page text, and needs `PageLeaves`.
    private lazy var isChromium = handle.attributeNames.contains("ChromeAXNodeId")
    /// The page's scroll area, when it exposes a vertical scroll bar (WebKit, not Chromium): see `scroll(to:options:)`.
    private lazy var pageScroller: ScrollBarScroller? = {
        guard let scrollArea = try? handle.parent(with: .scrollArea) else { return nil }
        let scroller = ScrollBarScroller(scrollArea)
        return scroller.hasVerticalScrollBar ? scroller : nil
    }()
    /// Chromium with chrome://flags/#enable-accessibility-text-operation: selects page text through `AXTextOperation`.
    private(set) lazy var canSelectByTextOperation =
        isChromium && handle.parameterizedAttributeNames.contains(AXParameterizedAttribute<AXTextOperation, AXAnyValue>.textOperation.name)
    /// The last leaf marker made for `AXTextOperation`, to step from: the next unit usually starts where the last ended.
    private var lastLeafMarker: (element: AXElement, local: Int, marker: AXTextMarker)?
    private(set) var pageLeaves: PageLeaves?
    private lazy var overlay = HighlightOverlay()
    /// The last browser report, kept while the browser reports the same marker range for the same page text: measuring
    /// it costs time proportional to its offset.
    private var lastReport: (range: AXTextMarkerRange, text: String, report: Report)?
    /// Chromium: the leaf holding the start of the browser's selection, where `PageLeaves` lookups start.
    private var reportedLeaf: AXElement?

    /// Chromium (and Electron) build their full AX tree, incl. the page selection, only for assistive apps: Electron
    /// listens to `AXManualAccessibility`, Chromium to `AXEnhancedUserInterface` (what VoiceOver sets; while on, some
    /// apps skip window animations, which is why it's only on while reading). Other browsers ignore both.
    /// Chromium keeps its full tree after the flag is turned off again.
    override func beginReading() {
        if enabledAppFlags.isEmpty, let pid = try? handle.pid(), pid != getpid() {
            enabledAppFlags = WebAccessibility.enable(pid: pid)
            Log.accessibility.debug("web area: turned on \(enabledAppFlags) for \(appDomain ?? "unknown app")")
        }
        watchAppFlags()
    }

    /// Takes over flags turned on to find this web area (see `WebAccessibility`), to restore them in `endReading`.
    func adoptAppFlags(_ flags: [AXAttribute<Bool>]) {
        enabledAppFlags += flags.filter { !enabledAppFlags.contains($0) }
    }

    /// Chromium (seen in Brave 157) turns `AXEnhancedUserInterface` off again shortly after it becomes the active app,
    /// and with it drops the character layout behind `AXBoundsForRange` (zero-size rects): turn it back on, once a
    /// second while reading. Its layout is back about 2 s later.
    private func watchAppFlags() {
        guard appFlagsWatch == nil, !enabledAppFlags.isEmpty, let pid = try? handle.pid() else { return }
        appFlagsWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let reenabled = WebAccessibility.enable(pid: pid, flags: self.enabledAppFlags)
                if !reenabled.isEmpty { Log.accessibility.debug("web area: app turned off \(reenabled); turned back on") }
            }
        }
    }

    private func restoreAppFlags() {
        appFlagsWatch?.cancel()
        appFlagsWatch = nil
        guard !enabledAppFlags.isEmpty, let pid = try? handle.pid() else { return }
        WebAccessibility.restore(enabledAppFlags, pid: pid)
        Log.accessibility.debug("web area: turned off \(enabledAppFlags) for \(appDomain ?? "unknown app")")
        enabledAppFlags = []
    }

    override func endReading() {
        highlight(nil)
        restoreAppFlags()
    }

    override var fullText: String? {
        if let cachedText { return cachedText }
        guard let start = startMarker, let end = endMarker, let text = string(from: start, to: end) else { return nil }
        cachedText = text
        Task { @MainActor [weak self] in self?.cachedText = nil }
        return text
    }

    override var selectedText: String? {
        guard let text = fullText, let selection else { return nil }
        return String(text[selection.startIndex(in: text)..<selection.endIndex(in: text)])
    }

    override var selection: Selection? {
        get {
            guard let text = fullText else { return nil }
            let reported = report(in: text)
            if var tracked = trackedSelection {
                if let trackedText, trackedText != text {
                    let string = String(trackedText[tracked.startIndex(in: trackedText)..<tracked.endIndex(in: trackedText)])
                    tracked = Self.locate(string, near: tracked.lowerBound, in: text, tolerance: 64)
                    Log.accessibility.debug("web area: page text changed; selection moved to \(tracked)")
                    track(tracked, in: text)
                }
                guard let reported, !isUnchanged(reported, tracked: tracked, in: text) else { return tracked }
                Log.accessibility.debug("web area: browser selection changed to \(reported.selection)")
                highlight(nil)
            }
            if let reported {
                track(reported.selection, in: text)
                baseline = reported
                reportAfterSet = nil
                return reported.selection
            }
            let start = visibleStartOffset(in: text) ?? 0
            Log.accessibility.debug("web area: no selection reported; starting at visible offset \(start)")
            return Selection(start..<start)
        }
        set {
            guard let newValue, let text = fullText else { return }
            if trackedSelection == nil { baseline = report(in: text) }
            track(newValue, in: text)
            if isChromium {
                if canSelectByTextOperation, select(newValue, in: text) {
                    highlight(nil)
                } else {
                    // Chromium ignores `AXSelectedTextMarkerRange` (see the class comment): highlight it instead.
                    _ = leaves(for: text)
                    highlight(newValue.isEmpty ? nil : newValue)
                }
                reportAfterSet = report(in: text)
                return
            }
            guard let range = markerRange(for: newValue, in: text) else {
                Log.accessibility.debug("web area: no markers for \(newValue)")
                return
            }
            do {
                try handle.set(.selectedTextMarkerRange, to: range)
            } catch {
                Log.accessibility.debug("web area: setting selection failed: \(error)")
            }
            reportAfterSet = report(in: text)
        }
    }

    private func track(_ selection: Selection, in text: String) {
        trackedSelection = selection
        trackedText = text
    }

    /// Whether the browser's `reported` selection is still the one from when tracking began, or (an in-between state of)
    /// the tracked one.
    private func isUnchanged(_ reported: Report, tracked: Selection, in text: String) -> Bool {
        if let baseline, reported.matches(baseline) { return true }
        if let reportAfterSet, reported.matches(reportAfterSet) { return true }
        let trackedString = String(text[tracked.startIndex(in: text)..<tracked.endIndex(in: text)])
        if reported.matches(Report(selection: tracked, string: trackedString)) { return true }
        let other = reported.selection
        return other.lowerBound < tracked.upperBound && tracked.lowerBound < other.upperBound
    }

    /// The page selection the browser reports, as offsets in `text`. Measured from its start and the selected string,
    /// not each end: the text before a marker at a node boundary can differ from the full text by a character or two
    /// (e.g. collapsed whitespace).
    private func report(in text: String) -> Report? {
        guard let range = try? handle.attribute(.selectedTextMarkerRange) else { return nil }
        if let lastReport, lastReport.text == text, lastReport.range == range { return lastReport.report }
        guard let start = range.start, let lower = leafOffset(of: start, in: text) ?? offset(of: start, in: text),
            let selected = try? handle.attribute(.stringForTextMarkerRange, for: range)
        else { return nil }
        let report = Report(selection: Self.locate(selected, near: lower, in: text), string: selected)
        lastReport = (range, text, report)
        if isChromium, let leaf = try? handle.attribute(.uiElementForTextMarker, for: start) {
            reportedLeaf = leaf
        }
        return report
    }

    /// Scrolls the selection into view, unless it's already visible. WebKit exposes the page's scroll bars and a
    /// document-sized web area frame, so it scrolls like a text area (selection near the top, smooth if enabled).
    /// Otherwise (Chromium, which has neither and ignores synthesized scroll-wheel events posted to it), the element
    /// holding the selection start is scrolled into view with `AXScrollToVisible` (minimal, instant).
    override func scroll(to selection: Selection, options: ScrollOptions) {
        if isChromium {
            scrollLeaf(to: selection, options: options)
            return
        }
        guard let text = fullText, let start = marker(at: selection.lowerBound, in: text) else { return }
        let bounds = markerRange(for: selection, in: text).flatMap { try? handle.attribute(.boundsForTextMarkerRange, for: $0) }
        if let bounds, bounds.size != .zero, let scroller = pageScroller, let scrollFrame = scroller.frame,
            let pageFrame = try? handle.attribute(.frame), pageFrame.height > scrollFrame.height
        {
            scroller.scroll(to: bounds, contentFrame: pageFrame, options: options)
            return
        }
        if let bounds, let visible = visibleFrame() {
            let padding = min(CGFloat(options.padding), visible.height / 2)
            if bounds.size != .zero, visible.insetBy(dx: 0, dy: padding).contains(bounds) {
                Log.scroll.debug("web area: \(selection) already visible")
                return
            }
        }
        guard let target = try? handle.attribute(.uiElementForTextMarker, for: start) else { return }
        do {
            try target.perform(.scrollToVisible)
            Log.scroll.debug("web area: scrolled element at \(selection.lowerBound) into view")
        } catch {
            Log.scroll.debug("web area: AXScrollToVisible failed: \(error)")
        }
    }

    // MARK: Offsets ↔ markers

    private var startMarker: AXTextMarker? { try? handle.attribute(.startTextMarker) }
    private var endMarker: AXTextMarker? { try? handle.attribute(.endTextMarker) }

    /// UTF-16 offset of `marker` in `text` (the page text): the length of the text before it.
    func offset(of marker: AXTextMarker, in text: String) -> Int? {
        guard let start = startMarker, let before = string(from: start, to: marker) else { return nil }
        // The range is unordered: for a marker before the document start (Safari's skip links) it's the text between
        // them, not a prefix.
        return text.utf16.starts(with: before.utf16) ? before.utf16.count : 0
    }

    /// The marker at UTF-16 `offset` in `text`, or the nearest one when no marker maps to it exactly.
    func marker(at offset: Int, in text: String) -> AXTextMarker? {
        let target = min(max(offset, 0), text.utf16.count)
        if target == 0 { return startMarker }
        if target == text.utf16.count { return endMarker }

        // `AXTextMarkerForIndex` counts differently, but the drift changes slowly: correct the guess by the error.
        var guess = target
        var best: (marker: AXTextMarker, offset: Int)?
        for _ in 0..<4 {
            guard let marker = try? handle.attribute(.textMarkerForIndex, for: guess),
                let found = self.offset(of: marker, in: text)
            else { break }
            if found == target { return marker }
            if best == nil || abs(found - target) < abs(best!.offset - target) { best = (marker, found) }
            guess += target - found
        }
        guard let best else { return nil }

        // Step character by character, measuring only the text stepped over.
        let forward = best.offset < target
        var current = best
        for _ in 0..<64 {
            guard let next = try? handle.attribute(forward ? .nextTextMarkerForTextMarker : .previousTextMarkerForTextMarker, for: current.marker),
                let stepped = string(from: best.marker, to: next)
            else { break }
            let nextOffset = best.offset + (forward ? stepped.utf16.count : -stepped.utf16.count)
            if forward ? nextOffset > target : nextOffset < target { break }
            current = (next, nextOffset)
            if nextOffset == target { break }
        }
        if current.offset != target {
            Log.accessibility.debug("web area: marker for offset \(target) is at \(current.offset)")
        }
        return current.marker
    }

    private func markerRange(for selection: Selection, in text: String) -> AXTextMarkerRange? {
        guard let start = marker(at: selection.lowerBound, in: text) else { return nil }
        let end = selection.isEmpty ? start : marker(at: selection.upperBound, in: text)
        return end.flatMap { range(from: start, to: $0) }
    }

    /// The selection of `string` at `offset` in `text`, or at the nearest occurrence within a few characters (marker
    /// offsets at node boundaries can be off by a collapsed space or so).
    nonisolated static func locate(_ string: String, near offset: Int, in text: String, tolerance: Int = 16) -> Selection {
        let length = string.utf16.count
        let utf16 = text.utf16
        let count = utf16.count
        func matches(at start: Int) -> Bool {
            guard start >= 0, start + length <= count else { return false }
            let from = utf16.index(utf16.startIndex, offsetBy: start)
            return utf16[from...].starts(with: string.utf16)
        }
        guard length > 0, !matches(at: offset) else { return Selection(offset..<min(offset + length, count)) }
        for distance in 1...tolerance {
            for start in [offset - distance, offset + distance] where matches(at: start) {
                return Selection(start..<start + length)
            }
        }
        return Selection(offset..<min(offset + length, count))
    }

    // MARK: Visible area

    /// The on-screen part of the page: browsers report either the whole document (Safari) or the viewport (Chromium)
    /// as the web area's frame, so clip it by its scroll area and window.
    private func visibleFrame() -> CGRect? {
        guard var frame = try? handle.attribute(.frame) else { return nil }
        if let scrollArea = try? handle.parent(with: .scrollArea), let scrollFrame = try? scrollArea.attribute(.frame) {
            frame = frame.intersection(scrollFrame)
        }
        if let window = try? handle.attribute(.window), let windowFrame = try? window.attribute(.frame) {
            frame = frame.intersection(windowFrame)
        }
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    /// Chromium has no `AXStartTextMarkerForBounds` (nor working position hit-testing): it finds its first visible leaf.
    private func visibleStartOffset(in text: String) -> Int? {
        if isChromium {
            guard let visible = visibleFrame(), let leaf = leaves(for: text)?.firstVisible(in: visible) else { return nil }
            return leaf.range.lowerBound
        }
        guard let visible = visibleFrame(), let marker = try? handle.attribute(.startTextMarkerForBounds, for: visible) else {
            return nil
        }
        return offset(of: marker, in: text)
    }

    // MARK: Chromium leaves

    /// Selects `selection` through `AXTextOperation`. Its markers must be anchored on leaves: ones from
    /// `AXTextMarkerForIndex` (anchored on the web area) are accepted but select nothing. Fails for text outside any
    /// leaf (list markers like Wikipedia's "a. " footnote letters).
    private func select(_ selection: Selection, in text: String) -> Bool {
        guard let leaves = leaves(for: text) else { return false }
        var parts = leaves.leaves(in: selection)
        if selection.isEmpty, let leaf = leaves.leaf(containing: selection.lowerBound) {
            parts = [(leaf, selection)]
        }
        // A DOM selection can't start or end in a list marker ("a. ", "• "): Chromium widens it to the whole list.
        while let first = parts.first, isListMarker(first.leaf.element) { parts.removeFirst() }
        while let last = parts.last, isListMarker(last.leaf.element) { parts.removeLast() }
        if parts.isEmpty, !selection.isEmpty, let last = lastLeafMarker {
            _ = textOperationSelect(range(from: last.marker, to: last.marker))
            return false
        }
        guard let first = parts.first, let last = parts.last,
            let start = leafMarker(in: first.leaf, at: first.part.lowerBound, text: text),
            let end = selection.isEmpty ? start : leafMarker(in: last.leaf, at: last.part.upperBound, text: text),
            let range = range(from: start, to: end)
        else {
            Log.accessibility.debug("web area: no leaf markers for \(selection)")
            return false
        }
        // Leaves whose marker range doesn't match their text (list markers) give ranges holding more than the unit:
        // collapse the selection there and let the overlay show this unit.
        let expected = String(text[selection.startIndex(in: text)..<selection.endIndex(in: text)])
        if let selected = try? handle.attribute(.stringForTextMarkerRange, for: range),
            !Self.covers(expected, selected)
        {
            Log.accessibility.debug("web area: markers for \(selection) select other text")
            _ = textOperationSelect(self.range(from: start, to: start))
            return false
        }
        return textOperationSelect(range)
    }

    private func isListMarker(_ element: AXElement) -> Bool {
        (try? element.role()) == .listMarker
    }

    /// Whether `selected` is (most of) `expected`, ignoring surrounding whitespace: marker ranges can miss text outside
    /// leaves (Wikipedia's "^" back links), never add any.
    nonisolated static func covers(_ expected: String, _ selected: String) -> Bool {
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected == expected || (!selected.isEmpty && expected.contains(selected))
    }

    private func textOperationSelect(_ range: AXTextMarkerRange?) -> Bool {
        guard let range else { return false }
        do {
            guard try handle.attribute(.textOperation, for: .select(range)) != nil else {
                Log.accessibility.debug("web area: AXTextOperation unsupported or no result")
                return false
            }
            return true
        } catch {
            Log.accessibility.debug("web area: AXTextOperation failed: \(error)")
            return false
        }
    }

    /// A leaf's own marker range and where its page text starts in that range's string: the range can hold whitespace
    /// that the page text collapses (Gutenberg: a leading line break).
    private func markers(of leaf: AXElement, pageText: String) -> (start: AXTextMarker, end: AXTextMarker, length: Int, shift: Int)? {
        guard let leafRange = try? handle.attribute(.textMarkerRangeForUIElement, for: leaf),
            let start = leafRange.start, let end = leafRange.end,
            let string = try? handle.attribute(.stringForTextMarkerRange, for: leafRange)
        else { return nil }
        let location = (string as NSString).range(of: pageText).location
        return (start, end, string.utf16.count, location == NSNotFound ? 0 : location)
    }

    /// A marker anchored on `leaf` at page text `offset`. Leaf markers can only be made by stepping from the leaf's
    /// start or end, or the last one made (0.1 ms per step).
    private func leafMarker(in leaf: PageLeaves.Leaf, at offset: Int, text: String) -> AXTextMarker? {
        let pageText = String(text[leaf.range.startIndex(in: text)..<leaf.range.endIndex(in: text)])
        guard let (leafStart, leafEnd, length, shift) = markers(of: leaf.element, pageText: pageText) else { return nil }
        let local = min(max(offset - leaf.range.lowerBound + shift, 0), length)
        var anchors: [(local: Int, marker: AXTextMarker)] = [(0, leafStart), (length, leafEnd)]
        if let last = lastLeafMarker, last.element == leaf.element { anchors.append((last.local, last.marker)) }
        var (position, marker) = anchors.min { abs($0.local - local) < abs($1.local - local) }!
        // Steps are characters, not UTF-16 units (emoji): measure and correct.
        for _ in 0..<6 where position != local {
            let forward = position < local
            for _ in 0..<abs(local - position) {
                guard let next = try? handle.attribute(forward ? .nextTextMarkerForTextMarker : .previousTextMarkerForTextMarker, for: marker)
                else { return nil }
                marker = next
            }
            guard let measured = string(from: leafStart, to: marker)?.utf16.count else { return nil }
            position = measured
        }
        if position != local {
            Log.accessibility.debug("web area: leaf marker for \(offset) is at \(leaf.range.lowerBound + position - shift)")
        }
        lastLeafMarker = (leaf.element, position, marker)
        return marker
    }

    /// The offset of a marker anchored on a leaf (as in the browser's selection), measured from the leaf's start: much
    /// faster than `offset(of:in:)` far down a page. Only while the leaves are known (set up when EasyReader selects).
    private func leafOffset(of marker: AXTextMarker, in text: String) -> Int? {
        guard isChromium, let leaves = pageLeaves, leaves.text == text,
            let element = try? handle.attribute(.uiElementForTextMarker, for: marker),
            let index = leaves.index(of: element), let leaf = leaves.leaf(at: index), !leaf.range.isEmpty,
            let leafMarkers = markers(
                of: leaf.element, pageText: String(text[leaf.range.startIndex(in: text)..<leaf.range.endIndex(in: text)])),
            let before = string(from: leafMarkers.start, to: marker)
        else { return nil }
        return leaf.range.lowerBound + max(0, before.utf16.count - leafMarkers.shift)
    }

    private func leaves(for text: String) -> PageLeaves? {
        if let pageLeaves, pageLeaves.text == text { return pageLeaves }
        let hint = pageLeaves?.cursorElement ?? reportedLeaf
        pageLeaves = PageLeaves(webArea: handle, text: text) { [weak self] element in
            guard let self, let range = try? self.handle.attribute(.textMarkerRangeForUIElement, for: element),
                let start = range.start
            else { return nil }
            return self.offset(of: start, in: text)
        }
        if let hint { pageLeaves?.moveCursor(to: hint) }
        Log.accessibility.debug("web area: \(pageLeaves?.count ?? 0) page text leaves")
        return pageLeaves
    }

    /// The paragraph (Chromium's: block boundaries) holding `offset`, as Chromium's page text has no line breaks
    /// between blocks.
    ///
    /// Paragraph ranges are only right for markers anchored on the web area (from `AXTextMarkerForIndex`); for leaf
    /// markers they end at the leaf. Chromium's index drifts slowly from text offsets (by hundreds on a long page) but
    /// round-trips exactly, so the paragraph is found by its text near the index plus the drift learned last time.
    override func textBlock(containing offset: Int) -> Selection? {
        guard isChromium, let text = fullText else { return nil }
        var guess = offset - indexDrift
        for _ in 0..<8 {
            guard let marker = try? handle.attribute(.textMarkerForIndex, for: max(0, guess)),
                let paragraph = try? handle.attribute(.paragraphTextMarkerRangeForTextMarker, for: marker),
                let string = try? handle.attribute(.stringForTextMarkerRange, for: paragraph), !string.isEmpty,
                let start = paragraph.start,
                let index = try? handle.attribute(.indexForTextMarker, for: start),
                let found = Self.nearestOccurrence(of: string, to: index + indexDrift, in: text)
            else { return nil }
            indexDrift = found - index
            let block = Selection(found..<found + string.utf16.count)
            if block.lowerBound <= offset, offset < block.upperBound { return block }
            // A neighboring paragraph: correct the guess by the new drift, or step over it.
            let corrected = offset - indexDrift
            guess = corrected != guess ? corrected : (offset < block.lowerBound ? index - 1 : index + string.utf16.count)
        }
        Log.accessibility.debug("web area: no paragraph found at \(offset)")
        return nil
    }

    /// Chromium's text offset minus its `AXIndexForTextMarker` index, near the last paragraph found.
    private var indexDrift = 0

    /// The occurrence of `string` in `text` starting closest to UTF-16 offset `expected`, within a few thousand characters.
    nonisolated static func nearestOccurrence(of string: String, to expected: Int, in text: String, within distance: Int = 4000) -> Int? {
        let text = text as NSString
        let expected = min(max(expected, 0), text.length)
        let lower = max(0, expected - distance)
        let upper = min(text.length, expected + distance + string.utf16.count)
        let after = text.range(of: string, options: .literal, range: NSRange(location: expected, length: upper - expected))
        let before = text.range(
            of: string, options: [.literal, .backwards], range: NSRange(location: lower, length: min(expected + string.utf16.count, upper) - lower))
        let candidates = [after, before].filter { $0.location != NSNotFound }.map(\.location)
        return candidates.min { abs($0 - expected) < abs($1 - expected) }
    }

    /// What the overlay highlights (Chromium), while the browser is frontmost.
    private(set) var highlighted: Selection?

    private func highlight(_ selection: Selection?) {
        highlighted = selection
        guard let selection else {
            overlay.hide()
            return
        }
        overlay.show { [weak self] in
            guard let self, self.app?.isActive != false else { return nil }
            return self.highlightRects(for: selection)
        }
    }

    /// Screen rects (top-left origin) of the visible part of `selection`, one per line and leaf. Uses the leaves from
    /// when the selection was set if there are any: the overlay asks a few times a second, and fetching the page text
    /// can take 100 ms.
    func highlightRects(for selection: Selection) -> [CGRect]? {
        guard let leaves = pageLeaves ?? fullText.flatMap({ leaves(for: $0) }), let visible = visibleFrame() else { return nil }
        return leaves.leaves(in: selection).flatMap { leaf, part -> [CGRect] in
            let shift = leaf.valueOffset - leaf.range.lowerBound
            let local = Selection(part.lowerBound + shift..<part.upperBound + shift)
            let lines = lineRects(of: leaf.element, local)
            // Some leaves have no character bounds (or none yet: see `watchAppFlags`): use the whole leaf.
            return lines.isEmpty ? frame(of: leaf.element).map { [$0] } ?? [] : lines
        }
        .map { $0.intersection(visible) }
        .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
    }

    private func frame(of element: AXElement) -> CGRect? {
        try? element.attribute(.frame)
    }

    /// Bounds of `range` (UTF-16 offsets in the leaf's text), one rect per line: Chromium reports the union of all lines.
    private func lineRects(of leaf: AXElement, _ range: Selection) -> [CGRect] {
        func bounds(_ lower: Int, _ upper: Int) -> CGRect? {
            guard let rect = try? leaf.attribute(.boundsForRange, for: CFRange(location: lower, length: upper - lower)),
                // Zero-size at the web area's origin while Chromium has no character layout (see `watchAppFlags`).
                rect.width >= 1 || rect.height >= 1
            else { return nil }
            return rect
        }
        var rects: [CGRect] = []
        var lower = range.lowerBound
        while lower < range.upperBound, rects.count < 50 {
            guard let first = bounds(lower, lower + 1), let whole = bounds(lower, range.upperBound) else { break }
            // On one line?
            if whole.height < first.height * 1.5 {
                rects.append(whole)
                break
            }
            // Binary search for the first character below this line.
            var low = lower + 1
            var high = range.upperBound
            while low < high {
                let middle = (low + high) / 2
                if let rect = bounds(middle, middle + 1), rect.height >= 1, rect.midY <= first.maxY {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if let line = bounds(lower, low) { rects.append(line) }
            lower = low
        }
        return rects
    }

    private func scrollLeaf(to selection: Selection, options: ScrollOptions) {
        guard let text = fullText, let leaves = leaves(for: text), let (leaf, part) = leaves.leaves(in: selection).first else { return }
        let shift = leaf.valueOffset - leaf.range.lowerBound
        let local = Selection(part.lowerBound + shift..<part.upperBound + shift)
        // Character bounds aren't clipped to the viewport, but leaf frames are (zero height outside it).
        if let leafFrame = frame(of: leaf.element), leafFrame.height >= 1, let first = lineRects(of: leaf.element, local).first,
            let visible = visibleFrame()
        {
            let padding = min(CGFloat(options.padding), visible.height / 4)
            if first.height >= 1, visible.insetBy(dx: 0, dy: padding).contains(first) {
                Log.scroll.debug("web area: \(selection) already visible")
                return
            }
        }
        do {
            try leaf.element.perform(.scrollToVisible)
            Log.scroll.debug("web area: scrolled leaf at \(leaf.range.lowerBound) into view")
        } catch {
            Log.scroll.debug("web area: AXScrollToVisible on leaf at \(leaf.range.lowerBound) failed: \(error)")
        }
    }

    // MARK: Markers

    private func range(from start: AXTextMarker, to end: AXTextMarker) -> AXTextMarkerRange? {
        try? handle.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [start, end])
    }

    private func string(from start: AXTextMarker, to end: AXTextMarker) -> String? {
        range(from: start, to: end).flatMap { try? handle.attribute(.stringForTextMarkerRange, for: $0) }
    }
}

/// The app-wide AX flags that make Chromium (`AXEnhancedUserInterface`, what VoiceOver sets) and Electron
/// (`AXManualAccessibility`) build their full AX tree. Until then a Chromium app vends no page content at all (no web
/// area), so `EasyReader` turns them on when it finds nothing to read in one (`isChromium`).
@MainActor
enum WebAccessibility {
    private static let flags: [AXAttribute<Bool>] = [.manualAccessibility, .enhancedUserInterface]

    /// Turns on the flags (default: all) that are off; returns those it turned on.
    static func enable(pid: pid_t, flags: [AXAttribute<Bool>] = flags) -> [AXAttribute<Bool>] {
        let app = AXElement.application(pid: pid)
        var enabled: [AXAttribute<Bool>] = []
        for flag in flags {
            if (try? app.attribute(flag)) == true { continue }
            // Chromium reports failure for `AXEnhancedUserInterface` but applies it: check by reading it back.
            try? app.set(flag, to: true)
            if (try? app.attribute(flag)) == true { enabled.append(flag) }
        }
        return enabled
    }

    static func restore(_ flags: [AXAttribute<Bool>], pid: pid_t) {
        let app = AXElement.application(pid: pid)
        for flag in flags {
            try? app.set(flag, to: false)
        }
    }

    /// Chromium-based browsers and Electron apps, by their bundle: Electron's framework is "Electron Framework";
    /// Chromium's framework has `Helpers/app_mode_loader` (browsers' web-app shim) or `chrome_crashpad_handler`.
    /// (Just having a `Helpers` folder isn't enough: WebKit's JavaScriptCore has one, e.g. in Orion.)
    nonisolated static func isChromium(_ app: NSRunningApplication) -> Bool {
        app.bundleURL.map { isChromium(bundleURL: $0) } ?? false
    }

    nonisolated static func isChromium(bundleURL: URL) -> Bool {
        frameworks(of: bundleURL).contains { framework in
            framework.lastPathComponent == "Electron Framework.framework"
                || hasHelper("app_mode_loader", in: framework) || hasHelper("chrome_crashpad_handler", in: framework)
        }
    }

    private nonisolated static func frameworks(of bundleURL: URL) -> [URL] {
        let folder = bundleURL.appendingPathComponent("Contents/Frameworks")
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "framework" }
    }

    private nonisolated static func hasHelper(_ name: String, in framework: URL) -> Bool {
        FileManager.default.fileExists(atPath: framework.appendingPathComponent("Versions/Current/Helpers/\(name)").path)
    }
}
