import AVFoundation
import AppKit
import Defaults
import XCTest

@testable import EasyReader

/// Runs the real speech state machine silently (volume 0, max rate).
/// Settings writes go to an in-memory store under XCTest (`UserDefaults.app`), so they never touch a real install.
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

    /// Skipping forward on the last unit is ignored: reading continues on the same unit.
    func testSkipForwardOnLastUnitKeepsReading() {
        let long = Array(repeating: "word", count: 2000).joined(separator: " ")
        let readable = MockReadable("First one here. Then \(long).")
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        XCTAssertTrue(reader.canSkipForward)
        XCTAssertTrue(reader.skip(.forward))
        let last = readable.selection
        XCTAssertFalse(reader.canSkipForward)
        XCTAssertFalse(reader.skip(.forward))
        XCTAssertEqual(readable.selection, last)
        wait(for: [reading], timeout: 10)
        spinRunLoop(0.5)  // a stray stop (e.g. from a queued first utterance finishing) would land here
        XCTAssertEqual(reader.state, .reading)
    }

    /// Stopping on a unit's last word (word boundary lets it finish) then starting again re-reads that unit.
    func testStopOnLastWordThenStartRereadsSameUnit() {
        Defaults[.speechStopBoundary] = .word
        let readable = MockReadable("Alpha. Bravo. Charlie. Delta.")
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        let first = readable.selection
        let stopped = expect(.stopped)
        XCTAssertTrue(reader.stop())
        wait(for: [stopped], timeout: 10)
        spinRunLoop(0.5)
        XCTAssertEqual(readable.selection, first, "selection moved after stop")
        let restarted = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [restarted], timeout: 10)
        XCTAssertEqual(readable.selection, first, "restart didn't re-read the stopped unit")
    }

    /// Between `speak` and `didStart` the synthesizer reports not speaking; pause must still work there.
    func testPauseBeforeSpeechStartsPausesSameUnit() {
        let readable = MockReadable("First one here. Second one here.")
        let paused = expect(.paused)
        XCTAssertTrue(reader.start(reading: readable))
        let first = readable.selection
        XCTAssertTrue(reader.pause())
        wait(for: [paused], timeout: 10)
        XCTAssertEqual(readable.selection, first)
        let reading = expect(.reading)
        XCTAssertTrue(reader.togglePlayPause())
        wait(for: [reading], timeout: 10)
        XCTAssertEqual(readable.selection, first)
    }

    func testStopBeforeSpeechStartsStops() {
        let readable = MockReadable("First one here. Second one here.")
        let stopped = expect(.stopped)
        XCTAssertTrue(reader.start(reading: readable))
        XCTAssertTrue(reader.stop())
        wait(for: [stopped], timeout: 10)
    }

    /// Start while paused on the same readable resumes; on another readable it reads that one instead.
    func testStartWhilePausedResumesSameReadableOnly() {
        let long = Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " ")
        let first = MockReadable(long)
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: first))
        wait(for: [reading], timeout: 10)
        let firstSelection = first.selection
        let paused = expect(.paused)
        XCTAssertTrue(reader.pause())
        wait(for: [paused], timeout: 10)

        let resumed = expect(.reading)
        XCTAssertTrue(reader.start(reading: first))
        wait(for: [resumed], timeout: 10)
        XCTAssertEqual(first.selection, firstSelection)
        let pausedAgain = expect(.paused)
        XCTAssertTrue(reader.pause())
        wait(for: [pausedAgain], timeout: 10)

        let other = MockReadable("Other text here. More.")
        let readingOther = expect(.reading)
        XCTAssertTrue(reader.start(reading: other))
        wait(for: [readingOther], timeout: 10)
        XCTAssertTrue(reader.readable === other)
        XCTAssertEqual(other.selection.flatMap(other.text(of:)), "Other text here.")
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

    /// With the word boundary macOS reports the word it stops *before* as spoken and then `didFinish`,
    /// so a pause anywhere in a one-word sentence must resume that sentence, not skip to the next.
    func testPauseInLastWordResumesSameSentence() {
        Defaults[.speechStopBoundary] = .word
        Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate
        let readable = MockReadable("Alpha. Bravo.")
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        let first = readable.selection
        let paused = expect(.paused)
        XCTAssertTrue(reader.pause())
        wait(for: [paused], timeout: 10)
        let resumed = expect(.reading)
        XCTAssertTrue(reader.togglePlayPause())
        wait(for: [resumed], timeout: 10)
        XCTAssertEqual(readable.selection, first)
    }

    /// Pausing mid-utterance then resuming keeps reading the same sentence (any stop boundary).
    func testPauseMidSentenceResumesSameSentence() {
        for boundary in [AVSpeechBoundary.immediate, .word] {
            Defaults[.speechStopBoundary] = boundary
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = expect(.reading)
            XCTAssertTrue(reader.start(reading: readable))
            wait(for: [reading], timeout: 10)
            spinRunLoop(0.3)
            let first = readable.selection
            let paused = expect(.paused)
            XCTAssertTrue(reader.pause())
            wait(for: [paused], timeout: 10)
            let resumed = expect(.reading)
            XCTAssertTrue(reader.togglePlayPause())
            wait(for: [resumed], timeout: 10)
            XCTAssertEqual(readable.selection, first, "boundary \(boundary.rawValue)")
            let stopped = expect(.stopped)
            XCTAssertTrue(reader.stop())
            wait(for: [stopped], timeout: 10)
        }
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
