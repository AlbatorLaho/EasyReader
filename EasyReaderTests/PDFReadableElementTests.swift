import AVFoundation
import AppKit
import Defaults
import PDFKit
import Testing

@testable import EasyReader

@Suite struct PDFTextTests {
    typealias Info = PDFReadableElement.LeafInfo

    @Test func flattenedKeepsOffsets() {
        let (flat, lineBreaks) = PDFReadableElement.flattened("One line\nwraps 😀 here.\r\nEnd")
        #expect(flat == "One line wraps 😀 here.  End")
        #expect(lineBreaks == [8, 23, 24])
        #expect(flat.utf16.count == "One line\nwraps 😀 here.\r\nEnd".utf16.count)
    }

    /// Word joiners keep the length (offsets map back to the leaf); a hyphen that's part of the word stays.
    @Test func dehyphenateJoinsWordsBrokenAtLineEnds() {
        let value = "be-\ncause self-\naware X-\nRay 3-\nd"
        let (flat, lineBreaks) = PDFReadableElement.flattened(value)
        var units = Array(flat.utf16)
        PDFReadableElement.dehyphenate(&units, lineBreaks: lineBreaks) { $0 == "because" }
        #expect(String(decoding: units, as: UTF16.self) == "be\u{2060}\u{2060}cause self-\u{2060}aware X- Ray 3- d")
        #expect(units.count == value.utf16.count)
    }

    /// PDFKit's report keeps line breaks and hyphens where our text has spaces and word joiners.
    @Test func userSelectionEndsWhereItsTextDoes() {
        let text = "Intro. A sen\u{2060}\u{2060}tence runs on. Next one."
        let report = "A sen-\ntence runs\non."
        #expect(PDFReadableElement.end(of: report, in: text, from: 7) == 28)
        #expect(PDFReadableElement.end(of: "😀 b", in: "x 😀 b c", from: 2) == 6)
        #expect(PDFReadableElement.end(of: "longer than the text", in: text, from: 30) == text.utf16.count)
        #expect(PDFReadableElement.end(of: "\n", in: text, from: 7) == 7)
    }

    @Test(
        arguments: [
            ("ends mid", true), ("ends here.", false), ("asks?\n", false), ("quoted.”", false), ("so:", false),
            ("a list;", true), ("hyphen-", true), ("", false), ("(closed.) ", false),
        ] as [(String, Bool)])
    func endsMidSentence(text: String, expected: Bool) {
        #expect(PDFReadableElement.endsMidSentence(text) == expected)
    }

    @Test func joinRules() {
        let join = { (a: Info, b: Info) in PDFReadableElement.join(a, b, isWord: { $0 == "because" }) }
        #expect(join(Info(text: "as he"), Info(text: "read, he")) == .space)
        #expect(join(Info(text: "Ends.\n"), Info(text: "next")) == .none)
        #expect(join(Info(text: "be-"), Info(text: "cause")) == .hyphen(keepsHyphen: false))
        #expect(join(Info(text: "self-"), Info(text: "aware")) == .hyphen(keepsHyphen: true))
        // Font size: about the same joins, clearly different doesn't.
        #expect(join(Info(text: "as he", fontSize: 10), Info(text: "read", fontSize: 10.4)) == .space)
        #expect(join(Info(text: "as he", fontSize: 10), Info(text: "5 a Jer.", fontSize: 8)) == .none)
        #expect(join(Info(text: "Big title", fontSize: 24), Info(text: "body", fontSize: 12)) == .none)
        // Headings: in an AXHeading, or one title-case line before a capital (an inline title-case run still joins).
        #expect(join(Info(text: "Introduction", isHeading: true), Info(text: "text")) == .none)
        #expect(join(Info(text: "PRESENT CODE — ACTIVITY"), Info(text: "Today you")) == .none)
        #expect(join(Info(text: "Quality of Life Wheel"), Info(text: "where a person")) == .space)
        #expect(join(Info(text: "This is a sample"), Info(text: "Quality of Life Wheel")) == .space)
    }

    /// A title-case line doesn't open a sentence that smaller text after it would be deferred for.
    @Test func runsOn() {
        #expect(PDFReadableElement.runsOn(Info(text: "spake")))
        #expect(!PDFReadableElement.runsOn(Info(text: "The First Book of Nephi")))
        #expect(!PDFReadableElement.runsOn(Info(text: "Chapter", isHeading: true)))
    }

    @Test func footnotesAreSmallPrintEndingThePage() {
        let page: [(fontSize: CGFloat?, length: Int)] = [(10, 900), (10, 20), (8, 300), (8, 200)]
        #expect(PDFReadableElement.footnoteStart(page) { _ in true } == 2)
        #expect(PDFReadableElement.footnoteStart(page) { _ in nil } == 2)
        #expect(PDFReadableElement.footnoteStart(page) { $0 == 3 } == 3)  // index 2 in the upper half: not a footnote
        #expect(PDFReadableElement.footnoteStart([(8, 300), (8, 200)]) { _ in true } == 2)  // all one size: none
        #expect(PDFReadableElement.footnoteStart([(10, 900), (nil, 50)]) { _ in true } == 2)  // size unknown: kept
    }

    @Test func footnoteMarksAreShortSuperscriptRuns() {
        let text = "his a heart, word12 here and x7y and big"
        func run(_ location: Int, _ length: Int, _ size: CGFloat) -> (range: NSRange, fontSize: CGFloat?) {
            (NSRange(location: location, length: length), size)
        }
        let runs = [
            run(0, 4, 10), run(4, 2, 6),  // "a "
            run(6, 11, 10), run(17, 2, 6),  // "12"
            run(19, 10, 10), run(29, 3, 9),  // "x7y" at 90%: not a mark
            run(32, 8, 10),
        ]
        #expect(PDFReadableElement.markerRanges(runs, in: text) == [NSRange(location: 4, length: 1), NSRange(location: 17, length: 2)])
    }

    @Test func marginIsTopAndBottomOfPage() {
        let page = CGRect(x: 0, y: 1000, width: 600, height: 800)
        #expect(PDFReadableElement.isInMargin(CGRect(x: 50, y: 1020, width: 100, height: 20), of: page))
        #expect(PDFReadableElement.isInMargin(CGRect(x: 50, y: 1760, width: 100, height: 20), of: page))
        #expect(!PDFReadableElement.isInMargin(CGRect(x: 50, y: 1100, width: 100, height: 20), of: page))
        #expect(!PDFReadableElement.isInMargin(.zero, of: page))
    }
}

extension IntegrationTests {
    /// The real AX code against a `PDFView` in the host's own process: one `AXStaticText` leaf per paragraph.
    @MainActor
    struct PDFReadableElementTests {
        private let window: NSWindow
        private let pdfView: PDFView
        private let recorder = StateRecorder()
        static let pageCount = 30

        /// Two paragraphs per page (more on some); page 2's second runs on to page 3, past a footnote.
        static func paragraphs(page: Int) -> [String] {
            let opening = "Page \(page) opens here. This sentence on page \(page) is long enough to wrap across several lines of the narrow column."
            switch page {
                case 2: return [opening, "A second paragraph on page 2. It runs on to the"]
                case 3: return ["next page, where it ends. " + opening, "A second paragraph on page 3. It ends the page."]
                case 4: return [opening, "Words like hyph-\nenated and self-\naware are split.", "A second paragraph on page 4. It ends the page."]
                default: return [opening, "A second paragraph on page \(page). It ends the page."]
            }
        }

        init() async throws {
            pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
            pdfView.autoScales = true
            pdfView.document = try #require(PDFDocument(data: Self.makePDF()))
            window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 420, height: 500),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "AX PDF Test \(UUID().uuidString)"
            window.contentView = pdfView
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(pdfView)
            let window = window
            Teardown.add { window.close() }
            await settle(0.3)
        }

        private static func makePDF() -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
            for page in 0..<pageCount {
                context.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                func draw(_ string: String, size: CGFloat, in rect: CGRect) {
                    NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size)]).draw(in: rect)
                }
                draw("Running Title", size: 10, in: CGRect(x: 72, y: 740, width: 300, height: 20))
                draw("\(page + 1)", size: 10, in: CGRect(x: 300, y: 20, width: 40, height: 20))
                switch page {
                    case 5:
                        // A superscript footnote mark.
                        let text = NSMutableAttributedString(
                            string: paragraphs(page: page)[0] + "\n\nA second paragraph has a marked",
                            attributes: [.font: NSFont.systemFont(ofSize: 14)])
                        text.append(
                            NSAttributedString(string: "z", attributes: [.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 6]))
                        text.append(NSAttributedString(string: " word. It ends the page.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
                        text.draw(in: CGRect(x: 72, y: 150, width: 300, height: 540))
                    case 6:
                        // A caption (smaller, mid-page) inside a sentence: read after the sentence's block.
                        draw(paragraphs(page: page)[0] + "\n\nA sentence before the", size: 14, in: CGRect(x: 72, y: 450, width: 300, height: 240))
                        draw("Figure 1: a caption.", size: 9, in: CGRect(x: 72, y: 410, width: 300, height: 20))
                        draw("caption ends here. It ends the page.", size: 14, in: CGRect(x: 72, y: 340, width: 300, height: 60))
                    default:
                        draw(paragraphs(page: page).joined(separator: "\n\n"), size: 14, in: CGRect(x: 72, y: 150, width: 300, height: 540))
                }
                if page == 2 { draw("1 A footnote on page 2.", size: 9, in: CGRect(x: 72, y: 80, width: 300, height: 20)) }
                NSGraphicsContext.current = nil
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        /// Silent reader, as in EasyReaderSpeechTests.
        private func makeReader() -> EasyReader {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.pauseBetweenUnits] = 0
            Defaults[.speechStopBoundary] = .immediate
            let reader = EasyReader()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            Teardown.add { reader.stop() }
            return reader
        }

        private func axWindow() throws -> AXElement {
            let app = AXElement.application(pid: getpid())
            let windows = try #require(try app.attribute(.windows))
            return try #require(windows.first { (try? $0.attribute(.title) as String?) == window.title }, "test window not in AX tree")
        }

        private func readable() throws -> PDFReadableElement {
            var queue = [try axWindow()]
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if let readable = try element.readableElement() {
                    return try #require(readable as? PDFReadableElement)
                }
                queue += (try? element.attribute(.children)) ?? []
            }
            throw NotFound()
        }

        private struct NotFound: Error {}

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
            throw NotFound()
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
            #expect(reader.start(reading: .element(try axWindow())))
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
            let target = (text as NSString).range(of: "Page 1 opens here.")
            try await go(toPage: 25)
            readable.selection = Selection(target)
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

        /// Superscript footnote marks stay in the text (selection) but aren't read.
        @Test func skipsFootnoteMarks() async throws {
            try await go(toPage: 5)
            let readable = try readable()
            let text = try #require(readable.fullText)
            let range = (text as NSString).range(of: "A second paragraph has a marked")
            #expect(range.location != NSNotFound)
            readable.selection = Selection(range.location..<range.location + range.length + 7)
            let spoken = try #require(readable.selectedText)
            #expect(!spoken.contains("z"), "\(spoken.debugDescription)")
            #expect(spoken.utf16.count == range.length + 7)
            #expect(selected?.contains("z") == true)
            #expect(!readable.isHighlighting)
        }

        /// PDFKit selects within one leaf: a unit spanning two is selected piece by piece as speech reaches each.
        @Test func selectsPiecesOfUnitAcrossPages() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            let text = try #require(readable.fullText)
            let unit = Selection((text as NSString).range(of: "It runs on to the next page, where it ends."))
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

        /// While reading, the selection follows speech from piece to piece.
        @Test func readingMovesSelectionToNextPiece() async throws {
            try await go(toPage: 2)
            let readable = try readable()
            let text = try #require(readable.fullText)
            readable.selection = Selection((text as NSString).range(of: "It runs on to the next page, where it ends."))
            let reader = makeReader()
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate  // slow enough to see the pieces
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            var waited = 0
            while waited < 100, selected != "next page, where it ends." {
                await settle(0.05)
                waited += 1
            }
            #expect(selected == "next page, where it ends.")
        }

        /// A word hyphenated at a line break is read whole; a hyphen that's part of the word stays.
        @Test func joinsHyphenatedWords() async throws {
            try await go(toPage: 4)
            let readable = try readable()
            let text = try #require(readable.fullText)
            #expect(text.contains("Words like hyph\u{2060}\u{2060}enated and self-\u{2060}aware are split."))
            readable.selection = Selection((text as NSString).range(of: "Words like hyph\u{2060}\u{2060}enated and self-\u{2060}aware are split."))
            #expect(selected?.replacingOccurrences(of: "\n", with: "") == "Words like hyph-enated and self-aware are split.")
            #expect(!readable.isHighlighting)
        }

        @Test func readsAndAdvances() async throws {
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: try readable()))
            try await reading.wait(timeout: 10)
            // Maximum rate: the first units go by fast, so only check that the selection moved on.
            var waited = 0
            while waited < 50, [nil, "Page 0 opens here."].contains(selected) {
                await settle()
                waited += 1
            }
            let unit = try #require(selected)
            #expect(unit != "Page 0 opens here.")
            #expect(try #require(reader.readable?.fullText).contains(PDFReadableElement.flattened(unit).0))
        }
    }
}
