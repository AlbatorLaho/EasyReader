import Cocoa

/// A Mac Catalyst web area (Apple Books' paginated chapters): `handle` is the window, a chapter its web area, offsets its AX indices.
final class CatalystWebAreaReadableElement: ReadableElement {
    /// A paragraph or heading with (part of) its text on the spread.
    private struct Leaf: Equatable {
        let element: AXElement
        /// The whole paragraph.
        let range: Range<Int>
        /// Usually only the part on the spread.
        let value: String
    }

    /// The web areas shown, left to right.
    private struct Spread: Equatable {
        struct Area: Equatable {
            let webArea: AXElement
            let leaves: [Leaf]
            /// Moves while a page turn animates.
            let frame: CGRect?
        }

        let areas: [Area]

        var isEmpty: Bool { areas.allSatisfy(\.leaves.isEmpty) }
        var leaves: [[Leaf]] { areas.map(\.leaves) }
    }

    private struct Paragraph {
        let element: AXElement
        let range: Range<Int>
        let visible: Range<Int>
    }

    /// The chapter's part of the spread.
    private struct Page {
        let paragraphs: [Paragraph]
        var visible: Range<Int> { paragraphs[0].visible.lowerBound..<paragraphs[paragraphs.count - 1].visible.upperBound }
    }

    private struct Chapter {
        let webArea: AXElement
        let text: String
        let nsText: NSString
        /// AX index of the chapter's first character (0 in Books).
        let base: Int
    }

    /// A leaf's range and text, as found walking the document.
    private struct Span {
        let range: Range<Int>
        let text: String
    }

    // Page Down/Up; arrows only turn while Books' page controller has key focus (else they scroll 40 px), so they're the fallback.
    private static let pageKeys: (forward: CGKeyCode, back: CGKeyCode) = (121, 116)
    private static let arrowKeys: (forward: CGKeyCode, back: CGKeyCode) = (124, 123)

    /// How long `page(showing:)` may keep turning.
    static let maxTurningTime: TimeInterval = 20

    private var chapter: Chapter?
    /// The unit being read; what `selection` reports while it's on screen.
    private var tracked: Selection?
    /// End of the part of `tracked` selected so far.
    private var pieceEnd: Int?
    /// Last offset in `selectedText` speech reached.
    private var lastReached: Int?
    /// The book's end: no next chapter after this unit of this chapter (web area).
    private var lastChapterEnd: (webArea: AXElement, unit: Selection)?
    private var isReading = false
    private var userMayHaveSelected = false
    // Removed only by `endReading`, which EasyReader always calls: a deinit can't (isolated deinits are off-limits).
    private var mouseMonitor: Any?
    private var usesArrows = false
    private var isRightToLeft = false
    /// What `spread()` read this main-actor turn; dropped by a posted key.
    private var cachedSpread: Spread?

    // Catalyst elements have no `AXWindow`.
    required init(_ element: AXElement) {
        super.init((try? element.parent(with: .window)) ?? element)
    }

    /// Whether the `AXWebArea` `element` has no page-wide text markers, but children with their own.
    static func matches(_ element: AXElement) -> Bool {
        guard (try? element.attribute(.startTextMarker)) == nil,
            let child = (try? element.attribute(.children))?.first
        else { return false }
        let key: AXParameterizedAttribute<AXElement, AXTextMarkerRange> = .textMarkerRangeForUIElement
        return child.parameterizedAttributeNames.contains(key.name)
    }

    override var title: String? { try? handle.attribute(.title) }

    override var fullText: String? {
        guard let chapter = refresh()?.chapter else { return nil }
        if isReading, isAtChapterEnd(chapter), let next = advanceChapter() {
            return next.text
        }
        return chapter.text
    }

    override var selectedText: String? {
        guard let chapter, let tracked, tracked.upperBound <= chapter.nsText.length else { return nil }
        return chapter.nsText.substring(with: NSRange(tracked))
    }

    override var selection: Selection? {
        get {
            if userMayHaveSelected {
                userMayHaveSelected = false
                adoptUserSelection()
            }
            guard let page = refresh()?.page else { return nil }
            if let tracked, Self.isShown(tracked, on: page.visible) { return tracked }
            let top = page.visible.lowerBound
            return Selection(top..<top)
        }
        set {
            guard let newValue, chapter != nil else { return }
            tracked = newValue
            lastReached = nil
            selectPiece(from: newValue.lowerBound)
        }
    }

    override func didReach(_ offset: Int) -> Selection? {
        lastReached = offset
        guard let tracked, let pieceEnd, pieceEnd < tracked.upperBound, tracked.lowerBound + offset >= pieceEnd else { return nil }
        Log.accessibility.debug("catalyst: reading reached \(tracked.lowerBound + offset), past the page")
        return selectPiece(from: pieceEnd)
    }

    override func beginReading() {
        isReading = true
        adoptUserSelection()
        watchMouse()
    }

    override func endReading() {
        isReading = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // Books posts no `AXSelectedTextChanged`; this way the clipboard isn't touched per unit.
    private func watchMouse() {
        guard mouseMonitor == nil, let pid = try? handle.pid() else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self?.userMayHaveSelected = true
            }
        }
    }

    // MARK: Spread

    /// Loads the spread's first chapter when the current one isn't shown, dropping the unit being read.
    private func refresh() -> (chapter: Chapter, page: Page?)? {
        let spread = spread()
        if let chapter {
            if let page = page(of: chapter, in: spread) { return (chapter, page) }
            // Shown, but its text doesn't fit (yet): keep it rather than reloading on every read.
            if spread.areas.contains(where: { $0.webArea == chapter.webArea }) { return (chapter, nil) }
        }
        guard let area = spread.areas.first(where: { !$0.leaves.isEmpty }), let loaded = loadChapter(area) else {
            return chapter.map { ($0, nil) }
        }
        Log.accessibility.debug("catalyst: loaded chapter of \(loaded.nsText.length) chars")
        chapter = loaded
        tracked = nil
        pieceEnd = nil
        return (loaded, page(of: loaded, in: spread))
    }

    /// The spread, read once per main-actor turn: nothing moves on screen until we post a key.
    private func spread() -> Spread {
        if let cachedSpread { return cachedSpread }
        let read = readSpread()
        cachedSpread = read
        DispatchQueue.main.async { [weak self] in self?.cachedSpread = nil }
        return read
    }

    /// Reads the spread afresh: while waiting for it to change.
    private func readSpread() -> Spread {
        Spread(areas: webAreas().map { Spread.Area(webArea: $0, leaves: readLeaves(of: $0), frame: try? $0.attribute(.frame)) })
    }

    private func webAreas() -> [AXElement] {
        var queue = [handle]
        var found: [AXElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let element = queue.removeFirst()
            visited += 1
            if (try? element.role()) == .webArea {
                found.append(element)
            } else {
                queue += (try? element.attribute(.children)) ?? []
            }
        }
        return found
    }

    private func readLeaves(of webArea: AXElement) -> [Leaf] {
        let children = (try? webArea.attribute(.children)) ?? []
        return children.compactMap { child in
            guard let range = indices(of: child)?.range else { return nil }
            return Leaf(element: child, range: range, value: (try? child.attribute(.value)) ?? "")
        }
    }

    private func indices(of element: AXElement) -> (markers: AXTextMarkerRange, range: Range<Int>)? {
        guard let markers = try? element.attribute(.textMarkerRangeForUIElement, for: element),
            let start = markers.start, let end = markers.end,
            let lower = try? element.attribute(.indexForTextMarker, for: start),
            let upper = try? element.attribute(.indexForTextMarker, for: end), lower <= upper
        else { return nil }
        return (markers, lower..<upper)
    }

    /// `chapter`'s part of `spread`; nil if it isn't shown or its text doesn't fit the chapter's.
    private func page(of chapter: Chapter, in spread: Spread) -> Page? {
        guard let leaves = spread.areas.first(where: { $0.webArea == chapter.webArea })?.leaves else { return nil }
        var screen: CGRect?
        var paragraphs: [Paragraph] = []
        for (index, leaf) in leaves.enumerated() {
            let range = leaf.range.lowerBound - chapter.base..<leaf.range.upperBound - chapter.base
            guard range.lowerBound >= 0, range.upperBound <= chapter.nsText.length else { return nil }
            guard !leaf.value.isEmpty, leaf.value.utf16.count < range.count else {
                paragraphs.append(Paragraph(element: leaf.element, range: range, visible: range))
                continue
            }
            // Split across spreads: `AXValue` isn't always the part on this one, so measure its lines on screen.
            if screen == nil { screen = try? handle.attribute(.frame) }
            let visible: Range<Int>
            if let screen, let lines = visibleLines(of: leaf, in: screen) {
                visible = lines.lowerBound - chapter.base..<lines.upperBound - chapter.base
            } else {
                let text = chapter.nsText.substring(with: NSRange(range))
                guard let found = Self.locate(leaf.value, in: text, fromEnd: index == 0) else { return nil }
                visible = range.lowerBound + found.lowerBound..<range.lowerBound + found.upperBound
            }
            paragraphs.append(Paragraph(element: leaf.element, range: range, visible: visible))
        }
        return paragraphs.isEmpty ? nil : Page(paragraphs: paragraphs)
    }

    /// The part of `leaf`'s paragraph whose lines are inside `screen` (~1 ms per line).
    private func visibleLines(of leaf: Leaf, in screen: CGRect) -> Range<Int>? {
        guard let markers = try? leaf.element.attribute(.textMarkerRangeForUIElement, for: leaf.element),
            var lineStart = markers.start
        else { return nil }
        var startIndex = leaf.range.lowerBound
        var visible: Range<Int>?
        for _ in 0..<2000 {
            guard let lineEnd = try? leaf.element.attribute(.nextLineEndTextMarkerForTextMarker, for: lineStart),
                let endIndex = try? leaf.element.attribute(.indexForTextMarker, for: lineEnd), endIndex > startIndex,
                let line = AXTextMarkerRange(start: lineStart, end: lineEnd),
                let bounds = try? leaf.element.attribute(.boundsForTextMarkerRange, for: line)
            else { break }
            let end = min(endIndex, leaf.range.upperBound)
            if screen.contains(CGPoint(x: bounds.midX, y: bounds.midY)) {
                visible = (visible?.lowerBound ?? startIndex)..<end
            } else if visible != nil {
                break
            }
            guard end < leaf.range.upperBound else { break }
            lineStart = lineEnd
            startIndex = endIndex
        }
        return visible
    }

    /// Where `value` (a paragraph's part on the spread) is in the whole `paragraph`; `fromEnd` for its tail.
    // Books drops the last character of a tail.
    nonisolated static func locate(_ value: String, in paragraph: String, fromEnd: Bool) -> Range<Int>? {
        let paragraph = paragraph as NSString
        let found = paragraph.range(of: value, options: fromEnd ? .backwards : [])
        guard found.location != NSNotFound else { return nil }
        let end = fromEnd && found.upperBound == paragraph.length - 1 ? paragraph.length : found.upperBound
        return found.location..<end
    }

    /// Whether `selection` is (partly) on the spread showing `visible`.
    private static func isShown(_ selection: Selection, on visible: Range<Int>) -> Bool {
        selection.isEmpty
            ? visible.lowerBound <= selection.lowerBound && selection.lowerBound <= visible.upperBound
            : selection.lowerBound < visible.upperBound && selection.upperBound > visible.lowerBound
    }

    // MARK: Chapter text

    /// Each leaf's text at its AX index, gaps (paragraph breaks) as line breaks.
    private func loadChapter(_ area: Spread.Area) -> Chapter? {
        guard let leaf = area.leaves.first?.element, let first = span(of: leaf) else { return nil }
        // The walk can meet an inline run (italics) before its paragraph: sort by start, longest first.
        let spans = (walk(from: leaf, forward: false) + [first] + walk(from: leaf, forward: true)).sorted {
            ($0.range.lowerBound, -$0.range.count) < ($1.range.lowerBound, -$1.range.count)
        }
        guard let base = spans.first?.range.lowerBound else { return nil }
        var text = ""
        var position = base
        for span in spans where span.range.upperBound > position {
            text += String(repeating: "\n", count: max(0, span.range.lowerBound - position))
            let skip = max(0, position - span.range.lowerBound)
            let length = span.range.count - skip
            var leafText = span.text as NSString
            leafText = leafText.substring(from: min(skip, leafText.length)) as NSString
            if leafText.length > length { leafText = leafText.substring(to: length) as NSString }
            text += leafText as String
            text += String(repeating: " ", count: length - leafText.length)
            position = span.range.upperBound
        }
        return Chapter(webArea: area.webArea, text: text, nsText: text as NSString, base: base)
    }

    private func span(of leaf: AXElement) -> Span? {
        guard let (markers, range) = indices(of: leaf) else { return nil }
        let text = (try? leaf.attribute(.attributedStringForTextMarkerRange, for: markers))?.string.string ?? ""
        return Span(range: range, text: text)
    }

    /// The leaves after (or before) `leaf` in its document, nearest first.
    private func walk(from leaf: AXElement, forward: Bool) -> [Span] {
        let step: AXParameterizedAttribute<AXTextMarker, AXTextMarker> =
            forward ? .nextTextMarkerForTextMarker : .previousTextMarkerForTextMarker
        var spans: [Span] = []
        var leaf = leaf
        var seen: Set<AXElement> = [leaf]
        while seen.count < 100_000 {
            guard let markers = try? leaf.attribute(.textMarkerRangeForUIElement, for: leaf),
                let edge = forward ? markers.end : markers.start,
                let marker = try? leaf.attribute(step, for: edge),
                let next = try? leaf.attribute(.uiElementForTextMarker, for: marker),
                seen.insert(next).inserted,
                let span = span(of: next)
            else { break }
            spans.append(span)
            leaf = next
        }
        return spans
    }

    // MARK: Selecting

    /// Turns to `offset` and selects the part of `tracked` from there that's on the spread.
    @discardableResult
    private func selectPiece(from offset: Int) -> Selection? {
        guard let tracked, let page = page(showing: offset) else {
            pieceEnd = nil
            return nil
        }
        guard offset < page.visible.upperBound || offset >= tracked.upperBound else {
            // Couldn't turn to it: don't try again on every word.
            Log.accessibility.debug("catalyst: couldn't turn to \(offset)")
            pieceEnd = tracked.upperBound
            return nil
        }
        // The paragraph holding `offset`, or the next one when it's in the line breaks between them.
        let clamped = offset.clamped(to: page.visible.lowerBound...page.visible.upperBound)
        let paragraph = page.paragraphs.first(where: { clamped < $0.range.upperBound }) ?? page.paragraphs[page.paragraphs.count - 1]
        let start = clamped.clamped(to: paragraph.range.lowerBound...paragraph.range.upperBound)
        let end = max(start, min(tracked.upperBound, page.visible.upperBound, paragraph.range.upperBound))
        pieceEnd = end
        let range = CFRange(location: start - paragraph.range.lowerBound, length: end - start)
        // WebKit scrolls toward the start of a paragraph that began on an earlier spread.
        let continued = paragraph.range.lowerBound < paragraph.visible.lowerBound
        let webArea = continued ? chapter?.webArea : nil
        let frame = try? webArea?.attribute(.frame)
        do {
            try paragraph.element.set(.selectedTextRange, to: range)
        } catch {
            Log.accessibility.debug("catalyst: selecting \(start)..<\(end) failed: \(error)")
        }
        if let webArea, let frame { realign(webArea, to: frame) }
        return Selection(start..<end)
    }

    /// Undoes WebKit scrolling `webArea` off Books' page grid: a turn key snaps it back to `frame`.
    private func realign(_ webArea: AXElement, to frame: CGRect) {
        var shift: CGFloat?
        for _ in 0..<6 {
            shift = (try? webArea.attribute(.frame)).flatMap { Self.sidewaysShift(from: frame, to: $0) }
            if shift != nil { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard let shift, let pid = try? handle.pid() else { return }
        // Content moved right: scrolled back.
        Log.accessibility.debug("catalyst: selecting scrolled the page by \(shift), turning back")
        postKey(key(forward: shift > 0), to: pid)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            if let now = try? webArea.attribute(.frame), Self.sidewaysShift(from: frame, to: now) == nil { return }
        }
        Log.accessibility.debug("catalyst: page didn't realign")
    }

    /// How far the columns moved sideways; nil within a point (a turn settling can still change y and size).
    nonisolated static func sidewaysShift(from frame: CGRect, to moved: CGRect) -> CGFloat? {
        let shift = moved.minX - frame.minX
        return abs(shift) > 1 ? shift : nil
    }

    private func key(forward: Bool) -> CGKeyCode {
        let keys = usesArrows ? Self.arrowKeys : Self.pageKeys
        return forward != isRightToLeft ? keys.forward : keys.back
    }

    private func postKey(_ key: CGKeyCode, to pid: pid_t) {
        cachedSpread = nil
        CGEvent.postKeystroke(key, to: pid)
    }

    private func page(showing offset: Int) -> Page? {
        guard let chapter else { return nil }
        var spread = spread()
        guard var page = page(of: chapter, in: spread) else { return nil }
        var lastDirection: Bool?
        // Each turn blocks main ~0.5 s.
        let deadline = Date().addingTimeInterval(Self.maxTurningTime)
        for _ in 0..<200 where Date() < deadline {
            let visible = page.visible
            if visible.contains(offset) { return page }
            let forward = offset >= visible.upperBound
            // Turned past it (it's between what two spreads report).
            if let lastDirection, lastDirection != forward { return page }
            lastDirection = forward
            guard let turned = turnPage(forward: forward, from: spread) else { return page }
            guard let next = self.page(of: chapter, in: turned) else {
                // Out of the chapter: offsets are only valid in this one.
                _ = turnPage(forward: !forward, from: turned)
                return page
            }
            if forward ? next.visible.lowerBound < visible.lowerBound : next.visible.lowerBound > visible.lowerBound {
                isRightToLeft.toggle()
                Log.accessibility.debug("catalyst: page turn went the other way, swapping keys")
            }
            spread = turned
            page = next
        }
        return page
    }

    /// Nil if the page didn't turn.
    // Done once text changed and frames read equal twice: text updates before the animation ends. Empty for a while between chapters.
    private func turnPage(forward: Bool, from spread: Spread) -> Spread? {
        guard let pid = try? handle.pid() else { return nil }
        postKey(key(forward: forward), to: pid)
        Log.accessibility.debug("catalyst: turning page \(forward ? "forward" : "back")\(usesArrows ? " (arrow keys)" : "")")
        var previous = spread
        var stable = 0
        var moved = false
        for attempt in 0..<60 {
            Thread.sleep(forTimeInterval: 0.05)
            let read = readSpread()
            moved = moved || read != spread
            if !moved, attempt == 11, !usesArrows {
                Log.accessibility.debug("catalyst: page keys didn't turn the page, using arrow keys")
                usesArrows = true
                postKey(key(forward: forward), to: pid)
            }
            stable = read == previous ? stable + 1 : 0
            previous = read
            if read.leaves != spread.leaves, stable >= (read.isEmpty ? 10 : 1) { return read }
        }
        Log.accessibility.debug("catalyst: page didn't turn")
        return nil
    }

    // MARK: User selection

    /// Starts from the user's selection when it's on the spread, unless it's within the unit being read (ours).
    private func adoptUserSelection() {
        guard let shown = refresh(), let page = shown.page, let pid = try? handle.pid(),
            let copied = CopiedSelection.copy(from: pid).map(Self.excerpt(fromCopied:)),
            let found = Self.locate(copied: copied, in: shown.chapter.nsText, on: page.visible)
        else { return }
        if let tracked, tracked.lowerBound <= found.lowerBound, found.upperBound <= tracked.upperBound { return }
        Log.accessibility.debug("catalyst: user selection \(found)")
        tracked = Selection(found)
        // The user already selected it on this spread.
        pieceEnd = min(found.upperBound, page.visible.upperBound)
        lastReached = nil
    }

    /// The text in Books' copy: `“text”`, a blank line and a citation ("Excerpt From"…).
    nonisolated static func excerpt(fromCopied copied: String) -> String {
        guard copied.hasPrefix("“"), let end = copied.range(of: "”\n\n", options: .backwards) else { return copied }
        return String(copied[copied.index(after: copied.startIndex)..<end.lowerBound])
    }

    /// Where `copied` is in `text`, starting on the spread showing `visible`.
    // By first and last line: the copy's paragraph breaks needn't be the text's.
    nonisolated static func locate(copied: String, in text: NSString, on visible: Range<Int>) -> Range<Int>? {
        let lines = copied.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, let last = lines.last, visible.upperBound <= text.length else { return nil }
        let searchEnd = min(text.length, visible.upperBound + first.utf16.count)
        let start = text.range(of: first, range: NSRange(location: visible.lowerBound, length: searchEnd - visible.lowerBound))
        guard start.location != NSNotFound else { return nil }
        guard lines.count > 1 else { return start.location..<start.upperBound }
        let slack = copied.utf16.count + 16 * lines.count
        let tail = NSRange(location: start.upperBound, length: min(text.length, start.location + slack) - start.upperBound)
        let end = text.range(of: last, range: tail)
        guard end.location != NSNotFound else { return nil }
        return start.location..<end.upperBound
    }

    // MARK: Next chapter

    private func isAtChapterEnd(_ chapter: Chapter) -> Bool {
        guard let tracked, let spoken = selectedText,
            lastChapterEnd.map({ $0.webArea == chapter.webArea && $0.unit == tracked }) != true
        else { return false }
        return Self.isChapterEnd(unit: tracked, in: chapter.nsText, spoken: spoken as NSString, reached: lastReached)
    }

    /// Whether speech reached the last word of `unit`, the chapter's last; `reached`: offset in `spoken` (nil: no word reported yet).
    nonisolated static func isChapterEnd(unit: Selection, in text: NSString, spoken: NSString, reached: Int?) -> Bool {
        guard !unit.isEmpty, unit.upperBound <= text.length else { return false }
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
        guard text.substring(from: unit.upperBound).trimmingCharacters(in: blank).isEmpty else { return false }
        // No words (punctuation, U+FFFC): speech reports none.
        guard let reached else { return spoken.rangeOfCharacter(from: .alphanumerics).location == NSNotFound }
        guard reached <= spoken.length else { return false }
        let unread = spoken.substring(from: reached).trimmingCharacters(in: blank)
        return unread.rangeOfCharacter(from: blank) == nil
    }

    /// The next web area on the spread, else the first other one after turning the page; reading goes on at its start.
    private func advanceChapter() -> Chapter? {
        guard let current = chapter else { return nil }
        var spread = spread()
        let index = spread.areas.firstIndex(where: { $0.webArea == current.webArea })
        var candidates = index.map { Array(spread.areas[($0 + 1)...]) } ?? []
        for _ in 0..<20 {
            for area in candidates where !area.leaves.isEmpty && area.webArea != current.webArea {
                guard let loaded = loadChapter(area) else { continue }
                Log.accessibility.debug("catalyst: next chapter, \(loaded.nsText.length) chars")
                chapter = loaded
                tracked = Selection(0..<0)
                pieceEnd = nil
                lastReached = nil
                return loaded
            }
            guard let turned = turnPage(forward: true, from: spread) else { break }
            spread = turned
            candidates = turned.areas
        }
        Log.accessibility.debug("catalyst: no next chapter")
        lastChapterEnd = tracked.map { (current.webArea, $0) }
        return nil
    }
}
