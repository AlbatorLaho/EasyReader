import AppKit
import Defaults
import UniformTypeIdentifiers
import WebKit

/// A text window to read files, web pages or pasted text in, through the same AX path as any other app's text area.
@MainActor
final class ReaderWindow: NSObject, NSWindowDelegate {
    nonisolated static let windowID = "ReaderWindow"

    /// Open (or closed but kept for reuse) windows, oldest first.
    private(set) static var windows: [ReaderWindow] = []

    /// Set by `AppDelegate`; the toolbar and Services drive it.
    static weak var reader: EasyReader?

    let window: NSWindow
    let textView: NSTextView
    private let loadingView = LoadingView()
    private var loadTask: Task<Void, Never>?
    private var darkBackgroundTask: Task<Void, Never>?

    private static let font = NSFont.systemFont(ofSize: 18)

    static let contentTypes: [UTType] =
        [.text, .rtfd, .flatRTFD, .webArchive]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"].compactMap(UTType.init)

    private override init() {
        let scrollView = ReaderTextView.scrollableTextView()
        let textView = scrollView.documentView as! ReaderTextView
        self.textView = textView
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize()), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        super.init()
        textView.onDrop = { [weak self] url in self?.open(url) }
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let contentView = NSView()
        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)
        loadingView.isHidden = true
        loadingView.onCancel = { [weak self] in self?.loadTask?.cancel() }
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            loadingView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -32),
        ])

        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        window.title = "Reader"
        window.contentView = contentView
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        if let front = Self.front?.window {
            window.setFrameTopLeftPoint(front.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
        } else {
            window.center()
            // Tests resize it: they'd save their sizes to the real defaults.
            if !UserDefaults.isUnderTest { window.setFrameAutosaveName(Self.windowID) }
        }

        darkBackgroundTask = Task { [weak self] in
            for await darkBackground in Defaults.updates(.readerDarkBackground) {
                self?.applyDarkBackground(darkBackground)
            }
        }
    }

    /// Portrait, like a page: 640 wide, 1.3× as tall, within the screen.
    private static func defaultContentSize() -> NSSize {
        let height = min(640 * 1.3, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
        return NSSize(width: 640, height: height)
    }

    static func make() -> ReaderWindow {
        let readerWindow = ReaderWindow()
        windows.append(readerWindow)
        return readerWindow
    }

    /// The frontmost open reader window; minimized ones count, so their text isn't replaced.
    static var front: ReaderWindow? {
        NSApp.orderedWindows.lazy.filter { $0.isVisible || $0.isMiniaturized }
            .compactMap { window in windows.first { $0.window === window } }.first
    }

    /// The window to show: the front one, else the last one used, else a new one.
    static var current: ReaderWindow {
        front ?? windows.last ?? make()
    }

    /// Where opened content goes: with `readerOpensNewWindows` a new window unless the front one is empty.
    static func forNewContent() -> ReaderWindow {
        guard Defaults[.readerOpensNewWindows] else { return current }
        if let front { return front.isEmpty ? front : make() }
        // The window kept after closing the last one
        return windows.last ?? make()
    }

    var isEmpty: Bool { textView.string.isEmpty && loadTask == nil }

    // Dark mode maps the document's colors like TextEdit's "Use Dark Background for Windows"; off, the text area stays light.
    private func applyDarkBackground(_ darkBackground: Bool) {
        textView.usesAdaptiveColorMappingForDarkAppearance = darkBackground
        textView.enclosingScrollView?.appearance = darkBackground ? nil : NSAppearance(named: .aqua)
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        // One window is kept (with its text) for reuse.
        if Self.windows.count > 1 {
            Self.windows.removeAll { $0 === self }
            darkBackgroundTask?.cancel()
        }
    }

    // MARK: Actions

    @objc static func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = Defaults[.readerOpensNewWindows]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc static func openWebPage() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "Enter the address of a page to read its text."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
        field.placeholderString = "https://example.com"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = webURL(field.stringValue) else {
            NSSound.beep()
            return
        }
        forNewContent().open(url)
    }

    /// Opens each URL in its own window with `readerOpensNewWindows`, else only the first.
    static func open(_ urls: [URL], thenRead: Bool = false) {
        for url in Defaults[.readerOpensNewWindows] ? urls : Array(urls.prefix(1)) {
            forNewContent().open(url, thenRead: thenRead)
        }
    }

    /// An http(s) URL from what the user typed, `https://` added when there's no scheme.
    nonisolated static func webURL(_ string: String) -> URL? {
        let string = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: string.contains("://") ? string : "https://" + string),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false
        else { return nil }
        return url
    }

    // MARK: Loading

    /// Loads a file or web page and shows it, presenting any error; web pages show progress in the window meanwhile.
    func open(_ url: URL, thenRead: Bool = false) {
        loadTask?.cancel()
        let previousTitle = window.title
        if !url.isFileURL {
            loadingView.show("Loading \(url.host ?? url.absoluteString)…")
            if isEmpty { window.title = "Loading…" }
            present { [weak self] in self?.loadingView.focusCancel() }
        }
        loadTask = Task {
            defer {
                if loadingView.hasFocus { window.makeFirstResponder(textView) }
                loadingView.isHidden = true
                loadTask = nil
            }
            do {
                if url.isFileURL {
                    try loadFile(url)
                } else {
                    try await loadPage(url)
                }
            } catch {
                if window.title == "Loading…" { window.title = previousTitle }
                if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                    present()
                    window.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
                }
                return
            }
            present { [weak self] in
                if thenRead, self?.startReading() != true { NSSound.beep() }
            }
        }
    }

    func loadFile(_ url: URL) throws {
        var attributes: NSDictionary?
        let text = try NSMutableAttributedString(url: url, options: [:], documentAttributes: &attributes)
        let documentAttributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        if documentAttributes[.documentType] as? NSAttributedString.DocumentType == .plain {
            text.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: text.length))
        }
        show(text, title: url.lastPathComponent, documentAttributes: documentAttributes)
        window.representedURL = url
    }

    /// Also takes file URLs (tests).
    func loadPage(_ url: URL) async throws {
        let (data, response) = try await Self.fetch(url)
        try Task.checkCancellation()
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The server returned HTTP status \(status)."])
        }
        let isHTML = response.mimeType?.contains("html") ?? true
        var encoding: String.Encoding?
        if let name = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            }
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: isHTML ? NSAttributedString.DocumentType.html : .plain,
            // Synchronous HTML import (macOS 11) waits for style sheets up to this.
            .timeout: 10,
            .baseURL: response.url ?? url,
        ]
        if let encoding { options[.characterEncoding] = encoding.rawValue }
        let text: NSAttributedString
        if isHTML, #available(macOS 12.0, *) {
            // Out of process: the main thread (and Cancel) stays responsive.
            text = try await Self.importHTML(Self.withoutMedia(data, encoding: encoding), options: options)
            try Task.checkCancellation()
        } else if isHTML {
            text = try NSAttributedString(data: Self.withoutMedia(data, encoding: encoding), options: options, documentAttributes: nil)
        } else {
            let plain = try NSMutableAttributedString(data: data, options: options, documentAttributes: nil)
            plain.addAttribute(.font, value: Self.font, range: NSRange(location: 0, length: plain.length))
            text = plain
        }
        let title = isHTML ? Self.pageTitle(in: data, encoding: encoding) : nil
        show(text, title: title ?? url.host ?? url.absoluteString)
    }

    @available(macOS 12.0, *)
    private static func importHTML(_ data: Data, options: [NSAttributedString.DocumentReadingOptionKey: Any]) async throws -> NSAttributedString {
        // Called back on main, where the caller is
        struct Result: @unchecked Sendable { let text: NSAttributedString }
        return try await withCheckedThrowingContinuation { continuation in
            NSAttributedString.loadFromHTML(data: data, options: options) { text, _, error in
                if let text {
                    continuation.resume(returning: Result(text: text))
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                }
            }
        }
        .text
    }

    /// Images and embeds aren't read, and HTML import would wait for each one.
    nonisolated static func withoutMedia(_ data: Data, encoding: String.Encoding?) -> Data {
        let encoding = encoding ?? .utf8
        guard let html = String(data: data, encoding: encoding) else { return data }
        let stripped = html.replacingOccurrences(
            of: "<(img|picture|source|video|audio|iframe|embed|object)\\b[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return stripped.data(using: encoding) ?? data
    }

    /// HTML import doesn't report the `<title>`.
    nonisolated static func pageTitle(in data: Data, encoding: String.Encoding?) -> String? {
        guard let html = String(data: data, encoding: encoding ?? .utf8) ?? String(data: data, encoding: .isoLatin1),
            let match = html.range(of: "<title[^>]*>[^<]*", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let raw = html[match].drop { $0 != ">" }.dropFirst()
        let title = (CFXMLCreateStringByUnescapingEntities(nil, String(raw) as CFString, nil) as String)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    private nonisolated static func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        let box = DataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: url) { data, response, error in
                    if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: error ?? URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The widest fixed width the document asks for (TextEdit's view size, fixed-width tables), in points.
    nonisolated static func preferredWidth(of text: NSAttributedString, documentAttributes: [NSAttributedString.DocumentAttributeKey: Any]) -> CGFloat {
        var width = (documentAttributes[.viewSize] as? NSValue)?.sizeValue.width ?? 0
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            for block in (value as? NSParagraphStyle)?.textBlocks ?? [] {
                if block.valueType(for: .width) == .absoluteValueType {
                    width = max(width, block.value(for: .width))
                }
                if let table = (block as? NSTextTableBlock)?.table, table.valueType(for: .width) == .absoluteValueType {
                    width = max(width, table.value(for: .width))
                }
            }
        }
        return width
    }

    func show(_ text: NSAttributedString, title: String, documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]) {
        if let reader = Self.reader, reader.state != .stopped, let readable = reader.readable as? ReadableElement,
            readable.appDomain == Bundle.main.bundleIdentifier, readable.title == window.title
        {
            _ = reader.stop()
        }
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        textView.undoManager?.removeAllActions()
        window.title = title
        window.representedURL = nil
        fitWidth(Self.preferredWidth(of: text, documentAttributes: documentAttributes))
    }

    /// Widens the window to a document's fixed width (within the screen); text wraps to the window either way.
    private func fitWidth(_ documentWidth: CGFloat) {
        guard documentWidth > 0 else { return }
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        let padding = textView.textContainerInset.width * 2 + (textView.textContainer?.lineFragmentPadding ?? 0) * 2 + scroller
        var frame = window.frame
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
        let width = min(window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: documentWidth + padding, height: 0)).width, screen.width)
        guard width > frame.width else { return }
        // Stays portrait where the screen allows
        let height = max(frame.height, min(width * 1.3, screen.height))
        frame = NSRect(x: min(frame.minX, screen.maxX - width), y: max(frame.maxY - height, screen.minY), width: width, height: height)
        window.setFrame(frame, display: true)
    }

    /// Shows the text and reads it from the start (Services, drops on the menu bar icon).
    func read(_ text: NSAttributedString, title: String = "Reader") {
        show(text, title: title)
        present { [weak self] in
            if self?.startReading() != true { NSSound.beep() }
        }
    }

    private func present(then action: (@MainActor () -> Void)? = nil) {
        SettingsOpener.present(window) { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(textView)
            action?()
        }
    }

    /// Reads the text view through AX: the app's focused element, so the window must be key.
    private func startReading() -> Bool {
        guard let reader = Self.reader else { return false }
        window.makeFirstResponder(textView)
        return reader.start(reading: .element(.application(pid: getpid()), fromFocused: true))
    }

    static func updateToolbars() {
        for readerWindow in windows {
            readerWindow.window.toolbar?.validateVisibleItems()
        }
    }

    /// What a drag or Services pasteboard holds that a reader window can take.
    enum PasteboardContent {
        case url(URL)
        case text(NSAttributedString)
    }

    static func content(of pasteboard: NSPasteboard, allowText: Bool) -> PasteboardContent? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            if url.isFileURL {
                if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, contentTypes.contains(where: type.conforms(to:)) {
                    return .url(url)
                }
            } else if webURL(url.absoluteString) != nil {
                return .url(url)
            }
        }
        guard allowText else { return nil }
        let text =
            pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
            ?? pasteboard.string(forType: .string).map(plainText)
        guard let text, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .text(text)
    }

    static func plainText(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font])
    }

    /// Opens or reads what was dropped on the menu bar icon or sent by Services; false if there's nothing to read.
    static func read(_ pasteboard: NSPasteboard) -> Bool {
        switch content(of: pasteboard, allowText: true) {
            case .url(let url): forNewContent().open(url, thenRead: true)
            case .text(let text): forNewContent().read(text)
            case nil: return false
        }
        return true
    }
}

// MARK: - Toolbar

extension ReaderWindow: NSToolbarDelegate, NSToolbarItemValidation {
    private func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "ReaderWindowToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        PlaybackControl.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool)
        -> NSToolbarItem?
    {
        guard PlaybackControl(rawValue: identifier.rawValue) != nil else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.action = #selector(performControl(_:))
        item.isBordered = true
        _ = validateToolbarItem(item)
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let control = PlaybackControl(rawValue: item.itemIdentifier.rawValue) else { return false }
        let appearance = control.appearance(for: Self.reader)
        item.label = appearance.title
        item.toolTip = appearance.title
        item.image = appearance.image
        return appearance.isEnabled
    }

    @objc private func performControl(_ sender: NSToolbarItem) {
        guard let control = PlaybackControl(rawValue: sender.itemIdentifier.rawValue), let reader = Self.reader else { return }
        let ok =
            switch control {
                case .startStop: reader.state == .reading ? reader.stop() : startReading()
                case .playPause: reader.togglePlayPause()
                case .skipBackward: reader.skip(.backward)
                case .skipForward: reader.skip(.forward)
            }
        if !ok { NSSound.beep() }
    }
}

// MARK: - Views

/// Opens dropped files and web links instead of inserting them.
private final class ReaderTextView: NSTextView {
    var onDrop: ((URL) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .url(let url) = ReaderWindow.content(of: sender.draggingPasteboard, allowText: false) else {
            return super.performDragOperation(sender)
        }
        onDrop?(url)
        return true
    }
}

/// A spinner, what's loading, and Cancel, over the text.
private final class LoadingView: NSVisualEffectView {
    var onCancel: (() -> Void)?
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let cancel = CancelButton(title: "Cancel", target: nil, action: nil)

    var hasFocus: Bool { window?.firstResponder === cancel }

    /// Space presses it, like a dialog's focused button.
    func focusCancel() {
        guard !isHidden else { return }
        window?.makeFirstResponder(cancel)
    }

    init() {
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        spinner.style = .spinning
        spinner.controlSize = .small
        // Keeps spinning while HTML import blocks the main thread
        spinner.usesThreadedAnimation = true
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancel.target = self
        cancel.action = #selector(cancelAction)
        let stack = NSStackView(views: [spinner, label, cancel])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
        spinner.startAnimation(nil)
    }

    override var isHidden: Bool {
        didSet { if isHidden { spinner.stopAnimation(nil) } }
    }

    @objc private func cancelAction() {
        onCancel?()
    }
}

/// Takes focus without Full Keyboard Access, and answers Esc and ⌘. while shown.
private final class CancelButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCancel =
            (event.charactersIgnoringModifiers == "." && flags == .command) || (event.keyCode == 53 && flags.isDisjoint(with: [.command, .option, .control]))
        guard isCancel, !isHiddenOrHasHiddenAncestor else { return super.performKeyEquivalent(with: event) }
        performClick(nil)
        return true
    }
}

/// Lets a fetch's data task be cancelled from the task's cancellation handler.
private final class DataTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if isCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        task?.cancel()
    }
}

// MARK: - Services and the menu bar icon

/// The Services menu's "Read with EasyReader" for text and for files (`NSServices` in Info.plist).
@MainActor
final class ReaderService: NSObject {
    @objc func readText(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        if !ReaderWindow.read(pasteboard) { error.pointee = "No text to read." }
    }

    @objc func readFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No file to read."
            return
        }
        ReaderWindow.open(urls, thenRead: true)
    }
}

/// Reads files, links and text dropped on the menu bar icon (NSWindow passes drags to its delegate).
@MainActor
final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private weak var button: NSStatusBarButton?

    func attach(to button: NSStatusBarButton) {
        self.button = button
        button.window?.registerForDraggedTypes([.fileURL, .URL, .rtf, .string])
        button.window?.delegate = self
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ReaderWindow.content(of: sender.draggingPasteboard, allowText: true) != nil else { return [] }
        button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        return ReaderWindow.read(sender.draggingPasteboard)
    }
}
