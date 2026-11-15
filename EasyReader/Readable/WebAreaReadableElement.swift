import Cocoa

/// A web page (Safari/WebKit, Chromium, Firefox), read through AX text markers.
final class WebAreaReadableElement: ReadableElement {
    // Browsers' selection reports can't be read back (Chromium ignores sets, Safari lags): track it ourselves.
    private var trackedSelection: Selection?
    private var trackedText: String?
    // Reports that aren't a user selection: the one when tracking began and the one right after our last set.
    private var baseline: Report?
    private var reportAfterSet: Report?

    struct Report {
        let selection: Selection
        let string: String

        func matches(_ other: Report, tolerance: Int = 64) -> Bool {
            string == other.string && abs(selection.lowerBound - other.selection.lowerBound) <= tolerance
        }
    }

    // Only for the current main-actor turn: read several times per unit, but the page may change between units.
    private var cachedText: String?

    /// App-wide AX flags this readable turned on, restored by `endReading`.
    private var enabledAppFlags: [AXAttribute<Bool>] = []
    private var appFlagsWatch: Task<Void, Never>?

    private lazy var isChromium = handle.attributeNames.contains("ChromeAXNodeId")
    // WebKit only: Chromium exposes no scroll bars.
    private lazy var pageScroller: ScrollBarScroller? = {
        guard let scrollArea = try? handle.parent(with: .scrollArea) else { return nil }
        let scroller = ScrollBarScroller(scrollArea)
        return scroller.hasVerticalScrollBar ? scroller : nil
    }()
    /// Chromium with chrome://flags/#enable-accessibility-text-operation.
    private(set) lazy var canSelectByTextOperation =
        isChromium && handle.parameterizedAttributeNames.contains(AXParameterizedAttribute<AXTextOperation, AXAnyValue>.textOperation.name)
    // To step from: the next unit usually starts where the last one ended.
    private var lastLeafMarker: (element: AXElement, local: Int, marker: AXTextMarker)?
    private(set) var pageLeaves: PageLeaves?
    private lazy var overlay = HighlightOverlay()
    /// What the overlay highlights (Chromium), while the browser is frontmost.
    private(set) var highlighted: Selection?
    // Measuring a report costs O(offset): reuse it while range and text are unchanged.
    private var lastReport: (range: AXTextMarkerRange, text: String, report: Report)?
    // Chromium: where `PageLeaves` lookups start.
    private var reportedLeaf: AXElement?
    /// Chromium's text offset minus its `AXIndexForTextMarker` index, near the last paragraph found.
    private var indexDrift = 0

    // Chromium/Electron build their full AX tree only for assistive apps. The flags can affect window animations,
    // hence only while reading.
    override func beginReading() {
        if enabledAppFlags.isEmpty, let pid = try? handle.pid(), pid != getpid() {
            enabledAppFlags = AppAccessibility.enable(pid: pid)
            Log.accessibility.debug("web area: turned on \(enabledAppFlags) for \(appDomain ?? "unknown app")")
        }
        watchAppFlags()
    }

    /// Takes over flags turned on to find this web area, to restore them in `endReading`.
    func adoptAppFlags(_ flags: [AXAttribute<Bool>]) {
        enabledAppFlags += flags.filter { !enabledAppFlags.contains($0) }
    }

    // Brave turns `AXEnhancedUserInterface` back off once it's active (dropping its character bounds)
    private func watchAppFlags() {
        guard appFlagsWatch == nil, !enabledAppFlags.isEmpty, let pid = try? handle.pid() else { return }
        appFlagsWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let reenabled = AppAccessibility.enable(pid: pid, flags: enabledAppFlags, unreadable: false)
                if !reenabled.isEmpty { Log.accessibility.debug("web area: app turned off \(reenabled); turned back on") }
            }
        }
    }

    private func restoreAppFlags() {
        appFlagsWatch?.cancel()
        appFlagsWatch = nil
        guard !enabledAppFlags.isEmpty, let pid = try? handle.pid() else { return }
        AppAccessibility.restore(enabledAppFlags, pid: pid)
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
        return substring(selection, of: text)
    }

    override var selection: Selection? {
        get {
            guard let text = fullText else { return nil }
            let reported = report(in: text)
            if var tracked = trackedSelection {
                if let trackedText, trackedText != text {
                    tracked = Self.locate(substring(tracked, of: trackedText), near: tracked.lowerBound, in: text, tolerance: 64)
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
                    // Chromium ignores `AXSelectedTextMarkerRange` on page text
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

    /// Whether `reported` isn't a selection by the user.
    private func isUnchanged(_ reported: Report, tracked: Selection, in text: String) -> Bool {
        let known = [baseline, reportAfterSet].compactMap { $0 }
        return Self.isUnchanged(reported, known: known, tracked: Report(selection: tracked, string: substring(tracked, of: text)))
    }

    /// A known report or the tracked unit (same text within 64 chars), or overlapping the unit.
    nonisolated static func isUnchanged(_ reported: Report, known: [Report], tracked: Report) -> Bool {
        if known.contains(where: { reported.matches($0) }) || reported.matches(tracked) { return true }
        let other = reported.selection
        return other.lowerBound < tracked.selection.upperBound && tracked.selection.lowerBound < other.upperBound
    }

    // Located by start + selected string: offsets at node boundaries can be off by a collapsed space.
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

    override func scroll(to selection: Selection, options: ScrollOptions) {
        if isChromium {
            scrollLeaf(to: selection, options: options)
            return
        }
        guard let text = fullText, let start = marker(at: selection.lowerBound, in: text) else { return }
        let bounds = markerRange(for: selection, in: text).flatMap { try? handle.attribute(.boundsForTextMarkerRange, for: $0) }
        // WebKit: scroll bars and a document-sized frame, so scroll like a text area
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

    /// The UTF-16 length of the page text before `marker`.
    func offset(of marker: AXTextMarker, in text: String) -> Int? {
        guard let start = startMarker, let before = string(from: start, to: marker) else { return nil }
        // Markers before the document start (Safari's skip links) give the text between them, not a prefix
        return text.utf16.starts(with: before.utf16) ? before.utf16.count : 0
    }

    /// The marker at UTF-16 `offset` in `text`, or the nearest one when no marker maps to it exactly.
    func marker(at offset: Int, in text: String) -> AXTextMarker? {
        let target = min(max(offset, 0), text.utf16.count)
        if target == 0 { return startMarker }
        if target == text.utf16.count { return endMarker }

        // `AXTextMarkerForIndex` drifts from offsets, but slowly: correct the guess by the error
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

        // Measure only the text stepped over
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

    /// `string` at `offset` in `text`, or at the nearest occurrence within `tolerance`.
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

    // The web area's frame is the whole document (Safari) or the viewport (Chromium)
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

    // Chromium has no `AXStartTextMarkerForBounds`
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

    // `AXTextOperation` selects nothing with web-area-anchored markers: they must be leaf-anchored
    private func select(_ selection: Selection, in text: String) -> Bool {
        guard let leaves = leaves(for: text) else { return false }
        var parts = leaves.leaves(in: selection)
        if selection.isEmpty, let leaf = leaves.leaf(containing: selection.lowerBound) {
            parts = [(leaf, selection)]
        }
        // A DOM selection ending in a list marker ("a. ", "• ") widens to the whole list
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
        // Selects more than the unit (list markers): collapse it and let the overlay show the unit
        if let selected = try? handle.attribute(.stringForTextMarkerRange, for: range),
            !Self.covers(substring(selection, of: text), selected)
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

    // Marker ranges can miss text outside leaves (Wikipedia's "^" back links), never add any
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

    // `shift`: where `pageText` starts in the leaf's range string, which can hold collapsed whitespace (Gutenberg)
    private func markers(of leaf: AXElement, pageText: String) -> (start: AXTextMarker, end: AXTextMarker, length: Int, shift: Int)? {
        guard let leafRange = try? handle.attribute(.textMarkerRangeForUIElement, for: leaf),
            let start = leafRange.start, let end = leafRange.end,
            let string = try? handle.attribute(.stringForTextMarkerRange, for: leafRange)
        else { return nil }
        let location = (string as NSString).range(of: pageText).location
        return (start, end, string.utf16.count, location == NSNotFound ? 0 : location)
    }

    // Leaf-anchored markers can only be made by stepping from another one
    private func leafMarker(in leaf: PageLeaves.Leaf, at offset: Int, text: String) -> AXTextMarker? {
        guard let (leafStart, leafEnd, length, shift) = markers(of: leaf.element, pageText: substring(leaf.range, of: text)) else {
            return nil
        }
        let local = min(max(offset - leaf.range.lowerBound + shift, 0), length)
        var anchors: [(local: Int, marker: AXTextMarker)] = [(0, leafStart), (length, leafEnd)]
        if let last = lastLeafMarker, last.element == leaf.element { anchors.append((last.local, last.marker)) }
        var (position, marker) = anchors.min { abs($0.local - local) < abs($1.local - local) }!
        // Steps are characters, not UTF-16 units: measure and correct
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

    // Measured from the leaf: much faster than `offset(of:in:)` far down a page
    private func leafOffset(of marker: AXTextMarker, in text: String) -> Int? {
        guard isChromium, let leaves = pageLeaves, leaves.text == text,
            let element = try? handle.attribute(.uiElementForTextMarker, for: marker),
            let index = leaves.index(of: element), let leaf = leaves.leaf(at: index), !leaf.range.isEmpty,
            let leafMarkers = markers(of: leaf.element, pageText: substring(leaf.range, of: text)),
            let before = string(from: leafMarkers.start, to: marker)
        else { return nil }
        return leaf.range.lowerBound + max(0, before.utf16.count - leafMarkers.shift)
    }

    private func leaves(for text: String) -> PageLeaves? {
        if let pageLeaves, pageLeaves.text == text { return pageLeaves }
        let hint = pageLeaves?.cursorElement ?? reportedLeaf
        pageLeaves = PageLeaves(webArea: handle, text: text) { [weak self] element in
            guard let self, let range = try? handle.attribute(.textMarkerRangeForUIElement, for: element),
                let start = range.start
            else { return nil }
            return offset(of: start, in: text)
        }
        if let hint { pageLeaves?.moveCursor(to: hint) }
        Log.accessibility.debug("web area: \(pageLeaves?.count ?? 0) page text leaves")
        return pageLeaves
    }

    // Needs web-area-anchored markers (leaf ones stop at the leaf); located by text near index + learned drift
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
            // Got a neighbor: correct the guess by the new drift, or step over it
            let corrected = offset - indexDrift
            guess = corrected != guess ? corrected : (offset < block.lowerBound ? index - 1 : index + string.utf16.count)
        }
        Log.accessibility.debug("web area: no paragraph found at \(offset)")
        return nil
    }

    /// The occurrence of `string` in `text` starting closest to `expected`, within `distance`.
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

    private func highlight(_ selection: Selection?) {
        highlighted = selection
        guard let selection else {
            overlay.hide()
            return
        }
        overlay.show { [weak self] in
            guard let self, app?.isActive != false else { return nil }
            return highlightRects(for: selection)
        }
    }

    /// Screen rects (top-left origin), one per line and leaf, of the visible part of `selection`.
    // Reuses the leaves from the last set: the overlay polls 4×/s and fetching the page text can take 100 ms.
    func highlightRects(for selection: Selection) -> [CGRect]? {
        guard let leaves = pageLeaves ?? fullText.flatMap({ leaves(for: $0) }), let visible = visibleFrame() else { return nil }
        return leaves.leaves(in: selection).flatMap { leaf, part -> [CGRect] in
            let lines = HighlightOverlay.lineRects(of: leaf.element, valueRange(of: part, in: leaf))
            // Some leaves have no character bounds (or none yet: see `watchAppFlags`)
            return lines.isEmpty ? (try? leaf.element.attribute(.frame)).map { [$0] } ?? [] : lines
        }
        .map { $0.intersection(visible) }
        .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
    }

    private func scrollLeaf(to selection: Selection, options: ScrollOptions) {
        guard let text = fullText, let leaves = leaves(for: text), let (leaf, part) = leaves.leaves(in: selection).first else { return }
        let local = valueRange(of: part, in: leaf)
        // Leaf frames are clipped to the viewport (zero height outside), character bounds aren't
        if let leafFrame = try? leaf.element.attribute(.frame), leafFrame.height >= 1, let first = HighlightOverlay.lineRects(of: leaf.element, local).first,
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

    /// `part` (page text offsets) as offsets in the leaf's `AXValue`.
    private func valueRange(of part: Selection, in leaf: PageLeaves.Leaf) -> Selection {
        let shift = leaf.valueOffset - leaf.range.lowerBound
        return Selection(part.lowerBound + shift..<part.upperBound + shift)
    }

    // MARK: Markers

    private func range(from start: AXTextMarker, to end: AXTextMarker) -> AXTextMarkerRange? {
        try? handle.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [start, end])
    }

    private func string(from start: AXTextMarker, to end: AXTextMarker) -> String? {
        range(from: start, to: end).flatMap { try? handle.attribute(.stringForTextMarkerRange, for: $0) }
    }
}

private func substring(_ selection: Selection, of text: String) -> String {
    String(text[selection.startIndex(in: text)..<selection.endIndex(in: text)])
}
