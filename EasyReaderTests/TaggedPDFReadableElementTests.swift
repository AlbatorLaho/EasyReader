import AppKit
import PDFKit
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// `TaggedPDF.pdf`, printed by Chrome from:
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
            let url = try #require(Bundle(for: BundleToken.self).url(forResource: "TaggedPDF", withExtension: "pdf"))
            pdfView.document = try #require(PDFDocument(url: url))
            window = makeTestWindow(pdfView, title: "AX Tagged PDF Test", frame: NSRect(x: 200, y: 200, width: 500, height: 600))
            window.makeFirstResponder(pdfView)
            await settle(0.3)
        }

        private func readable() throws -> PDFReadableElement { try readableElement(in: window) }

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
            let page = try #require(try readable().handle.attribute(.children)?.first)
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

/// Finds the test bundle (its resources).
private final class BundleToken {}
