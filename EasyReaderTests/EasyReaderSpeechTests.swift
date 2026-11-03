import AVFoundation
import AppKit
import Defaults
import XCTest

@testable import EasyReader

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
        Defaults[.pronunciations] = []
        Defaults[.scrollSelectionIntoView] = true
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
        for entry in pending where entry.state == state { entry.expectation.fulfill() }
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

    /// Skipping backward from the first sentence re-reads it.
    func testSkipBackwardAtStartKeepsReading() {
        let readable = MockReadable("First one here. Second one here.")
        XCTAssertTrue(reader.start(reading: readable))
        XCTAssertTrue(reader.skip(.backward))
        XCTAssertEqual(readable.selection.flatMap(readable.text(of:)), "First one here.")
    }

    func testAutoScrollingOffDoesNotScroll() {
        Defaults[.scrollSelectionIntoView] = false
        let readable = MockReadable("First one here. Second one here.")
        XCTAssertTrue(reader.start(reading: readable))
        XCTAssertTrue(reader.skip(.forward))
        XCTAssertEqual(readable.scrolls, [])
    }

    func testDisabledPronunciationIsNotApplied() {
        Defaults[.pronunciations] = [Pronunciation(search: "GUI", replace: "gooey", ignoreCase: true, enabled: false)]
        XCTAssertEqual(reader.pronunciations(with: nil), [])
    }

    func testPronunciationsFilteredByAppDomain() {
        let any = Pronunciation(search: "a", replace: "b", ignoreCase: true, enabled: true)
        let mine = Pronunciation(search: "c", replace: "d", domain: "com.example.mine", ignoreCase: true, enabled: true)
        let other = Pronunciation(search: "e", replace: "f", domain: "com.example.other", ignoreCase: true, enabled: true)
        Defaults[.pronunciations] = [any, mine, other]
        XCTAssertEqual(reader.pronunciations(with: "com.example.mine"), [any, mine])
        XCTAssertEqual(reader.pronunciations(with: nil), [any])
    }

    /// The text got shorter while reading (selection now past the end): advancing finds nothing instead of trapping.
    func testSkipAfterTextShrinks() {
        let readable = MockReadable("Short.", selection: Selection(40..<50))
        reader.readable = readable
        XCTAssertFalse(reader.skip(.forward))
    }

    /// Pausing on the last word lets the utterance finish (`didFinish` with stopType `.pause`);
    /// resuming must move on (here: stop at the end) instead of re-reading the finished sentence.
    func testPauseAtEndOfTextStopsOnResume() {
        Defaults[.speechStopBoundary] = .word
        let readable = MockReadable("Hi.")
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        let paused = expect(.paused)
        XCTAssertTrue(reader.pause())
        wait(for: [paused], timeout: 10)
        let reads = readable.selectedTextReads
        let stopped = expect(.stopped)
        XCTAssertTrue(reader.togglePlayPause())
        wait(for: [stopped], timeout: 10)
        XCTAssertEqual(readable.selectedTextReads, reads)
    }

    func testStopsAndDropsReadableWhenInvalidated() {
        let readable = MockReadable(Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " "))
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        let stopped = expect(.stopped)
        readable.onInvalidate?()
        wait(for: [stopped], timeout: 5)
        XCTAssertNil(reader.readable)
        XCTAssertNil(readable.onInvalidate)
    }

    /// Guards the shared `stopType`: a stop's late `didCancel` must not stop the reading that replaced it.
    func testStopThenImmediateRestartKeepsReading() {
        let readable = MockReadable(Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " "))
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        XCTAssertTrue(reader.stop())
        XCTAssertTrue(reader.start(reading: readable))
        spinRunLoop(1)
        XCTAssertEqual(reader.state, .reading)
    }
}
