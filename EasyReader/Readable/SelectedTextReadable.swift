import Cocoa
import Defaults

/// The selected text of an app with no readable element, read as a document of its own (`readSelectedTextFallback`).
final class SelectedTextReadable: Readable {
    let app: NSRunningApplication?
    let title: String?
    let fullText: String?
    var selection: Selection? = Selection() {
        didSet { highlight(selection) }
    }
    var onInvalidate: (() -> Void)?

    /// Where the text is in the app, for the overlay.
    private let source: (element: AXElement, offset: Int)?
    private lazy var overlay = HighlightOverlay()
    private(set) var highlighted: Selection?

    var groupTitle: String? { app?.localizedName }
    var appDomain: String? { app?.bundleIdentifier }
    var icon: NSImage? { app?.icon }

    var selectedText: String? {
        guard let fullText, let selection, let range = Range(selection, in: fullText) else { return nil }
        return String(fullText[range])
    }

    init(_ text: String, app: NSRunningApplication?, title: String? = nil, source: (element: AXElement, offset: Int)? = nil) {
        fullText = text
        self.app = app
        self.title = title
        self.source = source
    }

    func scroll(to selection: Selection, options: ScrollOptions) {}

    func endReading() {
        highlighted = nil
        overlay.hide()
    }

    private func highlight(_ selection: Selection?) {
        guard source != nil, let selection, !selection.isEmpty else {
            endReading()
            return
        }
        highlighted = selection
        overlay.show { [weak self] in
            guard let self, app?.isActive != false else { return nil }
            return highlightRects(for: selection)
        }
    }

    /// Screen rects (top-left origin), one per line, of the visible part of `selection`.
    func highlightRects(for selection: Selection) -> [CGRect]? {
        guard let source, var visible = try? source.element.attribute(.frame) else { return nil }
        // A text view's frame is its whole document
        if let scrollArea = try? source.element.parent(with: .scrollArea), let frame = try? scrollArea.attribute(.frame) {
            visible = visible.intersection(frame)
        }
        if let window = try? source.element.attribute(.window), let frame = try? window.attribute(.frame) {
            visible = visible.intersection(frame)
        }
        let range = Selection(selection.lowerBound + source.offset..<selection.upperBound + source.offset)
        return HighlightOverlay.lineRects(of: source.element, range)
            .map { $0.intersection(visible) }
            .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
    }

    /// Nil when the setting is off or nothing is selected.
    static func selection(in pid: pid_t, focused: AXElement?) -> SelectedTextReadable? {
        guard Defaults[.readSelectedTextFallback], let (text, isFocusedSelection) = selectedText(in: pid, focused: focused) else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        let title = try? focused?.attribute(.window)?.attribute(.title)
        // Some apps report a stale or empty range
        let source =
            isFocusedSelection
            ? (try? focused?.attribute(.selectedTextRange)).flatMap { range in
                range.length == text.utf16.count ? focused.map { (element: $0, offset: range.location) } : nil
            }
            : nil
        return SelectedTextReadable(text, app: app, title: title, source: source)
    }

    /// The app's selected text: the focused element's (`isFocusedSelection`), else copied with ⌘C.
    static func selectedText(in pid: pid_t, focused: AXElement?) -> (text: String, isFocusedSelection: Bool)? {
        if let focused, let text = try? focused.attribute(.selectedText), hasText(text) {
            Log.accessibility.debug("selected text of focused element (\(text.utf16.count) chars)")
            return (text, true)
        }
        if let text = CopiedSelection.copy(from: pid, timeout: 0.5), hasText(text) {
            Log.accessibility.debug("copied selection (\(text.utf16.count) chars)")
            return (text, false)
        }
        return nil
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
