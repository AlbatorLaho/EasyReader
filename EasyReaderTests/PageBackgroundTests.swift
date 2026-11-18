import AppKit
import Testing

@testable import EasyReader

struct PageBackgroundTests {
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
