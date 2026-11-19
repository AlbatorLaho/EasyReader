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
    private var cachedContent: (text: String, range: Range<Int>?)?
    private var cachedLastIndex: (text: String, index: Int)?

    /// App-wide AX flags this readable turned on, restored by `endReading`.
    private var enabledAppFlags: [AXAttribute<Bool>] = []
    private var appFlagsWatch: Task<Void, Never>?

    private lazy var isChromium = handle.attributeNames.contains("ChromeAXNodeId")
    private lazy var scrollArea = try? handle.parent(with: .scrollArea)
    private lazy var window = try? handle.attribute(.window)
    // WebKit only: Chromium exposes no scroll bars.
    private lazy var pageScroller: ScrollBarScroller? = {
        guard let scrollArea else { return nil }
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
    /// The text offset minus the `AXIndexForTextMarker` index near the last paragraph (Chromium) or marker found.
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
        appFlagsWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(seconds: 1)
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
        Task { [weak self] in self?.cachedText = nil }
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
            let start = max(visibleStartOffset(in: text) ?? 0, content(in: text)?.lowerBound ?? 0)
            Log.accessibility.debug("web area: no selection reported; starting at offset \(start)")
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
        guard let start = range.start else { return nil }
        let leaf = isChromium ? try? handle.attribute(.uiElementForTextMarker, for: start) : nil
        guard let lower = leafOffset(of: start, in: leaf, text: text) ?? offset(of: start, in: text, near: trackedSelection?.lowerBound),
            let selected = try? handle.attribute(.stringForTextMarkerRange, for: range)
        else { return nil }
        let report = Report(selection: Self.locate(selected, near: lower, in: text), string: selected)
        lastReport = (range, text, report)
        if let leaf { reportedLeaf = leaf }
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

    /// The UTF-16 length of the page text before `marker`; `near`: where it likely is. `strict`: nil instead of 0 when
    /// the text before it isn't a prefix of `text`.
    func offset(of marker: AXTextMarker, in text: String, near hint: Int? = nil, strict: Bool = false) -> Int? {
        let anchors = anchors(for: text)
        if let exact = anchors.first(where: { $0.marker == marker }) { return exact.offset }
        let nearest = hint.flatMap { hint in anchors.min { abs($0.offset - hint) < abs($1.offset - hint) } } ?? anchors.last
        if let nearest, let between = string(from: nearest.marker, to: marker),
            let found = Self.offset(of: between, beside: nearest.offset, in: text, near: hint ?? nearest.offset)
        {
            remember(marker, at: found, in: text)
            return found
        }
        guard let start = startMarker, let before = string(from: start, to: marker) else { return nil }
        // Markers before the document start (Safari's skip links) give the text between them, not a prefix
        guard text.utf16.starts(with: before.utf16) else { return strict ? nil : 0 }
        remember(marker, at: before.utf16.count, in: text)
        return before.utf16.count
    }

    /// The marker at UTF-16 `offset` in `text`, or the nearest one when no marker maps to it exactly.
    func marker(at offset: Int, in text: String) -> AXTextMarker? {
        let target = offset.clamped(to: 0...text.utf16.count)
        if target == 0 { return startMarker }
        if target == text.utf16.count { return endMarker }
        if let nearest = anchors(for: text).min(by: { abs($0.offset - target) < abs($1.offset - target) }) {
            if nearest.offset == target { return nearest.marker }
            if abs(nearest.offset - target) <= Self.maxSteps, let marker = step(from: nearest, to: target, in: text) { return marker }
        }

        // `AXTextMarkerForIndex` drifts from offsets, but slowly: correct the guess by the error
        var guess = target - indexDrift
        let lastIndex = lastIndex(in: text)
        var best: Anchor?
        var tried: Int?
        for _ in 0..<4 {
            let index = min(max(0, guess), lastIndex)
            guard index != tried, let marker = indexMarker(index) else { break }
            tried = index
            // Some can't be measured (ranges to them hold other text): try a neighbor
            guard let found = self.offset(of: marker, in: text, near: target, strict: true) else {
                guess = index + 16
                continue
            }
            indexDrift = found - index
            if found == target { return marker }
            if best.map({ abs(found - target) < abs($0.offset - target) }) ?? true { best = Anchor(offset: found, marker: marker) }
            guess += target - found
        }
        guard let best else { return nil }
        guard abs(best.offset - target) <= 8 * Self.maxSteps else {
            Log.accessibility.debug("web area: marker for offset \(target) is at \(best.offset)")
            return best.marker
        }
        return step(from: best, to: target, in: text) ?? best.marker
    }

    // Indices run behind offsets; past the last one, markers are the page start or end
    private func lastIndex(in text: String) -> Int {
        if let cachedLastIndex, cachedLastIndex.text == text { return cachedLastIndex.index }
        let index = endMarker.flatMap { try? handle.attribute(.indexForTextMarker, for: $0) } ?? Int.max
        cachedLastIndex = (text, index)
        return index
    }

    // Index markers can sit in collapsed whitespace, where ranges to them hold the wrong text: step out and back
    private func indexMarker(_ index: Int) -> AXTextMarker? {
        guard let marker = try? handle.attribute(.textMarkerForIndex, for: index) else { return nil }
        return (try? handle.attribute(.nextTextMarkerForTextMarker, for: marker))
            .flatMap { try? handle.attribute(.previousTextMarkerForTextMarker, for: $0) } ?? marker
    }

    // MARK: Anchors

    /// A marker whose offset was measured.
    private struct Anchor {
        let offset: Int
        let marker: AXTextMarker
    }

    // Measuring from the page start costs O(offset) (150 ms at the end of Wikipedia), from a nearby anchor O(distance)
    private var anchorList: (text: String, anchors: [Anchor])?
    private static let maxAnchors = 64
    /// Stepping a character costs ~0.1 ms; `AXTextMarkerForIndex` alone ~50 ms on a long page.
    private static let maxSteps = 600

    // Chromium has its own paths (leaves), with markers anchored on different elements
    private func anchors(for text: String) -> [Anchor] {
        guard !isChromium else { return [] }
        if let anchorList, anchorList.text == text { return anchorList.anchors }
        let anchors = startMarker.map { [Anchor(offset: 0, marker: $0)] } ?? []
        anchorList = (text, anchors)
        return anchors
    }

    private func remember(_ marker: AXTextMarker, at offset: Int, in text: String) {
        guard !isChromium else { return }
        var anchors = anchors(for: text).filter { $0.offset != offset }
        anchors.append(Anchor(offset: offset, marker: marker))
        if anchors.count > Self.maxAnchors { anchors.remove(at: 1) }
        anchorList = (text, anchors)
    }

    /// Where a marker is whose text to an anchor at `anchor` is `between`: right after or before it (closer to `hint` if both).
    nonisolated static func offset(of between: String, beside anchor: Int, in text: String, near hint: Int) -> Int? {
        let length = between.utf16.count
        guard length > 0 else { return anchor }
        let utf16 = text.utf16
        func matches(at start: Int) -> Bool {
            guard start >= 0, start + length <= utf16.count else { return false }
            return utf16[utf16.index(utf16.startIndex, offsetBy: start)...].starts(with: between.utf16)
        }
        return [anchor + length, anchor - length].filter { matches(at: min($0, anchor)) }.min { abs($0 - hint) < abs($1 - hint) }
    }

    // Steps are characters, not UTF-16 units: jump, then walk one character at a time once past `target`
    private func step(from anchor: Anchor, to target: Int, in text: String) -> AXTextMarker? {
        var current = anchor
        var best = anchor
        var count = abs(target - anchor.offset)
        for _ in 0..<8 where current.offset != target {
            let forward = current.offset < target
            guard let marker = stepped(current.marker, by: count, forward: forward),
                let between = string(from: anchor.marker, to: marker),
                let found = Self.offset(of: between, beside: anchor.offset, in: text, near: target)
            else { return nil }
            if found == current.offset { break }
            let crossed = forward ? found > target : found < target
            current = Anchor(offset: found, marker: marker)
            remember(marker, at: found, in: text)
            if abs(found - target) < abs(best.offset - target) { best = current }
            // No marker at `target` (inside a character or collapsed whitespace)
            if crossed, count == 1 { break }
            count = crossed ? 1 : abs(target - found)
        }
        if best.offset != target {
            Log.accessibility.debug("web area: marker for offset \(target) is at \(best.offset)")
        }
        return best.marker
    }

    /// `count` character steps from `marker`; nil if one fails.
    private func stepped(_ marker: AXTextMarker, by count: Int, forward: Bool) -> AXTextMarker? {
        var marker = marker
        for _ in 0..<count {
            guard let next = try? handle.attribute(forward ? .nextTextMarkerForTextMarker : .previousTextMarkerForTextMarker, for: marker) else {
                return nil
            }
            marker = next
        }
        return marker
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
        let offset = offset.clamped(to: 0...count)
        func matches(at start: Int) -> Bool {
            guard start >= 0, start + length <= count else { return false }
            let from = utf16.index(utf16.startIndex, offsetBy: start)
            return utf16[from...].starts(with: string.utf16)
        }
        guard length > 0, !matches(at: offset) else { return Selection(offset..<min(offset + length, count)) }
        for distance in stride(from: 1, through: tolerance, by: 1) {
            for start in [offset - distance, offset + distance] where matches(at: start) {
                return Selection(start..<start + length)
            }
        }
        return Selection(offset..<min(offset + length, count))
    }

    // MARK: Main content

    override var contentStart: Int { fullText.flatMap { content(in: $0)?.lowerBound } ?? 0 }
    override var contentEnd: Int? { fullText.flatMap { content(in: $0)?.upperBound } }

    /// The text of `<main>`, else of the first `<article>`; nil if the page has neither.
    private func content(in text: String) -> Range<Int>? {
        if let cachedContent, cachedContent.text == text { return cachedContent.range }
        // Chromium: from the leaves where possible (measuring from the page start costs O(offset))
        if isChromium { _ = leaves(for: text) }
        func measure(_ marker: AXTextMarker) -> Int? {
            leafOffset(of: marker, text: text) ?? offset(of: marker, in: text)
        }
        let found = contentElement().flatMap { element -> Range<Int>? in
            guard let range = try? handle.attribute(.textMarkerRangeForUIElement, for: element),
                let start = range.start.flatMap(measure),
                let end = range.end.flatMap(measure), start <= end
            else { return nil }
            return start..<end
        }
        Log.accessibility.debug("web area: main content at \(found.map { "\($0)" } ?? "none")")
        cachedContent = (text, found)
        return found
    }

    private func contentElement() -> AXElement? {
        func elements(_ predicate: AXSearchPredicate) -> [AXElement] {
            ((try? handle.attribute(.uiElementsForSearchPredicate, for: predicate)) ?? []).compactMap(\.element)
        }
        return elements(.landmark).lazy.filter { (try? $0.attribute(.subrole)) == "AXLandmarkMain" }.first(where: hasContent)
            ?? elements(.article).lazy.first(where: hasContent)
    }

    // Pages can hold empty ones (fetching the text instead costs 40 ms on Wikipedia)
    private func hasContent(_ element: AXElement) -> Bool {
        (try? element.attribute(.children))?.isEmpty == false
    }

    // MARK: Visible area

    // The web area's frame is the whole document (Safari) or the viewport (Chromium)
    private func visibleFrame() -> CGRect? {
        guard var frame = try? handle.attribute(.frame) else { return nil }
        if let scrollFrame = try? scrollArea?.attribute(.frame) {
            frame = frame.intersection(scrollFrame)
        }
        if let windowFrame = try? window?.attribute(.frame) {
            frame = frame.intersection(windowFrame)
        }
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    // Only Safari has `AXStartTextMarkerForBounds`
    private func visibleStartOffset(in text: String) -> Int? {
        if isChromium {
            guard let visible = visibleFrame(), let leaf = leaves(for: text)?.firstVisible(in: visible) else { return nil }
            return leaf.range.lowerBound
        }
        guard let visible = visibleFrame(),
            let marker = (try? handle.attribute(.startTextMarkerForBounds, for: visible))
                ?? (try? handle.attribute(.textMarkerForPosition, for: CGPoint(x: visible.midX, y: visible.minY + 1)))
        else { return nil }
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
            let firstMarkers = markers(of: first.leaf, text: text),
            let lastMarkers = last.leaf.index == first.leaf.index ? firstMarkers : markers(of: last.leaf, text: text),
            let start = leafMarker(in: first.leaf, at: first.part.lowerBound, markers: firstMarkers),
            let end = selection.isEmpty ? start : leafMarker(in: last.leaf, at: last.part.upperBound, markers: lastMarkers),
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

    private typealias LeafMarkers = (start: AXTextMarker, end: AXTextMarker, length: Int, shift: Int)

    // `shift`: where the leaf's page text starts in its range string, which can hold collapsed whitespace (Gutenberg)
    private func markers(of leaf: PageLeaves.Leaf, text: String) -> LeafMarkers? {
        let pageText = substring(leaf.range, of: text)
        guard let leafRange = try? handle.attribute(.textMarkerRangeForUIElement, for: leaf.element),
            let start = leafRange.start, let end = leafRange.end,
            let string = try? handle.attribute(.stringForTextMarkerRange, for: leafRange)
        else { return nil }
        let location = (string as NSString).range(of: pageText).location
        return (start, end, string.utf16.count, location == NSNotFound ? 0 : location)
    }

    // Leaf-anchored markers can only be made by stepping from another one
    private func leafMarker(in leaf: PageLeaves.Leaf, at offset: Int, markers: LeafMarkers) -> AXTextMarker? {
        let (leafStart, leafEnd, length, shift) = markers
        let local = min(max(offset - leaf.range.lowerBound + shift, 0), length)
        var anchors: [(local: Int, marker: AXTextMarker)] = [(0, leafStart), (length, leafEnd)]
        if let last = lastLeafMarker, last.element == leaf.element { anchors.append((last.local, last.marker)) }
        var (position, marker) = anchors.min { abs($0.local - local) < abs($1.local - local) }!
        // Steps are characters, not UTF-16 units: measure and correct
        for _ in 0..<6 where position != local {
            guard let next = stepped(marker, by: abs(local - position), forward: position < local) else { return nil }
            marker = next
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
    private func leafOffset(of marker: AXTextMarker, text: String) -> Int? {
        guard isChromium else { return nil }
        return leafOffset(of: marker, in: try? handle.attribute(.uiElementForTextMarker, for: marker), text: text)
    }

    /// `element`: the marker's (`AXUIElementForTextMarker`).
    private func leafOffset(of marker: AXTextMarker, in element: AXElement?, text: String) -> Int? {
        guard isChromium, let element, let leaves = pageLeaves, leaves.text == text,
            let index = leaves.index(of: element), let leaf = leaves.leaf(at: index), !leaf.range.isEmpty,
            let leafMarkers = markers(of: leaf, text: text),
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
        // The nearest paragraphs found before and after `offset`, with their AX index ranges
        var before: (block: Selection, indices: Range<Int>)?
        var after: (block: Selection, indices: Range<Int>)?
        for _ in 0..<8 {
            guard let marker = try? handle.attribute(.textMarkerForIndex, for: min(max(0, guess), lastIndex(in: text))),
                let paragraph = try? handle.attribute(.paragraphTextMarkerRangeForTextMarker, for: marker),
                let string = try? handle.attribute(.stringForTextMarkerRange, for: paragraph), !string.isEmpty,
                let start = paragraph.start,
                let index = try? handle.attribute(.indexForTextMarker, for: start),
                let found = Self.nearestOccurrence(of: string, to: index + indexDrift, in: text)
            else { return nil }
            indexDrift = found - index
            let block = Selection(found..<found + string.utf16.count)
            let indices = index..<index + string.utf16.count
            if block.lowerBound <= offset, offset < block.upperBound { return leaves(for: text)?.itemPart(of: block, containing: offset) ?? block }
            if block.upperBound <= offset, before.map({ $0.block.upperBound < block.upperBound }) ?? true { before = (block, indices) }
            if block.lowerBound > offset, after.map({ $0.block.lowerBound > block.lowerBound }) ?? true { after = (block, indices) }
            // Text in no paragraph (U+FFFC for an icon) between two paragraphs adjacent by index
            if let before, let after, before.indices.upperBound >= after.indices.lowerBound {
                return Selection(before.block.upperBound..<after.block.lowerBound)
            }
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
        let expected = expected.clamped(to: 0...text.length)
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
        overlay.show(
            { [weak self] in
                guard let self, app?.isActive != false, isFrontWindow else { return nil }
                return highlightRects(for: selection)
            },
            probe: { [weak self] in
                guard let self, app?.isActive != false, let leaf = pageLeaves?.leaf(containing: selection.lowerBound) else { return nil }
                let lower = max(selection.lowerBound, leaf.range.lowerBound)
                let local = valueRange(of: Selection(lower..<lower), in: leaf)
                return try? leaf.element.attribute(.boundsForRange, for: CFRange(location: local.lowerBound, length: 1))
            })
    }

    // Another window of the browser may be in front of ours
    private var isFrontWindow: Bool {
        guard let window, let pid = try? handle.pid(), let main = try? AXElement.application(pid: pid).attribute(.mainWindow) else { return true }
        return main == window
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
