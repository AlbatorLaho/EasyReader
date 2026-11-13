//
//  CatalystWebAreaReadableElement.swift
//  EasyReader
//

import Cocoa

/// A web area in a Mac Catalyst app: Apple Books' book view (paginated `WKWebView`s, one document and web area per
/// chapter).
///
/// UIKit's AX bridge gives a web area itself no text, text markers or selection; its children are only the paragraphs
/// (and headings) on the current spread, and each child's `AXValue` is only its part on that spread. Each child's
/// `AXTextMarkerRangeForUIElement` still covers its whole paragraph, and markers step through the whole chapter (also
/// past the spread, where `AXUIElementForTextMarker` gives elements that aren't children), with `AXIndexForTextMarker`
/// = UTF-16 offset in the chapter. So `fullText` is the chapter, built leaf by leaf (~0.3 s for 50k characters; the
/// document's own string differs from the indices around images), and offsets are AX indices.
///
/// Selection: a child's `AXSelectedTextRange` can be set (relative to its paragraph's start, even when that's on an
/// earlier spread) but never reads back, nor does anything else report the user's selection. Selecting text that isn't
/// on the spread makes WebKit scroll its column layout out of alignment with Books' pages (half pages, stale page
/// number), so a unit is selected only after turning to its page (page keys posted to the app: works in the
/// background; the AX scroll-by-page actions return success but do nothing), and only its part on the spread; the rest
/// is selected as speech reaches it (`didReach(_:)`). Reading starts at the user's selection (copied: `copySelection`)
/// when it's on the spread, else resumes the unit read last while it's still on screen, else at the top of the spread.
///
/// Chapters: a spread can show two chapters (the end of one on the left page, the start of the next on the right), each
/// in its own web area; web areas of chapters turned away from stay valid (with stale children) but leave the window.
/// So `handle` is the window, a chapter is identified by its web area, and the web areas shown are looked up on each
/// read. After a chapter's last unit, reading goes on in the next web area on the spread, or turns the page to it.
final class CatalystWebAreaReadableElement: ReadableElement {
    /// A text child of a web area: a paragraph or heading with (part of) its text on the current spread.
    private struct Leaf: Equatable {
        let element: AXElement
        /// The whole paragraph, in AX indices.
        let range: Range<Int>
        /// The part on the spread (`AXValue`).
        let value: String
    }

    /// The web areas shown in the window, in order (left to right page), with their text children.
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

    /// The chapter's part of the current spread.
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

    /// Keys that turn a page (forward, back). Page Down/Up turn exactly one spread (snapping to the page grid, across
    /// chapters) wherever the key focus is; the arrow keys only do while Books itself has it (once the user selected
    /// text, they scroll the web view by 40 px instead), so they're the fallback for when the page keys do nothing.
    private static let pageKeys: (forward: CGKeyCode, back: CGKeyCode) = (121, 116)
    private static let arrowKeys: (forward: CGKeyCode, back: CGKeyCode) = (124, 123)
    private static let copyKey: CGKeyCode = 8

    private var chapter: Chapter?
    /// The unit being read (offsets in the chapter text); what `selection` reports while it's on screen.
    private var tracked: Selection?
    /// End of the part of `tracked` selected so far.
    private var pieceEnd: Int?
    /// Last offset in `selectedText` speech reached.
    private var lastReached: Int?
    /// The unit after which no next chapter was found (end of the book), so it isn't looked for again.
    private var lastChapterEnd: Selection?
    private var isReading = false
    /// A mouse button went up in the app while reading (the user may have selected something): copied at the next
    /// `selection` read.
    private var userMayHaveSelected = false
    // Removed only by `endReading`, which EasyReader always calls: a deinit can't (isolated deinits are off-limits).
    private var mouseMonitor: Any?
    /// Set once the page keys didn't turn the page (see `pageKeys`).
    private var usesArrows = false
    /// Set once a forward turn went back (right-to-left books): the keys are swapped.
    private var isReversed = false

    /// `element` is a web area; reads go to whichever web areas its window shows. (Catalyst elements have no
    /// `AXWindow`: found through parents.)
    required init(_ element: AXElement) {
        super.init((try? element.parent(with: .window)) ?? element)
    }

    /// Whether `element` (an `AXWebArea`) is a Catalyst one: no page-wide text markers, but children with their own.
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

    /// Notes mouse-ups in the app (Books posts no `AXSelectedTextChanged`), so a selection made while reading is copied
    /// once, instead of copying after every unit. Global monitors see other apps' events with the Accessibility grant.
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

    /// Reads the spread; loads the chapter on its first page when the current one isn't shown (or there's none yet),
    /// which drops the unit being read.
    private func refresh() -> (chapter: Chapter, page: Page?)? {
        let spread = readSpread()
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

    private func readSpread() -> Spread {
        Spread(areas: webAreas().map { Spread.Area(webArea: $0, leaves: readLeaves(of: $0), frame: try? $0.attribute(.frame)) })
    }

    /// The web areas the window shows (breadth-first: a few groups down; not searching inside web areas), in order.
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

    /// A web area's text children, with their paragraphs' ranges (AX indices).
    private func readLeaves(of webArea: AXElement) -> [Leaf] {
        let children = (try? webArea.attribute(.children)) ?? []
        return children.compactMap { child in
            guard let markers = try? child.attribute(.textMarkerRangeForUIElement, for: child),
                let start = markers.start, let end = markers.end,
                let lower = try? child.attribute(.indexForTextMarker, for: start),
                let upper = try? child.attribute(.indexForTextMarker, for: end), lower <= upper
            else { return nil }
            return Leaf(element: child, range: lower..<upper, value: (try? child.attribute(.value)) ?? "")
        }
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
            // Split across spreads. Its `AXValue` is usually its part on this one, but not always (seen: a head
            // without its first line, running on to the paragraph's end), so its lines on screen are measured.
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

    /// The part of `leaf`'s paragraph (AX indices) whose lines are inside `screen` (the window), stepping line by line
    /// from its start (~1 ms per line).
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

    /// Where `value` (the part of a paragraph on the spread) is in `paragraph` (its whole text): its tail on the spread
    /// it continues onto (the first paragraph: `fromEnd`), its head on the one it continues from, or all of it. Books
    /// leaves out the last character of a tail, so a tail ending one short of the paragraph's end gets it back.
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

    /// The chapter shown in `area`, walking leaf to leaf from its first text child to both ends of the document. Each
    /// leaf's text is put at its AX index (gaps between leaves, i.e. paragraph breaks, as line breaks).
    private func loadChapter(_ area: Spread.Area) -> Chapter? {
        guard let leaf = area.leaves.first?.element, let first = span(of: leaf) else { return nil }
        // Inline runs (italics…) are elements of their own inside their paragraph, and the walk can meet one before its
        // paragraph (one starting with an italic word): in order of start, longest first, each adding what's past the
        // text so far.
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

    /// A leaf's range (AX indices) and text, as found walking the document.
    private struct Span {
        let range: Range<Int>
        let text: String
    }

    private func span(of leaf: AXElement) -> Span? {
        guard let markers = try? leaf.attribute(.textMarkerRangeForUIElement, for: leaf),
            let start = markers.start, let end = markers.end,
            let lower = try? leaf.attribute(.indexForTextMarker, for: start),
            let upper = try? leaf.attribute(.indexForTextMarker, for: end), lower <= upper
        else { return nil }
        let text = (try? leaf.attribute(.attributedStringForTextMarkerRange, for: markers))?.string.string ?? ""
        return Span(range: lower..<upper, text: text)
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

    /// Selects the part of `tracked` from `offset` that's on the spread showing `offset` (turning to it first);
    /// returns that part.
    @discardableResult
    private func selectPiece(from offset: Int) -> Selection? {
        guard let tracked, let page = page(showing: offset) else {
            pieceEnd = nil
            return nil
        }
        guard offset < page.visible.upperBound || offset >= tracked.upperBound else {
            // Couldn't turn to it: don't try again on every word (`didReach`).
            Log.accessibility.debug("catalyst: couldn't turn to \(offset)")
            pieceEnd = tracked.upperBound
            return nil
        }
        // From the paragraph holding `offset`, or the next one when it's in the line breaks between them.
        let clamped = min(max(offset, page.visible.lowerBound), page.visible.upperBound)
        let paragraph = page.paragraphs.first(where: { clamped < $0.range.upperBound }) ?? page.paragraphs[page.paragraphs.count - 1]
        let start = min(max(clamped, paragraph.range.lowerBound), paragraph.range.upperBound)
        let end = max(start, min(tracked.upperBound, page.visible.upperBound, paragraph.range.upperBound))
        pieceEnd = end
        let range = CFRange(location: start - paragraph.range.lowerBound, length: end - start)
        // WebKit scrolls a selection in a paragraph that starts on an earlier page back toward its start.
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

    /// Undoes WebKit scrolling `webArea` off Books' page grid (its frame moved from `frame`, where it was on the page):
    /// an arrow key turns to the nearest page in its direction, back to where it was.
    private func realign(_ webArea: AXElement, to frame: CGRect) {
        var moved: CGRect?
        for _ in 0..<6 {
            moved = try? webArea.attribute(.frame)
            if moved != frame { break }
            Thread.sleep(forTimeInterval: 0.03)
        }
        guard let moved, moved != frame, let pid = try? handle.pid() else { return }
        // Scrolled back (content moved right): turn forward to get back.
        let forward = moved.minX > frame.minX
        Log.accessibility.debug("catalyst: selecting scrolled the page by \(moved.minX - frame.minX), turning back")
        postKey(key(forward: forward), to: pid)
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 0.05)
            if (try? webArea.attribute(.frame)) == frame { return }
        }
        Log.accessibility.debug("catalyst: page didn't realign")
    }

    private func key(forward: Bool) -> CGKeyCode {
        let keys = usesArrows ? Self.arrowKeys : Self.pageKeys
        return forward != isReversed ? keys.forward : keys.back
    }

    private func postKey(_ key: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.postToPid(pid)
        }
    }

    /// The chapter's part of the spread showing chapter offset `offset`, turning pages to it.
    private func page(showing offset: Int) -> Page? {
        guard let chapter else { return nil }
        var spread = readSpread()
        guard var page = page(of: chapter, in: spread) else { return nil }
        var lastDirection: Bool?
        for _ in 0..<200 {
            let visible = page.visible
            if visible.contains(offset) { return page }
            let forward = offset >= visible.upperBound
            // Turned past it (it's between what two spreads report): take this one.
            if let lastDirection, lastDirection != forward { return page }
            lastDirection = forward
            guard let turned = turnPage(forward: forward, from: spread) else { return page }
            guard let next = self.page(of: chapter, in: turned) else {
                // Out of the chapter: offsets are only valid in this one.
                _ = turnPage(forward: !forward, from: turned)
                return page
            }
            if forward ? next.visible.lowerBound < visible.lowerBound : next.visible.lowerBound > visible.lowerBound {
                isReversed.toggle()
                Log.accessibility.debug("catalyst: page turn went the other way, swapping keys")
            }
            spread = turned
            page = next
        }
        return page
    }

    /// Posts a page key to the app and waits for the spread's text to change and the spread to settle (the same twice
    /// in a row, frames included, or for a while when it has no text: between chapters there's briefly no web area); nil
    /// if it doesn't change. The text changes ~50 ms before the turn's animation (~0.5 s) ends, and selecting during it
    /// leaves the pages out of alignment. When the page keys don't move anything, switches to the arrow keys.
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

    /// Starts from the user's selection when it's on the spread. Books doesn't report it, but copies it (also in the
    /// background), so it's copied with a posted ⌘C and the clipboard restored. Not taken when it's (part of) the unit
    /// being read, i.e. our own selection.
    private func adoptUserSelection() {
        guard let shown = refresh(), let page = shown.page, let copied = copySelection(),
            let found = Self.locate(copied: copied, in: shown.chapter.nsText, on: page.visible)
        else { return }
        if let tracked, tracked.lowerBound <= found.lowerBound, found.upperBound <= tracked.upperBound { return }
        Log.accessibility.debug("catalyst: user selection \(found)")
        tracked = Selection(found)
        // Already selected (by the user) on this spread; the rest is selected as speech reaches it.
        pieceEnd = min(found.upperBound, page.visible.upperBound)
        lastReached = nil
    }

    /// The app's selection as copied (⌘C), leaving the clipboard as it was; nil if nothing was copied.
    private func copySelection() -> String? {
        guard let pid = try? handle.pid() else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let count = pasteboard.changeCount
        postKey(Self.copyKey, flags: .maskCommand, to: pid)
        for _ in 0..<15 where pasteboard.changeCount == count {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != count else { return nil }
        let copied = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects(
            saved.map { pairs in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            })
        return copied.map(Self.excerpt(fromCopied:))
    }

    /// The selected text in what Books copies: `“text”`, a blank line and a citation ("Excerpt From", title, author…).
    nonisolated static func excerpt(fromCopied copied: String) -> String {
        guard copied.hasPrefix("“"), let end = copied.range(of: "”\n\n", options: .backwards) else { return copied }
        return String(copied[copied.index(after: copied.startIndex)..<end.lowerBound])
    }

    /// Where `copied` (a selection's text) is in `text`, starting on the spread showing `visible`. Matched by its first
    /// and last lines, as the copy's line breaks between paragraphs needn't be the text's.
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

    /// Whether speech reached the last word of the chapter's last unit.
    private func isAtChapterEnd(_ chapter: Chapter) -> Bool {
        guard let tracked, !tracked.isEmpty, tracked != lastChapterEnd, tracked.upperBound <= chapter.nsText.length,
            let lastReached, let spoken = selectedText.map({ $0 as NSString }), lastReached <= spoken.length
        else { return false }
        let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FFFC}"))
        let rest = chapter.nsText.substring(from: tracked.upperBound)
        guard rest.trimmingCharacters(in: blank).isEmpty else { return false }
        let unread = spoken.substring(from: lastReached).trimmingCharacters(in: blank)
        return unread.rangeOfCharacter(from: blank) == nil
    }

    /// Loads the chapter after the current one: the next web area on the spread, or the first other one after turning
    /// the page. Its `tracked` is empty at its start, so reading goes on from there.
    private func advanceChapter() -> Chapter? {
        guard let current = chapter else { return nil }
        var spread = readSpread()
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
        lastChapterEnd = tracked
        return nil
    }
}
