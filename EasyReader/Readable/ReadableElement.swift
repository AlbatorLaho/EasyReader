import Cocoa

@MainActor
class ReadableElement: Readable {
    let handle: AXElement
    let app: NSRunningApplication?

    var title: String? {
        let window = try? handle.attribute(.window)
        return try? window?.attribute(.title)
    }
    var groupTitle: String? {
        if let name = app?.localizedName { return name }
        let application = try? handle.parent(with: .application)
        return try? application?.attribute(.title)
    }
    var appDomain: String? { app?.bundleIdentifier }
    var icon: NSImage? { app?.icon }
    // Declared in the class too (with the methods below) so subclasses can override them.
    var fullText: String? { nil }
    var selectedText: String? { nil }
    var selection: Selection?
    var contentStart: Int { 0 }
    var contentEnd: Int? { nil }
    // Observe only while someone listens, so readables dropped during a search hold no AX observer.
    var onInvalidate: (() -> Void)? {
        didSet {
            if onInvalidate == nil {
                observer = nil
            } else if observer == nil {
                observeDestruction()
            }
        }
    }
    private var observer: AXNotificationObserver?

    private static let values: [AXRole: ReadableElement.Type] = [
        .textArea: TextAreaReadableElement.self,
        .webArea: WebAreaReadableElement.self,
    ]

    private static let subroleValues: [AXRole: [String: ReadableElement.Type]] = [
        .group: ["AXSharedDocumentContainer": PDFReadableElement.self]
    ]

    /// `subrole` is fetched only for roles registered by subrole.
    static func type(for role: AXRole, subrole: () throws -> String?) rethrows -> ReadableElement.Type? {
        if let type = values[role] { return type }
        guard let types = subroleValues[role], let subrole = try subrole() else { return nil }
        return types[subrole]
    }

    required init(_ element: AXElement) {
        handle = element
        app = (try? handle.pid()).flatMap(NSRunningApplication.init(processIdentifier:))
        Log.accessibility.debug("\(Self.self) for \(app?.bundleIdentifier ?? "unknown app")")
    }

    /// Highlights with `overlay` while the app is active; the first character's bounds (element, index) are the probe.
    func show(_ overlay: HighlightOverlay, rects: @escaping () -> [CGRect]?, firstCharacter: @escaping () -> (AXElement, Int)?) {
        overlay.show(
            { [weak self] in
                guard let self, app?.isActive != false else { return nil }
                return rects()
            },
            probe: { [weak self] in
                guard let self, app?.isActive != false, let (element, index) = firstCharacter() else { return nil }
                return try? element.attribute(.boundsForRange, for: CFRange(location: index, length: 1))
            })
    }

    func scroll(to selection: Selection, options: ScrollOptions) {}
    func textBlock(containing offset: Int) -> Selection? { nil }
    func didReach(_ offset: Int) -> Selection? { nil }
    func beginReading() {}
    func endReading() {}

    // AppKit posts the element's destruction when it leaves its window, but only the window's when the window closes.
    private func observeDestruction() {
        guard let pid = try? handle.pid() else { return }
        let observer: AXNotificationObserver
        do {
            observer = try AXNotificationObserver(pid: pid) { [weak self] _, _ in
                Log.accessibility.debug("readable element or its window destroyed")
                self?.onInvalidate?()
            }
        } catch {
            Log.accessibility.error("Unable to observe readable element destruction: \(error)")
            return
        }
        // Each separately: either one alone still invalidates.
        let targets = [handle] + [try? handle.attribute(.window)].compactMap { $0 }
        var observed = false
        for target in targets {
            do {
                try observer.add(.uiElementDestroyed, for: target)
                observed = true
            } catch {
                Log.accessibility.error("Unable to observe destruction: \(error)")
            }
        }
        if observed { self.observer = observer }
    }
}

extension AXElement {
    @MainActor func readableElement() throws -> ReadableElement? {
        guard let role = try role(),
            let readableType = try ReadableElement.type(for: role, subrole: { try attribute(.subrole) })
        else { return nil }
        if readableType == WebAreaReadableElement.self, CatalystWebAreaReadableElement.matches(self) {
            return CatalystWebAreaReadableElement(self)
        }
        return readableType.init(self)
    }
}
