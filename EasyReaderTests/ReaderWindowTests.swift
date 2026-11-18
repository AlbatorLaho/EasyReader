import AppKit
import Defaults
import Foundation
import Testing

@testable import EasyReader

private struct ReaderTextAreaNotFound: Error {}

extension IntegrationTests {
    /// Loading only fills the window; it isn't shown.
    @MainActor
    struct ReaderWindowTests {
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderWindowTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let directory = directory
            Teardown.add { try? FileManager.default.removeItem(at: directory) }
        }

        @Test func loadsPlainTextFileInWindowFont() throws {
            let url = directory.appendingPathComponent("Notes.txt")
            try "First sentence. Second sentence.".write(to: url, atomically: true, encoding: .utf8)
            let reader = ReaderWindow.current
            try reader.loadFile(url)
            #expect(reader.textView.string == "First sentence. Second sentence.")
            #expect(reader.window.title == "Notes.txt")
            #expect(reader.window.representedURL == url)
            let font = reader.textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 18)
        }

        @Test func loadsHTMLPageWithItsTitle() async throws {
            let url = directory.appendingPathComponent("page.html")
            let html = "<html><head><meta charset=\"utf-8\"><title>Test Page</title></head><body><p>Hello café world.</p></body></html>"
            try html.write(to: url, atomically: true, encoding: .utf8)
            let reader = ReaderWindow.current
            try await reader.loadPage(url)
            #expect(reader.textView.string.contains("Hello café world."))
            #expect(reader.window.title == "Test Page")
            #expect(reader.window.representedURL == nil)
        }

        /// Each scroll puts the unit the same distance below the visible top (TextKit 2's estimated heights made the first far one miss).
        @Test(arguments: [false, true])
        func scrollsUnitsToSamePositionFromTop(smooth: Bool) async throws {
            let reader = ReaderWindow.current
            let paragraphs = (1...300).map { n in
                "Paragraph \(n). " + Array(repeating: "Some words to fill the line and wrap it.", count: n % 7 + 1).joined(separator: " ")
            }
            let text = paragraphs.joined(separator: "\n\n")
            reader.show(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]), title: "Scroll \(UUID().uuidString)")
            reader.window.makeKeyAndOrderFront(nil)
            Teardown.add { reader.window.close() }
            await settle(0.3)
            let readable = try readerReadable()
            let scrollView = try #require(reader.textView.enclosingScrollView)
            let options = ScrollOptions(padding: 40, duration: smooth ? 0.2 : 0)
            var distances: [CGFloat] = []
            for n in [250, 40, 180, 100, 260, 10] {
                let start = (text as NSString).range(of: "Paragraph \(n).").location
                let selection = Selection(start..<(start + 10))
                readable.selection = selection
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: n < 150 ? scrollView.documentView!.frame.height : 0))
                readable.scroll(to: selection, options: options)
                await settle(smooth ? 0.6 : 0.3)  // animation, then corrections 50 ms apart
                let rect = try #require(reader.textView.firstRect(forCharacterRange: NSRange(location: start, length: 10), actualRange: nil) as NSRect?)
                let inWindow = reader.window.convertFromScreen(rect)
                let inClip = scrollView.contentView.convert(inWindow, from: nil)
                distances.append(inClip.minY - scrollView.contentView.bounds.minY)
            }
            let spread = (distances.max() ?? 0) - (distances.min() ?? 0)
            #expect(spread < 4, "distances from top: \(distances)")
        }

        private func readerReadable() throws -> TextAreaReadableElement {
            let app = AXElement.application(pid: getpid())
            let windows = try #require(try app.attribute(.windows))
            let window = try #require(windows.first { (try? $0.attribute(.title) as String?) == ReaderWindow.current.window.title })
            var queue = [window]
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if let readable = try element.readableElement() { return try #require(readable as? TextAreaReadableElement) }
                queue += (try? element.attribute(.children)) ?? []
            }
            throw ReaderTextAreaNotFound()
        }

        /// Fixed-width HTML tables (and the ODT made from them) wrap to the window instead of running past it.
        @Test(arguments: ["html", "odt"])
        func wrapsWideDocumentsToWindow(format: String) async throws {
            let html = directory.appendingPathComponent("wide.html")
            try """
            <html><body><table width="900"><tr><td>A table cell with a long sentence that has to wrap when the window is narrower than the table.</td></tr></table>
            <p>A normal paragraph after it, also long enough to wrap in a narrow window.</p></body></html>
            """.write(to: html, atomically: true, encoding: .utf8)
            var url = html
            if format != "html" {
                url = directory.appendingPathComponent("wide.\(format)")
                let textutil = try Process.run(URL(fileURLWithPath: "/usr/bin/textutil"), arguments: ["-convert", format, html.path, "-output", url.path])
                textutil.waitUntilExit()
            }
            let reader = ReaderWindow.current
            try reader.loadFile(url)
            reader.window.setContentSize(NSSize(width: 360, height: 400))
            reader.window.makeKeyAndOrderFront(nil)
            Teardown.add { reader.window.close() }
            await settle(0.2)
            let clipWidth = try #require(reader.textView.enclosingScrollView).contentView.bounds.width
            #expect(reader.textView.frame.width <= clipWidth)
            let layoutManager = try #require(reader.textView.layoutManager)
            let container = try #require(reader.textView.textContainer)
            layoutManager.ensureLayout(for: container)
            var maxX: CGFloat = 0
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, used, _, _, _ in
                maxX = max(maxX, used.maxX)
            }
            #expect(maxX <= container.size.width, "text runs to \(maxX) in a \(container.size.width) container")
        }

        /// A document with a fixed width (here a 900 pt table) widens the window to fit, within the screen.
        @Test func widensWindowForFixedWidthDocument() throws {
            let url = directory.appendingPathComponent("table.html")
            try "<table width=\"900\"><tr><td>Wide table.</td></tr></table>".write(to: url, atomically: true, encoding: .utf8)
            let reader = ReaderWindow.current
            reader.window.setContentSize(NSSize(width: 400, height: 400))
            try reader.loadFile(url)
            let screen = try #require(reader.window.screen ?? NSScreen.main).visibleFrame
            #expect(reader.window.frame.width >= min(900, screen.width))
            #expect(reader.window.frame.height >= min(reader.window.frame.width * 1.3, screen.height) - 1, "stays portrait")
        }

        @Test func darkBackgroundSettingSwitchesColorMapping() async throws {
            let reader = ReaderWindow.current
            Defaults[.readerDarkBackground] = false
            await settle(0.2)
            #expect(!reader.textView.usesAdaptiveColorMappingForDarkAppearance)
            #expect(reader.textView.enclosingScrollView?.appearance?.name == .aqua)
            Defaults[.readerDarkBackground] = true
            await settle(0.2)
            #expect(reader.textView.usesAdaptiveColorMappingForDarkAppearance)
            #expect(reader.textView.enclosingScrollView?.appearance == nil)
        }

        /// With "Open files in new windows", each file gets a window (the empty front one first); without, one window takes the first file.
        @Test(arguments: [false, true])
        func opensFilesPerWindowSetting(opensNewWindows: Bool) async throws {
            Defaults[.readerOpensNewWindows] = opensNewWindows
            let urls = try (1...2).map { n in
                let url = directory.appendingPathComponent("File \(n).txt")
                try "Text \(n).".write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            let front = ReaderWindow.current
            front.show(NSAttributedString(string: ""), title: "Reader")
            front.window.makeKeyAndOrderFront(nil)
            let before = Set(ReaderWindow.windows.map(ObjectIdentifier.init))
            Teardown.add {
                for readerWindow in ReaderWindow.windows { readerWindow.window.close() }
            }
            await settle(0.2)
            ReaderWindow.open(urls)
            await settle(1)
            let added = ReaderWindow.windows.filter { !before.contains(ObjectIdentifier($0)) }
            #expect(front.window.title == "File 1.txt")
            if opensNewWindows {
                #expect(added.map(\.window.title) == ["File 2.txt"])
                #expect(added.first?.window.isVisible == true)
            } else {
                #expect(added.isEmpty)
            }
        }

        /// New windows are portrait, like the page they show.
        @Test func newWindowIsPortrait() async throws {
            Defaults[.readerOpensNewWindows] = true
            let front = ReaderWindow.current
            front.show(NSAttributedString(string: "Not empty."), title: "Front")
            front.window.makeKeyAndOrderFront(nil)
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            await settle(0.1)
            let new = ReaderWindow.forNewContent()
            #expect(new !== front)
            let size = new.window.contentRect(forFrameRect: new.window.frame).size
            #expect(size.height > size.width, "\(size)")
        }

        enum CancelInput: String, CaseIterable { case click, space, escape, commandPeriod }

        /// Cancel (focused, so Space presses it; also Esc and ⌘.) stops a page load that's still waiting for the server,
        /// and the window goes back to its title with the text view focused.
        @Test(arguments: CancelInput.allCases)
        func cancelStopsPageLoad(input: CancelInput) async throws {
            URLProtocol.registerClass(StallingURLProtocol.self)
            Teardown.add { URLProtocol.unregisterClass(StallingURLProtocol.self) }
            Defaults[.readerOpensNewWindows] = false
            let reader = ReaderWindow.current
            reader.show(NSAttributedString(string: "Old text."), title: "Old")
            Teardown.add { reader.window.close() }
            reader.open(try #require(URL(string: "https://stall.test/page")))
            await settle(1.5)  // focused once the window is key (up to 1 s)
            let cancel = try #require(Self.button("Cancel", in: reader.window.contentView))
            #expect(!cancel.isHiddenOrHasHiddenAncestor)
            #expect(reader.window.firstResponder === cancel)
            switch input {
                case .click:
                    cancel.performClick(nil)
                case .space:
                    reader.window.sendEvent(try Self.key(" ", keyCode: 49, window: reader.window))
                case .escape:
                    #expect(reader.window.performKeyEquivalent(with: try Self.key("\u{1b}", keyCode: 53, window: reader.window)))
                case .commandPeriod:
                    #expect(reader.window.performKeyEquivalent(with: try Self.key(".", keyCode: 47, modifiers: .command, window: reader.window)))
            }
            await settle(0.3)
            #expect(cancel.isHiddenOrHasHiddenAncestor)
            #expect(reader.window.title == "Old")
            #expect(reader.textView.string == "Old text.")
            #expect(reader.window.firstResponder === reader.textView)
            #expect(reader.window.attachedSheet == nil, "a cancelled load isn't an error")
        }

        private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: keyCode))
        }

        private static func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }

        @Test func loadingMissingFileThrows() {
            #expect(throws: (any Error).self) {
                try ReaderWindow.current.loadFile(directory.appendingPathComponent("missing.txt"))
            }
        }
    }
}

/// Never answers, like a slow server.
private final class StallingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stall.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
