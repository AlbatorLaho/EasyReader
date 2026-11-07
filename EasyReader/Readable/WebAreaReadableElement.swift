//
//  WebAreaReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import AXSwift
import Cocoa

extension ReadableElement.Role {
    static let webArea = Self("AXWebArea")
}

/// A web page (Safari/WebKit incl. `WKWebView`, Chromium, Firefox), read through the AX text-marker API.
///
/// Web areas have no `AXValue`/`AXSelectedTextRange`; text positions are opaque text markers instead. The page text is
/// the string between `AXStartTextMarker` and `AXEndTextMarker`, and a marker's offset is the UTF-16 length of the text
/// before it (consistent with the full text by construction). `AXTextMarkerForIndex`/`AXIndexForTextMarker` use a
/// different count (it drifts by dozens of characters on real pages), so they only seed the search for an offset's marker.
///
/// Not every browser lets AX clients change the page selection: Chromium (tested: Brave) reports the user's selection
/// (only once its full AX mode is on, see `beginReading`) but ignores setting it. The selection is then tracked here: reading
/// starts at the user's selection or caret, else at the top of the visible part of the page (Safari) or of the page
/// (Chromium), and continues from there, just without highlighting. Safari/WebKit supports both.
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
    private var enabledAppFlags: [String] = []

    /// Chromium (and Electron) build their full AX tree, incl. the page selection, only for assistive apps: Electron
    /// listens to `AXManualAccessibility`, Chromium to `AXEnhancedUserInterface` (what VoiceOver sets; while on, some
    /// apps skip window animations, which is why it's only on while reading). Other browsers ignore both.
    /// Chromium keeps its full tree after the flag is turned off again.
    override func beginReading() {
        guard enabledAppFlags.isEmpty, let pid = try? handle.pid(), pid != getpid() else { return }
        let app = AXUIElementCreateApplication(pid)
        for flag in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(app, flag as CFString, &value) == .success, (value as? Bool) == true { continue }
            AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
            // Chromium reports failure for `AXEnhancedUserInterface` but applies it: check by reading it back.
            if AXUIElementCopyAttributeValue(app, flag as CFString, &value) == .success, (value as? Bool) == true {
                enabledAppFlags.append(flag)
            }
        }
        Log.accessibility.debug("web area: turned on \(enabledAppFlags) for \(appDomain ?? "unknown app")")
    }

    override func endReading() {
        guard !enabledAppFlags.isEmpty, let pid = try? handle.pid() else { return }
        let app = AXUIElementCreateApplication(pid)
        for flag in enabledAppFlags {
            AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanFalse)
        }
        Log.accessibility.debug("web area: turned off \(enabledAppFlags) for \(appDomain ?? "unknown app")")
        enabledAppFlags = []
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
            guard let range = markerRange(for: newValue, in: text) else {
                Log.accessibility.debug("web area: no markers for \(newValue)")
                return
            }
            do {
                try handle.setAttribute("AXSelectedTextMarkerRange", value: range)
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
        guard let range = parameterless("AXSelectedTextMarkerRange"),
            let start = TextMarkerRange.start(of: range), let lower = offset(of: start, in: text),
            let selected = parameterized("AXStringForTextMarkerRange", range) as? String
        else { return nil }
        return Report(selection: Self.locate(selected, near: lower, in: text), string: selected)
    }

    /// Scrolls the element holding the selection start into view (`AXScrollToVisible`; browsers don't expose a
    /// page-sized frame with scroll bars consistently), unless the selection is already visible.
    override func scroll(to selection: Selection, options: ScrollOptions) {
        guard let text = fullText, let start = marker(at: selection.lowerBound, in: text) else { return }
        if let range = markerRange(for: selection, in: text),
            let bounds: CGRect = rect(parameterized("AXBoundsForTextMarkerRange", range)),
            let visible = visibleFrame()
        {
            let padding = min(CGFloat(options.padding), visible.height / 2)
            if bounds.size != .zero, visible.insetBy(dx: 0, dy: padding).contains(bounds) {
                Log.scroll.debug("web area: \(selection) already visible")
                return
            }
        }
        guard let element = parameterized("AXUIElementForTextMarker", start), CFGetTypeID(element) == AXUIElementGetTypeID() else { return }
        let target = UIElement(element as! AXUIElement)
        do {
            try target.performAction("AXScrollToVisible")
            Log.scroll.debug("web area: scrolled element at \(selection.lowerBound) into view")
        } catch {
            Log.scroll.debug("web area: AXScrollToVisible failed: \(error)")
        }
    }

    // MARK: Offsets ↔ markers

    private var startMarker: AnyObject? { parameterless("AXStartTextMarker") }
    private var endMarker: AnyObject? { parameterless("AXEndTextMarker") }

    /// UTF-16 offset of `marker` in `text` (the page text): the length of the text before it.
    func offset(of marker: AnyObject, in text: String) -> Int? {
        guard let start = startMarker, let before = string(from: start, to: marker) else { return nil }
        // The range is unordered: for a marker before the document start (Safari's skip links) it's the text between
        // them, not a prefix.
        return text.utf16.starts(with: before.utf16) ? before.utf16.count : 0
    }

    /// The marker at UTF-16 `offset` in `text`, or the nearest one when no marker maps to it exactly.
    func marker(at offset: Int, in text: String) -> AnyObject? {
        let target = min(max(offset, 0), text.utf16.count)
        if target == 0 { return startMarker }
        if target == text.utf16.count { return endMarker }

        // `AXTextMarkerForIndex` counts differently, but the drift changes slowly: correct the guess by the error.
        var guess = target
        var best: (marker: AnyObject, offset: Int)?
        for _ in 0..<4 {
            guard let marker = parameterized("AXTextMarkerForIndex", guess as CFNumber),
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
            guard let next = parameterized(forward ? "AXNextTextMarkerForTextMarker" : "AXPreviousTextMarkerForTextMarker", current.marker),
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

    private func markerRange(for selection: Selection, in text: String) -> AnyObject? {
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
        guard var frame: CGRect = try? handle.attribute(.frame) else { return nil }
        if let scrollArea = try? handle.parent(with: .scrollArea), let scrollFrame: CGRect = try? scrollArea.attribute(.frame) {
            frame = frame.intersection(scrollFrame)
        }
        if let window: UIElement = try? handle.attribute(.window), let windowFrame: CGRect = try? window.attribute(.frame) {
            frame = frame.intersection(windowFrame)
        }
        return frame.isNull || frame.isEmpty ? nil : frame
    }

    /// Chromium has no `AXStartTextMarkerForBounds` (nor working position hit-testing), so it starts at the top.
    private func visibleStartOffset(in text: String) -> Int? {
        guard let visible = visibleFrame(), let marker = parameterized("AXStartTextMarkerForBounds", AXValue.rect(visible)) else {
            return nil
        }
        return offset(of: marker, in: text)
    }

    // MARK: Raw AX
    // Text markers are opaque CF types, so these bypass AXSwift's value unpacking.

    private func parameterless(_ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(handle.element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func parameterized(_ attribute: String, _ parameter: AnyObject) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(handle.element, attribute as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    /// Chromium has only the unordered variant; WebKit has both.
    private func range(from start: AnyObject, to end: AnyObject) -> AnyObject? {
        parameterized("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
    }

    private func string(from start: AnyObject, to end: AnyObject) -> String? {
        range(from: start, to: end).flatMap { parameterized("AXStringForTextMarkerRange", $0) as? String }
    }

    private func rect(_ value: AnyObject?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }
}

extension AXValue {
    fileprivate static func rect(_ rect: CGRect) -> AXValue {
        var rect = rect
        return AXValueCreate(.cgRect, &rect)!
    }
}

/// HIServices function for splitting an `AXTextMarkerRange`. Not in the SDK headers, but exported (WebKit and assistive
/// apps use them); no browser implements the `AXStartTextMarkerForTextMarkerRange` attribute instead.
private enum TextMarkerRange {
    private typealias CopyMarker = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?

    private static let copyStart = load("AXTextMarkerRangeCopyStartMarker")

    private static func load(_ name: String) -> CopyMarker? {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, name) else {
            Log.accessibility.error("\(name) unavailable")
            return nil
        }
        return unsafeBitCast(symbol, to: CopyMarker.self)
    }

    static func start(of range: AnyObject) -> AnyObject? { copyStart?(range)?.takeRetainedValue() }
}
