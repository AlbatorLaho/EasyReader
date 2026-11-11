import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// Runs the real speech state machine silently (volume 0, max rate).
    /// Settings writes go to an in-memory store under tests (`UserDefaults.app`), so they never touch a real install.
    @MainActor
    struct EasyReaderSpeechTests {
        private let reader = EasyReader()
        private let recorder = StateRecorder()

        init() {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.speechDelayBefore] = 0
            Defaults[.speechDelayAfter] = 0
            Defaults[.speechStopBoundary] = .immediate
            Defaults[.resumeUnit] = .word
            Defaults[.pronunciations] = []
            Defaults[.scrollSelectionIntoView] = true
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            let reader = reader
            let recorder = recorder
            Teardown.add {
                guard reader.state != .stopped else { return }
                let stopped = recorder.expect(.stopped)
                reader.stop()
                do { try await stopped.wait(timeout: 5) } catch { Issue.record(error) }
            }
        }

        @Test func readsEverySentenceThenStops() async throws {
            let readable = MockReadable("One. Two. Three.")
            let reading = recorder.expect(.reading)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 15)
            try await stopped.wait(timeout: 15)
            let readingOrder = try #require(reading.order)
            let stoppedOrder = try #require(stopped.order)
            #expect(readingOrder < stoppedOrder)
            let read = readable.history.compactMap(readable.text(of:)).filter { !$0.isEmpty }
            #expect(read == ["One.", "Two.", "Three."])
        }

        @Test func pauseResumeStop() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)

            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)

            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)

            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        /// Selection changes synchronously, so assert right away (before speech advances on its own).
        @Test func skipForwardAndBackward() {
            let readable = MockReadable("First one here. Second one here. Third one here. Fourth one here.")
            #expect(reader.start(reading: readable))
            #expect(readable.selection.flatMap(readable.text(of:)) == "First one here.")
            #expect(reader.skip(.forward))
            #expect(readable.selection.flatMap(readable.text(of:)) == "Second one here.")
            #expect(reader.skip(.backward))
            #expect(readable.selection.flatMap(readable.text(of:)) == "First one here.")
        }

        /// Skipping forward on the last unit is ignored: reading continues on the same unit.
        @Test func skipForwardOnLastUnitKeepsReading() async throws {
            let long = Array(repeating: "word", count: 2000).joined(separator: " ")
            let readable = MockReadable("First one here. Then \(long).")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            #expect(reader.canSkipForward)
            #expect(reader.skip(.forward))
            let last = readable.selection
            #expect(!reader.canSkipForward)
            #expect(!reader.skip(.forward))
            #expect(readable.selection == last)
            try await reading.wait(timeout: 10)
            await settle(0.5)  // a stray stop (e.g. from a queued first utterance finishing) would land here
            #expect(reader.state == .reading)
        }

        /// Stopping on a unit's last word (word boundary lets it finish) then starting again re-reads that unit.
        @Test func stopOnLastWordThenStartRereadsSameUnit() async throws {
            Defaults[.speechStopBoundary] = .word
            let readable = MockReadable("Alpha. Bravo. Charlie. Delta.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let first = readable.selection
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
            await settle(0.5)
            #expect(readable.selection == first, "selection moved after stop")
            let restarted = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await restarted.wait(timeout: 10)
            #expect(readable.selection == first, "restart didn't re-read the stopped unit")
        }

        /// Between `speak` and `didStart` the synthesizer reports not speaking; pause must still work there.
        @Test func pauseBeforeSpeechStartsPausesSameUnit() async throws {
            let readable = MockReadable("First one here. Second one here.")
            let paused = recorder.expect(.paused)
            #expect(reader.start(reading: readable))
            let first = readable.selection
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            #expect(readable.selection == first)
            let reading = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await reading.wait(timeout: 10)
            #expect(readable.selection == first)
        }

        @Test func stopBeforeSpeechStartsStops() async throws {
            let readable = MockReadable("First one here. Second one here.")
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        /// Start while paused on the same readable resumes; on another readable it reads that one instead.
        @Test func startWhilePausedResumesSameReadableOnly() async throws {
            let first = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: first))
            try await reading.wait(timeout: 10)
            let firstSelection = first.selection
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)

            let resumed = recorder.expect(.reading)
            #expect(reader.start(reading: first))
            try await resumed.wait(timeout: 10)
            #expect(first.selection == firstSelection)
            let pausedAgain = recorder.expect(.paused)
            #expect(reader.pause())
            try await pausedAgain.wait(timeout: 10)

            let other = MockReadable("Other text here. More.")
            let readingOther = recorder.expect(.reading)
            #expect(reader.start(reading: other))
            try await readingOther.wait(timeout: 10)
            #expect(reader.readable === other)
            #expect(other.selection.flatMap(other.text(of:)) == "Other text here.")
        }

        @Test func stopWhenNotReadingFails() {
            #expect(!reader.stop())
            #expect(reader.state == .stopped)
        }

        /// Skipping backward from the first sentence re-reads it.
        @Test func skipBackwardAtStartKeepsReading() {
            let readable = MockReadable("First one here. Second one here.")
            #expect(reader.start(reading: readable))
            #expect(reader.skip(.backward))
            #expect(readable.selection.flatMap(readable.text(of:)) == "First one here.")
        }

        @Test func startingOnSelectionScrollsToIt() {
            let text = "First one here. Second one here."
            let second = Selection((text as NSString).range(of: "Second one here."))
            let readable = MockReadable(text, selection: second)
            #expect(reader.start(reading: readable))
            #expect(readable.scrolls == [second])
        }

        @Test func autoScrollingOffDoesNotScroll() {
            Defaults[.scrollSelectionIntoView] = false
            let readable = MockReadable("First one here. Second one here.")
            #expect(reader.start(reading: readable))
            #expect(reader.skip(.forward))
            #expect(readable.scrolls == [])
        }

        @Test func disabledPronunciationIsNotApplied() {
            Defaults[.pronunciations] = [Pronunciation(search: "GUI", replace: "gooey", ignoreCase: true, enabled: false)]
            #expect(reader.pronunciations(with: nil) == [])
        }

        @Test func pronunciationsFilteredByAppDomain() {
            let any = Pronunciation(search: "a", replace: "b", ignoreCase: true, enabled: true)
            let mine = Pronunciation(search: "c", replace: "d", domain: "com.example.mine", ignoreCase: true, enabled: true)
            let other = Pronunciation(search: "e", replace: "f", domain: "com.example.other", ignoreCase: true, enabled: true)
            Defaults[.pronunciations] = [any, mine, other]
            #expect(reader.pronunciations(with: "com.example.mine") == [any, mine])
            #expect(reader.pronunciations(with: nil) == [any])
        }

        @Test func speaksSelectionWithPronunciations() {
            Defaults[.pronunciations] = [
                Pronunciation(search: "GUI", replace: "gooey", ignoreCase: false),
                Pronunciation(search: "tomato", replace: "təˈmɑːtəʊ", isPhonetic: true),
            ]
            let readable = MockReadable("A GUI GUIDE with a tomato. Next.")
            #expect(reader.start(reading: readable))
            let spoken = try? #require(reader.spokenText)
            #expect(spoken?.original == "A GUI GUIDE with a tomato. ")
            #expect(spoken?.text == "A gooey GUIDE with a tomato. ")
            #expect(spoken?.hasPhonetics == true)
        }

        /// Resuming from a word maps the synthesizer's offset (in the replaced text) back to the original
        /// text, then re-applies the pronunciations from there.
        @Test func resumeFromWordWithLongerReplacement() async throws {
            Defaults[.pronunciations] = [Pronunciation(search: "GUI", replace: "graphical user interface")]
            let long = Array(repeating: "GUI", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            // A long utterance's first `willSpeakRange` comes ~0.5–1.2 s after it starts (synthesis lookahead).
            await settle(2)
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)
            let spoken = try #require(reader.spokenText)
            #expect(spoken.original.count < long.count, "resumed mid-sentence")
            #expect("\(long). ".hasSuffix(spoken.original))
            #expect(spoken.original.hasPrefix("GUI"))
            #expect(spoken.text.hasPrefix("graphical user interface "))
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        /// The text got shorter while reading (selection now past the end): advancing finds nothing instead of trapping.
        @Test func skipAfterTextShrinks() {
            let readable = MockReadable("Short.", selection: Selection(40..<50))
            reader.readable = readable
            #expect(!reader.skip(.forward))
        }

        /// With the word boundary macOS reports the word it stops *before* as spoken and then `didFinish`,
        /// so a pause anywhere in a one-word sentence must resume that sentence, not skip to the next.
        @Test func pauseInLastWordResumesSameSentence() async throws {
            Defaults[.speechStopBoundary] = .word
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate
            let readable = MockReadable("Alpha. Bravo.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let first = readable.selection
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)
            #expect(readable.selection == first)
        }

        /// Pausing mid-utterance then resuming keeps reading the same sentence (any stop boundary).
        @Test(arguments: [AVSpeechBoundary.immediate, .word])
        func pauseMidSentenceResumesSameSentence(boundary: AVSpeechBoundary) async throws {
            Defaults[.speechStopBoundary] = boundary
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            await settle(0.3)
            let first = readable.selection
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)
            #expect(readable.selection == first)
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        @Test func stopsAndDropsReadableWhenInvalidated() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            readable.onInvalidate?()
            try await stopped.wait(timeout: 5)
            #expect(reader.readable == nil)
            #expect(readable.onInvalidate == nil)
        }

        /// Guards the shared `stopType`: a stop's late `didCancel` must not stop the reading that replaced it.
        @Test func stopThenImmediateRestartKeepsReading() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            #expect(reader.stop())
            #expect(reader.start(reading: readable))
            await settle(1)
            #expect(reader.state == .reading)
        }
    }
}
