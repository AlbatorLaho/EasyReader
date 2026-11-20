import AVFoundation
import AppKit
import Defaults
import PDFKit
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// The real AX code against a `PDFView` in the host's own process: one `AXStaticText` leaf per paragraph.
    @MainActor
    struct PDFReadableElementTests {
        private let window: NSWindow
        private let pdfView: PDFView
        private let recorder = StateRecorder()
        static let pageCount = 30

        /// Two paragraphs per page (more on some); page 2's second runs on to page 3; pages 10–12 and 21 have only title and page number.
        static func paragraphs(page: Int) -> [String] {
            let opening = "Page \(page) opens here. This sentence on page \(page) is long enough to wrap across several lines of the narrow column."
            switch page {
                case 10...12, 21: return []
                case 2: return [opening, "A second paragraph on page 2. It runs on to the"]
                case 3: return ["next page, where it ends. " + opening, "A second paragraph on page 3. It ends the page."]
                case 4: return [opening, "Words like hyph-\nenated and self-\naware are split.", "A second paragraph on page 4. It ends the page."]
                case 27: return [opening, "A second paragraph on page 27 has boxes*. It ends the page."]
                case 28: return [opening, "A ruled note is marked4 here. It ends the page."]
                case 29: return [opening, "A verse has a letter mark here. It ends the page."]
                default: return [opening, "A second paragraph on page \(page). It ends the page."]
            }
        }

        init() async throws {
            PDFReadableElement.spellingLanguage = "en"
            Teardown.add { PDFReadableElement.spellingLanguage = nil }
            pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
            pdfView.autoScales = true
            pdfView.document = try #require(PDFDocument(data: try Self.makePDF()))
            window = makeTestWindow(pdfView, title: "AX PDF Test", frame: NSRect(x: 200, y: 200, width: 420, height: 500))
            window.makeFirstResponder(pdfView)
            await settle(0.3)
        }

        static func makePDF() throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = try #require(CGDataConsumer(data: data))
            let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
            let bold = try #require(NSFont(name: "Helvetica-Bold", size: 14))
            let large = try #require(NSFont(name: "Helvetica", size: 18))
            for page in 0..<pageCount {
                context.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                func draw(_ string: String, size: CGFloat, in rect: CGRect) {
                    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size)]).draw(in: rect)
                }
                // Another running title from page 22 on: page 22, loaded past the empty 21 without frames, can't confirm it.
                draw(page >= 22 ? "Appendix Title" : "Running Title", size: 10, in: CGRect(x: 72, y: 740, width: 300, height: 20))
                draw("\(page + 1)", size: 10, in: CGRect(x: 300, y: 20, width: 40, height: 20))
                switch page {
                    case 5:
                        // A superscript footnote mark, with its footnote.
                        let text = NSMutableAttributedString(
                            string: paragraphs(page: page)[0] + "\n\nA second paragraph has a marked",
                            attributes: [.font: NSFont.systemFont(ofSize: 14)])
                        text.append(
                            NSAttributedString(string: "z", attributes: [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 6]))
                        text.append(NSAttributedString(string: " word. It ends the page.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                        text.draw(in: CGRect(x: 72, y: 150, width: 300, height: 540))
                        draw("z The note.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20))
                    case 28, 29:
                        // Marked footnotes after a rule line (28) and starting with a chapter number larger than its text (29).
                        let (paragraph, mark) = page == 28 ? ("A ruled note is marked", "4") : ("A verse has a letter", "a")
                        let text = NSMutableAttributedString(
                            string: paragraphs(page: page)[0] + "\n\n" + paragraph, attributes: [.font: NSFont.systemFont(ofSize: 14)])
                        text.append(
                            NSAttributedString(string: mark, attributes: [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 6]))
                        let rest = page == 28 ? " here. It ends the page." : " mark here. It ends the page."
                        text.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                        text.draw(in: CGRect(x: 72, y: 150, width: 300, height: 540))
                        let note = NSMutableAttributedString(
                            string: page == 28 ? "______\n" : "1", attributes: [.font: NSFont.systemFont(ofSize: page == 28 ? 9 : 13)])
                        note.append(
                            NSAttributedString(
                                string: page == 28 ? "4 The ruled note." : " 1 a The verse note.",
                                attributes: [.font: NSFont.systemFont(ofSize: page == 28 ? 9 : 8)]))
                        note.draw(in: CGRect(x: 72, y: 60, width: 300, height: 40))
                    case 17, 18:
                        // An exponent and a footnote mark (superscripts), on a page with that footnote (17) and without (18).
                        let body = [.font: NSFont.systemFont(ofSize: 14)] as [NSAttributedString.Key: Any]
                        let superscript = [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 6] as [NSAttributedString.Key: Any]
                        let text = NSMutableAttributedString(string: paragraphs(page: page)[0] + "\n\nAn area of x", attributes: body)
                        text.append(NSAttributedString(string: "2", attributes: superscript))
                        text.append(NSAttributedString(string: " has a mark", attributes: body))
                        text.append(NSAttributedString(string: "3", attributes: superscript))
                        text.append(NSAttributedString(string: " here. It ends the page.", attributes: body))
                        text.draw(in: CGRect(x: 72, y: 150, width: 300, height: 540))
                        if page == 17 { draw("3 The note.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20)) }
                    case 6:
                        // A caption (smaller, mid-page) inside a sentence: read after the sentence's block.
                        draw(paragraphs(page: page)[0] + "\n\nA sentence before the", size: 14, in: CGRect(x: 72, y: 450, width: 300, height: 240))
                        draw("Figure 1: a caption.", size: 9, in: CGRect(x: 72, y: 410, width: 300, height: 20))
                        draw("caption ends here. It ends the page.", size: 14, in: CGRect(x: 72, y: 340, width: 300, height: 60))
                    case 2, 16:
                        // A superscript mark ending the first paragraph, for the footnote ending the page.
                        let text = NSMutableAttributedString(string: paragraphs(page: page)[0], attributes: [.font: NSFont.systemFont(ofSize: 14)])
                        text.append(
                            NSAttributedString(string: page == 2 ? "1" : "2", attributes: [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 6]))
                        text.append(
                            NSAttributedString(string: "\n\n" + paragraphs(page: page)[1], attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                        text.draw(in: CGRect(x: 72, y: 150, width: 300, height: 540))
                    default:
                        draw(paragraphs(page: page).joined(separator: "\n\n"), size: 14, in: CGRect(x: 72, y: 150, width: 300, height: 540))
                }
                if page == 2 { draw("1 A footnote on page 2.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20)) }
                // Small print ending the page: numbered without a body mark (26, read), a symbol with a full-size mark (27, skipped).
                if page == 26 { draw("1. Step one is small print.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20)) }
                if page == 27 { draw("* A starred note.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20)) }
                // Headings without a stop, not title case: bold in the paragraph's leaf (7) or its own (14), larger in the paragraph's (15).
                let headings: [Int: (String, NSFont, CGFloat)] = [
                    7: ("A bold heading without a stop", bold, 691),
                    14: ("A bold heading on its own", bold, 715),
                    15: ("A larger heading", large, 693),
                ]
                if let (heading, font, y) = headings[page] {
                    NSAttributedString(string: heading, attributes: [.font: font]).draw(in: CGRect(x: 72, y: y, width: 300, height: 24))
                }
                // Small print ending the page: a caption (read), then a footnote (skipped).
                if page == 16 {
                    draw("Figure 2: small print, not a footnote.", size: 9, in: CGRect(x: 72, y: 120, width: 300, height: 20))
                    draw("2 A second footnote.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20))
                }
                // Headings recurring two pages apart, below the margin.
                if page == 22 || page == 24 { draw("Part \(page / 2 - 8)", size: 14, in: CGRect(x: 72, y: 700, width: 300, height: 20)) }
                // A one-line paragraph in the bottom margin, unlike the other pages' margin lines.
                if page == 8 { draw("A short last line.", size: 14, in: CGRect(x: 72, y: 35, width: 300, height: 20)) }
                NSGraphicsContext.current = nil
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        private func makeReader() -> EasyReader { makeSilentReader(recorder: recorder) }

        private func readable() throws -> PDFReadableElement { try readableElement(in: window) }

        private var selected: String? {
            pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Selects `string` the way another AX client would (PDFKit's AX doesn't see `PDFView.setCurrentSelection`).
        private func axSelect(_ string: String, page: Int) throws {
            let container = try readable().handle
            let pageElement = try #require(try container.attribute(.children)?[page])
            var stack = [pageElement]
            while let element = stack.popLast() {
                if try element.role() == .staticText, let value: String = try element.attribute(.value) {
                    let range = (PDFReadableElement.flattened(value).0 as NSString).range(of: string)
                    if range.location != NSNotFound {
                        try element.set(.selectedTextRange, to: CFRange(location: range.location, length: range.length))
                        return
                    }
                }
                stack += (try element.attribute(.children)) ?? []
            }
            throw NotFound(what: "\(string.debugDescription) on page \(page)")
        }

        private func go(toPage index: Int) async throws {
            pdfView.go(to: try #require(pdfView.document?.page(at: index)))
            await settle(0.3)
        }

        private func next(_ readable: PDFReadableElement, _ direction: Selection.Direction = .forward) throws -> String {
            let selector = NLTextSelector(unit: .sentence)
            let text = try #require(readable.fullText)
            let current = try #require(readable.selection)
            readable.selection = selector.select(direction, from: current, in: text, blocks: { readable.textBlock(containing: $0) })
            return try #require(readable.selectedText).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @Test func findsPDFStartingFromWindow() throws {
            let reader = makeReader()
            #expect(reader.start(reading: .element(try axWindow(of: window))))
            #expect(reader.readable is PDFReadableElement)
        }

        /// Line breaks inside a paragraph become spaces, so a sentence wrapping across lines is one unit.
        @Test func readsWrappedSentenceAsOneUnit() throws {
            let readable = try readable()
            let text = try #require(readable.fullText)
            let sentence = "This sentence on page 0 is long enough to wrap across several lines of the narrow column."
            #expect(text.contains(sentence))
            #expect(try next(readable) == "Page 0 opens here.")
            #expect(try next(readable) == sentence)
        }

        @Test func settingSelectionSelectsInPDFView() throws {
            let readable = try readable()
            _ = try next(readable)
            #expect(selected == "Page 0 opens here.")
            #expect(!readable.isHighlighting)
        }

        /// Units stay inside a paragraph (leaf), and stepping on past the loaded page loads the next ones.
        @Test func stepsAcrossParagraphsAndPages() throws {
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<9 { units.append(try next(readable)) }
            #expect(units.contains("It ends the page."))
            #expect(units.contains("Page 1 opens here."))
            #expect(units.contains("Page 2 opens here."))
            #expect(!units.contains { $0.contains("\n") })
            #expect(selected == units.last)
        }

        @Test func readsUserSelection() async throws {
            try axSelect("It ends the page.", page: 0)
            let readable = try readable()
            #expect(readable.selectedText == "It ends the page.")
            // A selection made while reading (on the page now on screen) replaces the tracked one.
            #expect(try next(readable) == "Page 1 opens here.")
            try axSelect("A second paragraph on page 1.", page: 1)
            _ = readable.selection
            #expect(readable.selectedText == "A second paragraph on page 1.")
        }

        /// Selecting the text taken before again, after reading moved on, starts there again.
        @Test func readsSameUserSelectionAgain() throws {
            try axSelect("It ends the page.", page: 0)
            let readable = try readable()
            #expect(readable.selectedText == "It ends the page.")
            #expect(try next(readable) == "Page 1 opens here.")
            try axSelect("It ends the page.", page: 0)
            _ = readable.selection
            #expect(readable.selectedText == "It ends the page.")
        }

        /// A user selection far away that isn't in the text (a running title) keeps the unit being read.
        @Test func keepsUnitWhenUserSelectionIsNotInText() async throws {
            let readable = try readable()
            #expect(try next(readable) == "Page 0 opens here.")
            try await go(toPage: 20)
            try axSelect("Running Title", page: 20)
            #expect(readable.selection != nil)
            #expect(readable.selectedText?.trimmingCharacters(in: .whitespaces) == "Page 0 opens here.")
        }

        /// Wrapping around (the selection put at the text's start) reads from the document's start, not the window's.
        @Test func contentStartIsDocumentStart() async throws {
            try await go(toPage: 20)
            let readable = try readable()
            #expect(!(try #require(readable.fullText)).contains("Page 0 opens"))
            let start = readable.contentStart
            readable.selection = Selection(start..<start)
            #expect(try next(readable) == "Page 0 opens here.")
        }

        /// With only the bottom margin of the first visible page on screen, reading starts on the next page.
        @Test func startsOnNextPageBelowSliver() async throws {
            let page = try #require(pdfView.document?.page(at: 0))
            pdfView.go(to: PDFDestination(page: page, at: NSPoint(x: 0, y: 12)))
            await settle(0.3)
            #expect(try next(try readable()) == "Page 1 opens here.")
        }

        /// Starting in the middle of a long PDF loads only pages near there; going back loads earlier ones.
        @Test func startsAtVisiblePageAndLoadsEarlierPages() async throws {
            try await go(toPage: 20)
            let readable = try readable()
            let text = try #require(readable.fullText)
            #expect(!text.contains("Page 0 opens"))
            #expect(try next(readable) == "Page 20 opens here.")
            #expect(try next(readable, .backward) == "It ends the page.")
            #expect(try #require(readable.fullText).contains("Page 19 opens here."))
        }

        /// PDFKit ignores selections on pages off screen: the leaf is scrolled into view first.
        @Test func selectsOnPageOffScreen() async throws {
            let readable = try readable()
            for _ in 0..<12 { _ = try next(readable) }  // loads pages ahead of the visible one
            let text = try #require(readable.fullText)
            let target = try Selection(of: "Page 1 opens here.", in: text)
            try await go(toPage: 25)
            readable.selection = target
            #expect(selected == "Page 1 opens here.")
        }

        @Test func scrollBringsSelectionIntoView() async throws {
            let readable = try readable()
            for _ in 0..<12 { _ = try next(readable) }
            let selection = try #require(readable.selection)
            try await go(toPage: 0)
            readable.scroll(to: selection, options: ScrollOptions(padding: 16, duration: 0))
            await settle(0.3)
            let page = try #require(pdfView.currentSelection?.pages.first)
            #expect(pdfView.visiblePages.contains(page))
            #expect(pdfView.document?.index(for: page) != 0)
        }

        @Test func skipsRunningTitleAndPageNumber() throws {
            let text = try #require(try readable().fullText)
            #expect(text.contains("Page 0 opens here."))
            #expect(!text.contains("Running Title"))
            #expect(!text.split(separator: "\n").contains { Int($0.trimmingCharacters(in: .whitespaces)) != nil })
        }

        /// With `cleanUpPDFText` off, headers/footers, footnotes and their marks are read.
        @Test func readsHeadersAndFootnotesWithoutCleanup() async throws {
            Defaults[.cleanUpPDFText] = false
            try await go(toPage: 17)
            let readable = try readable()
            let text = try #require(readable.fullText)
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(lines.contains("Running Title"), "\(text)")
            // A page number runs on into the next page's header (no stop ends it).
            #expect(lines.contains("18 Running Title"), "\(text)")
            #expect(lines.contains("3 The note."), "\(text)")
            readable.selection = try Selection(of: "An area of x2 has a mark3 here.", in: text)
            #expect(readable.selectedText == "An area of x2 has a mark3 here.")
        }

        /// A heading line is a unit of its own, whether PDFKit puts it in the paragraph's leaf or its own.
        @Test(arguments: [(7, "A bold heading without a stop", false), (14, "A bold heading on its own", true), (15, "A larger heading", false)])
        func headingIsItsOwnUnit(page: Int, heading: String, ownLeaf: Bool) async throws {
            try await go(toPage: page)
            let readable = try readable()
            #expect(try leafValues(page: page).contains(heading) == ownLeaf)
            var units: [String] = []
            for _ in 0..<2 { units.append(try next(readable)) }
            #expect(units == [heading, "Page \(page) opens here."])
        }

        private func leafValues(page: Int) throws -> [String] {
            var values: [String] = []
            var stack = [try #require(try readable().handle.attribute(.children)?[page])]
            while let element = stack.popLast() {
                if try element.role() == .staticText { values.append(try element.attribute(.value) ?? "") }
                stack += (try element.attribute(.children)) ?? []
            }
            return values
        }

        /// A selection in a skipped footnote reads the page's footnotes from there.
        @Test func readsFootnoteUserSelected() async throws {
            try await go(toPage: 2)
            try axSelect("A footnote on page 2.", page: 2)
            let readable = try readable()
            #expect(readable.selectedText == "A footnote on page 2.")
            #expect(try #require(readable.fullText).contains("1 A footnote on page 2."))
            #expect(try next(readable) == "A second paragraph on page 3.")
        }

        /// A short selection left far away that a footnote here contains doesn't bring the footnotes back.
        @Test func skipsFootnoteMatchingStaleSelection() async throws {
            try await go(toPage: 5)
            try axSelect("The note.", page: 5)
            try await go(toPage: 17)
            let readable = try readable()
            #expect(!(try #require(readable.fullText)).contains("3 The note."))
            #expect(try next(readable) == "Page 17 opens here.")
        }

        @Test func readsUnmarkedSmallPrintEndingPage() async throws {
            try await go(toPage: 16)
            let text = try #require(try readable().fullText)
            #expect(text.contains("Figure 2: small print, not a footnote."))
            #expect(!text.contains("A second footnote"))
        }

        /// Small print starting like a footnote, but with no matching mark in the body, is read.
        @Test func readsMarkedSmallPrintWithoutBodyMark() async throws {
            try await go(toPage: 26)
            #expect(try #require(try readable().fullText).contains("1. Step one is small print."))
        }

        /// A symbol footnote is skipped when the body has its mark, even at full size.
        @Test func skipsSymbolFootnoteWithFullSizeMark() async throws {
            try await go(toPage: 27)
            let text = try #require(try readable().fullText)
            #expect(text.contains("has boxes*."))
            #expect(!text.contains("A starred note."))
        }

        /// A footnote after a rule line (28), or starting with a chapter number near body size (29), is skipped and its mark not read.
        @Test(arguments: [
            (28, "A ruled note is marked4 here.", "A ruled note is marked\u{2060} here."),
            (29, "A verse has a lettera mark here.", "A verse has a letter\u{2060} mark here."),
        ])
        func skipsFootnoteStartingUnlikeIt(page: Int, sentence: String, spoken: String) async throws {
            try await go(toPage: page)
            let readable = try readable()
            let text = try #require(readable.fullText)
            #expect(!text.contains("The ruled note") && !text.contains("The verse note"), "\(text)")
            #expect(!text.contains("_"), "\(text)")
            readable.selection = try Selection(of: sentence, in: text)
            #expect(readable.selectedText == spoken)
        }

        /// A margin line that doesn't repeat on nearby pages isn't a header or footer.
        @Test func readsUniqueLineInMargin() async throws {
            try await go(toPage: 8)
            #expect(try #require(try readable().fullText).contains("A short last line."))
        }

        /// Pages loaded ahead (no leaf frames) lose headers/footers seen in the margin of any page before: empty pages 10–12 are skipped.
        @Test func skipsHeadersOnPagesLoadedAhead() async throws {
            try await go(toPage: 9)
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<6 { units.append(try next(readable)) }
            #expect(units.contains("Page 13 opens here."), "\(units)")
            #expect(!units.contains { Int($0) != nil }, "\(units)")
            // Page 13 is more than two pages from any page with frames (8–10), which confirmed the header.
            #expect(!units.contains { $0.contains("Running Title") }, "\(units)")
        }

        /// A first line of a frameless page (22) recurring on a nearby frameless page (24) isn't taken for a header.
        @Test func readsRecurringLineOnPagesWithoutFrames() async throws {
            try await go(toPage: 20)
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<8 { units.append(try next(readable)) }
            #expect(units.contains("Page 22 opens here."), "\(units)")
            #expect(units.contains { $0.contains("Part 3") }, "\(units)")
            #expect(!units.contains { $0.contains("Running Title") || Int($0) != nil }, "\(units)")
        }

        /// A header read on a frameless page (22) is left out once a page with frames confirms it; reading goes on from the leaf after it.
        @Test func dropsHeaderConfirmedAfterItsPageLoaded() async throws {
            try await go(toPage: 20)
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<7 { units.append(try next(readable)) }
            #expect(Array(units.suffix(3)) == ["Appendix Title", "Part 3", "Page 22 opens here."], "\(units)")
            #expect(!(try #require(readable.fullText)).contains("Appendix Title"))
        }

        /// A sentence running on from one page to the next is one unit; the footnote in between comes after its block.
        @Test func joinsSentenceAcrossPages() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<7 { units.append(try next(readable)) }
            let runOn = try #require(units.firstIndex(of: "It runs on to the next page, where it ends."), "\(units)")
            #expect(units[runOn + 1] == "Page 3 opens here.")
            // Small print at the end of a page is a footnote: skipped.
            #expect(!(try #require(readable.fullText)).contains("footnote"))
        }

        /// Smaller text inside a sentence (not at the end of the page) comes after the sentence's block.
        @Test func defersCaptionInsideSentence() async throws {
            try await go(toPage: 6)
            let readable = try readable()
            var units: [String] = []
            for _ in 0..<5 { units.append(try next(readable)) }
            let sentence = try #require(units.firstIndex(of: "A sentence before the caption ends here."), "\(units)")
            #expect(Array(units.dropFirst(sentence + 1).prefix(2)) == ["It ends the page.", "Figure 1: a caption."])
        }

        /// Superscript footnote marks (with their footnote on the page) stay in the text (selection) but aren't read.
        @Test func skipsFootnoteMarks() async throws {
            try await go(toPage: 5)
            let readable = try readable()
            let text = try #require(readable.fullText)
            let start = try Selection(of: "A second paragraph has a marked", in: text)
            readable.selection = Selection(start.lowerBound..<start.upperBound + 7)
            let spoken = try #require(readable.selectedText)
            #expect(!spoken.contains("z"), "\(spoken.debugDescription)")
            #expect(spoken.utf16.count == start.count + 7)
            #expect(selected?.contains("z") == true)
            #expect(!readable.isHighlighting)
        }

        /// With footnotes on the page, a superscript that isn't one's mark (an exponent) is read.
        @Test func readsExponentOnPageWithFootnotes() async throws {
            try await go(toPage: 17)
            let readable = try readable()
            let text = try #require(readable.fullText)
            readable.selection = try Selection(of: "An area of x2 has a mark3 here.", in: text)
            #expect(readable.selectedText == "An area of x2 has a mark\u{2060} here.")
        }

        /// Without footnotes on the page, no superscript is taken for a mark: all are read.
        @Test func readsSuperscriptsOnPageWithoutFootnotes() async throws {
            try await go(toPage: 18)
            let readable = try readable()
            let text = try #require(readable.fullText)
            readable.selection = try Selection(of: "An area of x2 has a mark3 here.", in: text, options: .backwards)
            #expect(readable.selectedText == "An area of x2 has a mark3 here.")
        }

        /// PDFKit selects within one leaf: a unit spanning two is selected piece by piece as speech reaches each.
        @Test func selectsPiecesOfUnitAcrossPages() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            let text = try #require(readable.fullText)
            let unit = try Selection(of: "It runs on to the next page, where it ends.", in: text)
            readable.selection = unit
            #expect(!readable.isHighlighting)
            let first = try #require(selected)
            #expect("It runs on to the".hasPrefix(first.replacingOccurrences(of: "\n", with: " ")))
            #expect(readable.didReach(3) == nil)  // still in the first piece
            let second = try #require(readable.didReach("It runs on to the ".utf16.count))
            #expect(selected == "next page, where it ends.")
            #expect((text as NSString).substring(with: NSRange(second)).hasPrefix("next page"))
            // The piece selected isn't taken for a new selection by the user.
            #expect(readable.selection == unit)
            #expect(readable.didReach(30) == nil)
        }

        /// A re-layout that shifts leaf indices (an earlier page loaded) keeps the pieces on the unit's text.
        @Test func piecesFollowRelayout() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            let text = try #require(readable.fullText)
            readable.selection = try Selection(of: "It runs on to the next page, where it ends.", in: text)
            readable.setWindow(0..<5)
            #expect(readable.didReach("It runs on to the ".utf16.count) != nil)
            #expect(selected == "next page, where it ends.")
        }

        /// Each layout covers every loaded page, so reading on cuts the window back.
        @Test func windowStaysBoundedWhileReadingOn() throws {
            let readable = try readable()
            var largest = 0
            var unit = ""
            var steps = 0
            while steps < 400, unit != "Page 25 opens here." {
                unit = try next(readable)
                largest = max(largest, readable.loadedPageCount)
                steps += 1
            }
            #expect(unit == "Page 25 opens here.")
            #expect(readable.loadedPageCount <= PDFReadableElement.maxLoadedPages)
            // Plus pages 10–12: nothing readable on them, so the window runs on across them.
            #expect(largest <= PDFReadableElement.maxLoadedPages + 3)
        }

        /// While reading, the selection follows speech from piece to piece.
        @Test func readingMovesSelectionToNextPiece() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            let text = try #require(readable.fullText)
            readable.selection = try Selection(of: "It runs on to the next page, where it ends.", in: text)
            let reader = makeReader()
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate  // slow enough to see the pieces
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            try await waitUntil(timeout: 5, "selection on the second piece") { selected == "next page, where it ends." }
        }

        /// A word hyphenated at a line break is read whole; a hyphen that's part of the word stays.
        @Test func joinsHyphenatedWords() async throws {
            try await go(toPage: 4)
            let readable = try readable()
            let text = try #require(readable.fullText)
            #expect(text.contains("Words like hyph\u{2060}\u{2060}enated and self-\u{2060}aware are split."))
            readable.selection = try Selection(of: "Words like hyph\u{2060}\u{2060}enated and self-\u{2060}aware are split.", in: text)
            #expect(selected?.replacingOccurrences(of: "\n", with: "") == "Words like hyph-enated and self-aware are split.")
            #expect(!readable.isHighlighting)
        }

        @Test func readsAndAdvances() async throws {
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: try readable()))
            try await reading.wait(timeout: 10)
            // Maximum rate: the first units go by fast, so only check that the selection moved on.
            try await waitUntil(timeout: 5, "selection to move on") { ![nil, "Page 0 opens here."].contains(selected) }
            let unit = try #require(selected)
            #expect(try #require(reader.readable?.fullText).contains(PDFReadableElement.flattened(unit).0))
        }
    }
}
