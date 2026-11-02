import AVFoundation
import AppKit
import Defaults
import XCTest

@testable import EasyReader

/// In-memory readable that records every selection EasyReader makes.
private final class MockReadable: Readable {
    let title: String? = "Mock"
    let groupTitle: String? = nil
    let appDomain: String? = nil
    let icon: NSImage? = nil
    let fullText: String?
    var selection: Selection? {
        didSet { if let selection { history.append(selection) } }
    }
    private(set) var history: [Selection] = []
    var selectedText: String? {
        guard let fullText, let selection, let range = Range(selection, in: fullText) else { return nil }
        return String(fullText[range])
    }

    init(_ text: String) {
        fullText = text
        selection = Selection()
    }

    func text(of selection: Selection) -> String? {
        guard let fullText, let range = Range(selection, in: fullText) else { return nil }
        return String(fullText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scroll(to selection: Selection, options: ScrollOptions) {}
}

/// Runs the real speech state machine silently (volume 0, max rate).
/// Debug builds and tests use their own bundle ID, so these settings never touch a release install.
final class EasyReaderSpeechTests: XCTestCase, EasyReaderDelegate {
    private var reader: EasyReader!
    private var pending: [(state: EasyReader.State, expectation: XCTestExpectation)] = []

    override func setUp() {
        super.setUp()
        Defaults[.speechVolume] = 0
        Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
        Defaults[.speechDelayBefore] = 0
        Defaults[.speechDelayAfter] = 0
        Defaults[.speechStopBoundary] = .immediate
        Defaults[.resumeUnit] = .word
        reader = EasyReader()
        reader.delegate = self
        reader.textSelector = NLTextSelector(unit: .sentence)
    }

    override func tearDown() {
        if reader.state != .stopped {
            let stopped = expect(.stopped)
            reader.stop()
            wait(for: [stopped], timeout: 5)
        }
        reader = nil
        pending = []
        super.tearDown()
    }

    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        pending.filter { $0.state == state }.forEach { $0.expectation.fulfill() }
        pending.removeAll { $0.state == state }
    }

    /// Create before triggering the action, so fast transitions aren't missed.
    private func expect(_ state: EasyReader.State) -> XCTestExpectation {
        let expectation = expectation(description: "state \(state)")
        pending.append((state, expectation))
        return expectation
    }

    func testReadsEverySentenceThenStops() {
        let readable = MockReadable("One. Two. Three.")
        let reading = expect(.reading)
        let stopped = expect(.stopped)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading, stopped], timeout: 15, enforceOrder: true)
        let read = readable.history.compactMap(readable.text(of:)).filter { !$0.isEmpty }
        XCTAssertEqual(read, ["One.", "Two.", "Three."])
    }

    func testPauseResumeStop() {
        let readable = MockReadable(Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " "))
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)

        let paused = expect(.paused)
        XCTAssertTrue(reader.pause())
        wait(for: [paused], timeout: 10)

        let resumed = expect(.reading)
        XCTAssertTrue(reader.togglePlayPause())
        wait(for: [resumed], timeout: 10)

        let stopped = expect(.stopped)
        XCTAssertTrue(reader.stop())
        wait(for: [stopped], timeout: 10)
    }

    /// Selection changes synchronously, so assert right away (before speech advances on its own).
    func testSkipForwardAndBackward() {
        let readable = MockReadable("First one here. Second one here. Third one here. Fourth one here.")
        XCTAssertTrue(reader.start(reading: readable))
        XCTAssertEqual(readable.selection.flatMap(readable.text(of:)), "First one here.")
        XCTAssertTrue(reader.skip(.forward))
        XCTAssertEqual(readable.selection.flatMap(readable.text(of:)), "Second one here.")
        XCTAssertTrue(reader.skip(.backward))
        XCTAssertEqual(readable.selection.flatMap(readable.text(of:)), "First one here.")
    }

    func testStopWhenNotReadingFails() {
        XCTAssertFalse(reader.stop())
        XCTAssertEqual(reader.state, .stopped)
    }

    /// Known issue: skipping backward from the first sentence stops reading.
    func testSkipBackwardAtStartKeepsReading() {
        let readable = MockReadable("First one here. Second one here.")
        XCTAssertTrue(reader.start(reading: readable))
        XCTExpectFailure("skip(.backward) at start stops instead of re-reading") {
            XCTAssertTrue(reader.skip(.backward))
            XCTAssertEqual(readable.selection.flatMap(readable.text(of:)), "First one here.")
        }
    }
}
