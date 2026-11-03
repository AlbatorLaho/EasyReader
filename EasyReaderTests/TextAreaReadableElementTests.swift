import AVFoundation
import AXSwift
import AppKit
import Defaults
import XCTest

@testable import EasyReader

/// Drives the real AX code path against a text view in the test host's own process.
/// Reading your own process's accessibility tree does not require Accessibility permission.
final class TextAreaReadableElementTests: XCTestCase, EasyReaderDelegate {
    private var window: NSWindow!
    private var reader: EasyReader?
    private var pending: [(state: EasyReader.State, expectation: XCTestExpectation)] = []
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
        reader?.stop()
        reader = nil
        pending = []
        window.close()
        window = nil
        super.tearDown()
    }

    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        for entry in pending where entry.state == state { entry.expectation.fulfill() }
        pending.removeAll { $0.state == state }
    }

    private func expect(_ state: EasyReader.State) -> XCTestExpectation {
        let expectation = expectation(description: "state \(state)")
        pending.append((state, expectation))
        return expectation
    }

    /// Silent reader (see EasyReaderSpeechTests).
    private func makeReader() -> EasyReader {
        Defaults[.speechVolume] = 0
        Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
        Defaults[.speechDelayBefore] = 0
        Defaults[.speechDelayAfter] = 0
        Defaults[.speechStopBoundary] = .immediate
        let reader = EasyReader()
        reader.delegate = self
        reader.textSelector = NLTextSelector(unit: .sentence)
        self.reader = reader
        return reader
    }

    private func axWindow(for window: NSWindow) throws -> UIElement {
        let app = try XCTUnwrap(Application(NSRunningApplication.current))
        let windows = try XCTUnwrap(app.windows())
        return try XCTUnwrap(
            windows.first { (try? $0.attribute(.title) as String?) == window.title },
            "test window not found in AX tree"
        )
    }

    private func readable() throws -> TextAreaReadableElement {
        var queue = [try axWindow(for: window)]
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

    func testScrollValueIsClamped() {
        XCTAssertEqual(TextAreaReadableElement.scrollValue(offset: 50, scrollableLength: 100), 0.5)
        XCTAssertEqual(TextAreaReadableElement.scrollValue(offset: -16, scrollableLength: 100), 0)
        XCTAssertEqual(TextAreaReadableElement.scrollValue(offset: 150, scrollableLength: 100), 1)
        XCTAssertEqual(TextAreaReadableElement.scrollValue(offset: 10, scrollableLength: 0), 0)
        XCTAssertEqual(TextAreaReadableElement.scrollValue(offset: 10, scrollableLength: -20), 0)
    }

    /// `findReadableElement` descends via `.childrenInNavigationOrder`; AppKit supports it (other apps may not).
    func testFindsTextAreaStartingFromWindow() throws {
        let reader = makeReader()
        let start = try axWindow(for: window)
        XCTAssertTrue(reader.start(reading: .element(start)))
    }

    /// The search must not climb past the window and find (and focus) a text area in another window.
    func testDoesNotLeaveStartingWindow() throws {
        let other = NSWindow(contentRect: NSRect(x: 650, y: 200, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.title = "AX Other \(UUID().uuidString)"
        other.contentView = NSButton(title: "No text here", target: nil, action: nil)
        other.makeKeyAndOrderFront(nil)
        defer { other.close() }
        spinRunLoop()
        let reader = makeReader()
        let start = try axWindow(for: other)
        XCTAssertFalse(reader.start(reading: .element(start)))
    }

    /// Reading stops once the text view leaves its window.
    func testStopsWhenTextViewIsRemoved() throws {
        textView.string = Array(repeating: "word", count: 400).joined(separator: " ") + "."
        let reader = makeReader()
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: try readable()))
        wait(for: [reading], timeout: 10)
        let stopped = expect(.stopped)
        window.contentView = NSView()
        spinRunLoop()
        wait(for: [stopped], timeout: 3)
    }

    /// Closing the window only destroys the window element; the text area still answers AX.
    func testStopsWhenWindowCloses() throws {
        textView.string = Array(repeating: "word", count: 400).joined(separator: " ") + "."
        let reader = makeReader()
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: try readable()))
        wait(for: [reading], timeout: 10)
        let stopped = expect(.stopped)
        window.close()
        wait(for: [stopped], timeout: 3)
    }
}
