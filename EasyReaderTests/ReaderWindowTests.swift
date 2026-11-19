import AVFoundation
import AppKit
import Defaults
import Foundation
import PDFKit
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

        private func readable(in reader: ReaderWindow) throws -> ReadableElement {
            let app = AXElement.application(pid: getpid())
            let windows = try #require(try app.attribute(.windows))
            var queue = windows.filter { (try? $0.attribute(.identifier)) == reader.window.accessibilityIdentifier() }
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if let readable = try element.readableElement() { return readable }
                queue += (try? element.attribute(.children)) ?? []
            }
            throw ReaderTextAreaNotFound()
        }

        /// New content stops reading its window, and only that one, even when another has the same title.
        @Test func newContentStopsReadingOnlyItsWindow() async throws {
            Defaults[.readerOpensNewWindows] = true
            let recorder = StateRecorder()
            let easyReader = EasyReader()
            easyReader.delegate = recorder
            easyReader.textSelector = NLTextSelector(unit: .paragraph)
            ReaderWindow.reader = easyReader
            Teardown.add {
                easyReader.stop()
                ReaderWindow.reader = nil
                for readerWindow in ReaderWindow.windows { readerWindow.window.close() }
            }
            let text = NSAttributedString(string: Array(repeating: "Some words to read for a while.", count: 40).joined(separator: " "))
            let first = ReaderWindow.current
            first.show(text, title: "Same")
            first.window.makeKeyAndOrderFront(nil)
            let second = ReaderWindow.forNewContent()
            #expect(second !== first)
            second.show(text, title: "Same")
            second.window.makeKeyAndOrderFront(nil)
            await settle(0.3)
            let reading = recorder.expect(.reading)
            #expect(easyReader.start(reading: try readable(in: second)))
            try await reading.wait(timeout: 5)
            first.show(text, title: "Same")
            #expect(easyReader.state == .reading)
            let stopped = recorder.expect(.stopped)
            second.show(text, title: "Same")
            try await stopped.wait(timeout: 5)
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

        /// With "Open each document in a new window", each file gets a window (the empty front one first); without, one window takes the first file.
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

        /// Cancel (Space while focused, Esc, ⌘.) stops a page load waiting for the server; the title and text view focus come back.
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

        private func writePDF(_ name: String = "Document.pdf") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try PDFReadableElementTests.makePDF().write(to: url)
            return url
        }

        private func writeText(_ text: String = "Some text.") throws -> URL {
            let url = directory.appendingPathComponent("Text.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        private func showsPDF(_ reader: ReaderWindow) -> Bool {
            reader.documentView === reader.pdfView && reader.pdfView.superview === reader.window.contentView
                && reader.textScrollView.superview == nil
        }

        private func showsText(_ reader: ReaderWindow) -> Bool {
            reader.documentView === reader.textView && reader.textScrollView.superview === reader.window.contentView
                && reader.pdfView.superview == nil && reader.pdfView.document == nil
        }

        @Test func loadsPDFFileInPDFView() throws {
            let url = try writePDF()
            let reader = ReaderWindow.current
            try reader.loadFile(url)
            #expect(showsPDF(reader))
            #expect(reader.pdfView.document?.pageCount == PDFReadableElementTests.pageCount)
            #expect(reader.pdfView.document?.page(at: 0)?.string?.contains("Page 0 opens here.") == true)
            #expect(reader.window.title == "Document.pdf")
            #expect(reader.window.representedURL == url)
            #expect(reader.textView.string.isEmpty)
            #expect(!reader.isEmpty)
        }

        /// A web page that turns out to be a PDF shows in the PDF view too.
        @Test func loadsPDFPage() async throws {
            let reader = ReaderWindow.current
            try await reader.loadPage(try writePDF("Paper.pdf"))
            #expect(showsPDF(reader))
            #expect(reader.window.title == "Paper.pdf")
        }

        /// With one window, opening text after a PDF swaps the text view back in, and the other way round.
        @Test func swapsViewsBetweenPDFAndText() async throws {
            Defaults[.readerOpensNewWindows] = false
            let pdf = try writePDF()
            let text = try writeText()
            let reader = ReaderWindow.current
            reader.window.makeKeyAndOrderFront(nil)
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            ReaderWindow.open([pdf])
            await settle(0.5)
            #expect(ReaderWindow.front === reader)
            #expect(showsPDF(reader))
            #expect(reader.window.firstResponder === reader.pdfView)
            ReaderWindow.open([text])
            await settle(0.5)
            #expect(ReaderWindow.front === reader)
            #expect(showsText(reader))
            #expect(reader.textView.string == "Some text.")
            #expect(reader.window.firstResponder === reader.textView)
            ReaderWindow.open([pdf])
            await settle(0.5)
            #expect(showsPDF(reader))
        }

        /// A PDF counts as content: with "Open each document in a new window", the next file gets its own window.
        @Test func pdfWindowIsNotEmpty() async throws {
            Defaults[.readerOpensNewWindows] = true
            let front = ReaderWindow.current
            try front.loadFile(try writePDF())
            front.window.makeKeyAndOrderFront(nil)
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            await settle(0.1)
            #expect(ReaderWindow.forNewContent() !== front)
        }

        /// A PDF dropped or found in an Open panel is a reader window file.
        @Test func pdfIsReaderContent() throws {
            let url = try writePDF()
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyReaderTests-\(UUID().uuidString)"))
            Teardown.add { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            guard case .url(let found) = ReaderWindow.content(of: pasteboard, allowText: false) else {
                Issue.record("PDF not taken")
                return
            }
            #expect(found == url)
        }

        /// An unsupported file isn't read as text (its path, which a drag may carry as a string).
        @Test func unsupportedFileIsNotReaderContent() throws {
            let url = directory.appendingPathComponent("Archive.zip")
            try Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)).write(to: url)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyReaderTests-\(UUID().uuidString)"))
            Teardown.add { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
            pasteboard.addTypes([.string], owner: nil)
            pasteboard.setString(url.path, forType: .string)
            #expect(ReaderWindow.content(of: pasteboard, allowText: true) == nil)
        }

        enum StartPath: String, CaseIterable { case toolbarStart, readService }

        /// The toolbar's Start, and Read with EasyReader on a PDF file, read the PDF from its first page through AX.
        @Test(arguments: StartPath.allCases)
        func readsPDFFromStart(path: StartPath) async throws {
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.readerOpensNewWindows] = false
            let recorder = StateRecorder()
            let easyReader = EasyReader()
            easyReader.delegate = recorder
            easyReader.textSelector = NLTextSelector(unit: .sentence)
            ReaderWindow.reader = easyReader
            Teardown.add {
                easyReader.stop()
                ReaderWindow.reader = nil
                for readerWindow in ReaderWindow.windows { readerWindow.window.close() }
            }
            let url = try writePDF()
            let reading = recorder.expect(.reading)
            switch path {
                case .toolbarStart:
                    ReaderWindow.open([url])
                    await settle(1.5)  // shown once the window is key (up to 1 s)
                    let reader = try #require(ReaderWindow.front)
                    let start = try #require(reader.window.toolbar?.items.first { $0.itemIdentifier.rawValue == PlaybackControl.startStop.rawValue })
                    #expect(NSApp.sendAction(try #require(start.action), to: start.target, from: start))
                case .readService:
                    let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyReaderTests-\(UUID().uuidString)"))
                    Teardown.add { pasteboard.releaseGlobally() }
                    pasteboard.clearContents()
                    pasteboard.writeObjects([url as NSURL])
                    #expect(ReaderWindow.read(pasteboard))
            }
            try await reading.wait(timeout: 10)
            let reader = try #require(ReaderWindow.front)
            #expect(showsPDF(reader))
            #expect(easyReader.readable is PDFReadableElement)
            #expect(easyReader.readable?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == "Page 0 opens here.")
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
