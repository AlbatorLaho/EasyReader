import AppKit
import PDFKit
import Testing

@testable import EasyReader

struct ReaderWindowParsingTests {
    @Test(
        arguments: [
            ("example.com", "https://example.com"),
            ("  https://example.com/a?b=c \n", "https://example.com/a?b=c"),
            ("http://example.com", "http://example.com"),
            ("HTTPS://example.com", "HTTPS://example.com"),
            ("localhost:8080/page", "https://localhost:8080/page"),
        ] as [(String, String)])
    func webURL(input: String, expected: String) {
        #expect(ReaderWindow.webURL(input)?.absoluteString == expected)
    }

    @Test(
        arguments: [
            ("<html><head><TITLE lang=\"en\">\n  Fish &amp; Chips\n</TITLE></head></html>", "Fish & Chips"),
            ("<title></title>", nil),
            ("<p>No title</p>", nil),
        ] as [(String, String?)])
    func pageTitle(html: String, expected: String?) {
        #expect(ReaderWindow.pageTitle(in: Data(html.utf8), encoding: nil) == expected)
    }

    @Test func withoutMediaDropsImagesAndEmbeds() {
        let html = "<p>Text <IMG src=\"a.png\" alt=\"x\"> more</p><iframe src=\"x\"></iframe><video src=\"v\">"
        let stripped = String(decoding: ReaderWindow.withoutMedia(Data(html.utf8), encoding: nil), as: UTF8.self)
        #expect(stripped == "<p>Text  more</p></iframe>")
    }

    @Test(arguments: ["", "file:///etc/hosts", "ftp://example.com", "https://"])
    func webURLRejects(input: String) {
        #expect(ReaderWindow.webURL(input) == nil)
    }

    @Test func preferredWidthIsTheWidestFixedWidth() {
        let viewSize: [NSAttributedString.DocumentAttributeKey: Any] = [.viewSize: NSValue(size: NSSize(width: 700, height: 100))]
        #expect(ReaderWindow.preferredWidth(of: NSAttributedString(string: "x"), documentAttributes: viewSize) == 700)
        #expect(ReaderWindow.preferredWidth(of: NSAttributedString(string: "x"), documentAttributes: [:]) == 0)

        let table = NSTextTable()
        table.numberOfColumns = 1
        table.setValue(900, type: .absoluteValueType, for: .width)
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        let block = NSTextBlock()
        block.setValue(800, type: .absoluteValueType, for: .width)
        let relative = NSTextBlock()
        relative.setValue(2000, type: .percentageValueType, for: .width)
        func paragraph(_ blocks: [NSTextBlock]) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.textBlocks = blocks
            return NSAttributedString(string: "cell\n", attributes: [.paragraphStyle: style])
        }
        let text = NSMutableAttributedString(attributedString: paragraph([relative]))
        #expect(ReaderWindow.preferredWidth(of: text, documentAttributes: viewSize) == 700)
        text.append(paragraph([block]))
        #expect(ReaderWindow.preferredWidth(of: text, documentAttributes: viewSize) == 800)
        text.append(paragraph([cell]))
        #expect(ReaderWindow.preferredWidth(of: text, documentAttributes: viewSize) == 900)
    }

    @Test(arguments: [("  A Title \n", "A Title"), ("   ", nil), (nil, nil)] as [(String?, String?)])
    func pdfTitle(title: String?, expected: String?) {
        let document = PDFDocument()
        document.documentAttributes = title.map { [PDFDocumentAttribute.titleAttribute: $0] } ?? [:]
        #expect(ReaderWindow.pdfTitle(of: document) == expected)
    }

    // MARK: Page background

    private func paragraph(_ string: String, background: NSColor?) -> NSAttributedString {
        NSAttributedString(string: string, attributes: background.map { [.backgroundColor: $0] } ?? [:])
    }

    @Test func majorityBecomesThePageBackground() {
        let text = NSMutableAttributedString()
        text.append(paragraph("A long paragraph on the page color.\n", background: .yellow))
        text.append(paragraph("Highlighted.\n", background: .red))
        text.append(paragraph("Another long paragraph on the page color.\n", background: .yellow))
        let (separated, background) = ReaderWindow.separatingPageBackground(text, documentAttributes: [:])
        #expect(background == .yellow)
        var kept: [NSColor] = []
        separated.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: separated.length)) { value, _, _ in
            if let color = value as? NSColor { kept.append(color) }
        }
        #expect(kept == [.red])
        #expect(separated.string == text.string)
    }

    @Test func minorityIsLeftAlone() {
        let text = NSMutableAttributedString()
        text.append(paragraph("Short.\n", background: .yellow))
        text.append(paragraph("A much longer paragraph without any background.\n", background: nil))
        let (separated, background) = ReaderWindow.separatingPageBackground(text, documentAttributes: [:])
        #expect(background == nil)
        #expect(separated == text)
    }

    @Test func documentBackgroundWins() {
        let text = paragraph("Plain text.", background: nil)
        let (_, background) = ReaderWindow.separatingPageBackground(text, documentAttributes: [.backgroundColor: NSColor.blue])
        #expect(background == .blue)
    }
}
