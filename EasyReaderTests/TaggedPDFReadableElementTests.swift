import AppKit
import PDFKit
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// A tagged PDF (printed by Chrome, `TaggedPDF.pdf`; source in the test): a heading, two paragraphs split into
    /// leaves at inline spans (bold words, a footnote mark), none selectable, and a second page without a heading.
    ///
    /// ```html
    /// <style>body { font: 16px Georgia; width: 5in } .next { break-before: page }</style>
    /// <h1>Tagged Test Document</h1>
    /// <p>The first sentence has <b>bold words</b> inside it. The second sentence is plain.</p>
    /// <p>A footnote mark<sup>a</sup> splits this sentence too. It ends the paragraph.</p>
    /// <p class="next">This page has no heading. Its sentences can't be selected, so they are highlighted instead.</p>
    /// ```
    @MainActor
    struct TaggedPDFReadableElementTests {
        private let window: NSWindow
        private let pdfView: PDFView

        init() async throws {
            pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
            pdfView.autoScales = true
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TaggedPDF.pdf")
            pdfView.document = try #require(PDFDocument(url: url))
            window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 500, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "AX Tagged PDF Test \(UUID().uuidString)"
            window.contentView = pdfView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(pdfView)
            let window = window
            Teardown.add { window.close() }
            await settle(0.3)
        }

        private func container() throws -> AXElement {
            let app = AXElement.application(pid: getpid())
            let windows = try #require(try app.attribute(.windows))
            var queue = [try #require(windows.first { (try? $0.attribute(.title) as String?) == window.title })]
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if try element.readableElement() is PDFReadableElement { return element }
                queue += (try? element.attribute(.children)) ?? []
            }
            throw NotFound()
        }

        private struct NotFound: Error {}

        private func readable() throws -> PDFReadableElement {
            try #require(try container().readableElement() as? PDFReadableElement)
        }

        /// The PDF view's selection, with line breaks as spaces.
        private var selected: String? {
            pdfView.currentSelection?.string?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }

        private func select(_ string: String, in readable: PDFReadableElement) throws {
            let text = try #require(readable.fullText) as NSString
            let range = text.range(of: string)
            try #require(range.location != NSNotFound, "\(string) not in \(text)")
            readable.selection = Selection(range)
        }

        /// The leaves can't be selected, but the heading's selection runs on through the page.
        @Test func selectsUnitSpanningLeavesThatCantBeSelected() throws {
            let readable = try readable()
            try select("The first sentence has bold words inside it.", in: readable)
            #expect(selected == "The first sentence has bold words inside it.")
            #expect(!readable.isHighlighting)
            try select("The second sentence is plain.", in: readable)
            #expect(selected == "The second sentence is plain.")
        }

        /// The mark's leaf has no separator before the next one in the page's text.
        @Test func selectsAcrossFootnoteMarkLeaf() throws {
            let readable = try readable()
            try select("A footnote mark a splits this sentence too.", in: readable)
            #expect(selected == "A footnote marka splits this sentence too.")
            #expect(!readable.isHighlighting)
        }

        @Test func highlightsOnPageWithoutSelectableLeaf() async throws {
            pdfView.go(to: try #require(pdfView.document?.page(at: 1)))
            await settle(0.3)
            let readable = try readable()
            try select("This page has no heading.", in: readable)
            #expect(readable.isHighlighting)
        }

        /// The user's selection starts in a leaf that can't be selected through AX; that leaf reports it.
        @Test func readsUserSelectionStartingInLeafThatCantBeSelected() throws {
            let page = try #require(try container().attribute(.children)?.first)
            var stack = [page]
            var heading: AXElement?
            while let element = stack.popLast(), heading == nil {
                if try element.role() == .staticText { heading = element }
                stack += ((try element.attribute(.children)) ?? []).reversed()
            }
            let pageText = try #require(pdfView.document?.page(at: 0)?.string) as NSString
            let range = pageText.range(of: "second sentence")
            try #require(heading).set(.selectedTextRange, to: CFRange(location: range.location, length: range.length))
            #expect(selected == "second sentence")
            let readable = try readable()
            _ = readable.selection
            #expect(readable.selectedText == "second sentence")
        }
    }
}
