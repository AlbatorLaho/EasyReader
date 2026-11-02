import AXSwift
import AppKit
import XCTest

@testable import EasyReader

/// Drives the real AX code path against a text view in the test host's own process.
/// Reading your own process's accessibility tree does not require Accessibility permission.
final class TextAreaReadableElementTests: XCTestCase {
    private var window: NSWindow!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private let text = (1...80).map { "Sentence 😀 number \($0)." }.joined(separator: "\n")

    override func setUp() {
        super.setUp()
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as? NSTextView
        textView.string = text
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "AX Test \(UUID().uuidString)"
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        spinRunLoop()
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func spinRunLoop(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func readable() throws -> TextAreaReadableElement {
        let app = try XCTUnwrap(Application(NSRunningApplication.current))
        let windows = try XCTUnwrap(app.windows())
        let axWindow = try XCTUnwrap(
            windows.first { (try? $0.attribute(.title) as String?) == window.title },
            "test window not found in AX tree"
        )
        var queue = [axWindow]
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if let readable = try element.readableElement() {
                return try XCTUnwrap(readable as? TextAreaReadableElement)
            }
            queue += (try? element.arrayAttribute(.children) as [UIElement]?) ?? []
        }
        throw XCTSkip("no AXTextArea found")
    }

    func testFindsTextAreaWithFullText() throws {
        let readable = try readable()
        XCTAssertEqual(readable.fullText, text)
        XCTAssertEqual(readable.appDomain, Bundle.main.bundleIdentifier)
        XCTAssertEqual(readable.title, window.title)
    }

    func testSettingSelectionUpdatesTextView() throws {
        let readable = try readable()
        readable.selection = Selection(3..<9)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 6))
        XCTAssertEqual(readable.selection, Selection(3..<9))
        XCTAssertEqual(readable.selectedText, (text as NSString).substring(with: NSRange(location: 3, length: 6)))
    }

    func testReadsSelectionChangedInTextView() throws {
        let readable = try readable()
        textView.setSelectedRange(NSRange(location: 20, length: 4))
        XCTAssertEqual(readable.selection, Selection(20..<24))
    }

    /// AX ranges are UTF-16; each 😀 is two code units, so offsets drift if treated as Characters.
    func testSelectorStepsThroughNonBMPTextViaAX() throws {
        let readable = try readable()
        let selector = NLTextSelector(unit: .sentence)
        readable.selection = Selection()
        for n in 1...3 {
            let next = selector.select(.forward, from: try XCTUnwrap(readable.selection), in: try XCTUnwrap(readable.fullText))
            readable.selection = next
            XCTAssertEqual(
                readable.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                "Sentence 😀 number \(n)."
            )
        }
    }

    func testScrollBringsSelectionIntoView() throws {
        let readable = try readable()
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
        let last = Selection((text as NSString).range(of: "Sentence 😀 number 80."))
        readable.selection = last
        scrollView.contentView.scroll(to: .zero)  // selecting may auto-scroll; reset to test our scroll code
        spinRunLoop()
        readable.scroll(to: last, options: ScrollOptions(padding: 16, smooth: false, duration: 0, updateRate: 60))
        spinRunLoop()
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0)
    }
}
