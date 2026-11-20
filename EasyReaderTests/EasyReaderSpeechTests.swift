import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct EasyReaderSpeechTests {
        private let recorder = StateRecorder()
        private let reader: EasyReader

        init() {
            reader = makeSilentReader(recorder: recorder)
        }

        private func pauseAndResume() async throws {
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)
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

        @Test func progressAtEachUtteranceStart() async throws {
            let readable = MockReadable("One. Two. Three.")
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            let starts = recorder.progressAtStarts.compactMap { $0 }
            #expect(starts.map(\.position) == [0, 5, 10])
            #expect(starts.allSatisfy { $0.length == 16 })
        }

        /// A selection made while a unit is read isn't read itself: reading goes on after it.
        @Test func continuesAfterSelectionMadeWhileReading() async throws {
            let text = "One sentence that takes a while to read out loud. Two. Three. Four."
            let readable = MockReadable(text)
            let reading = recorder.expect(.reading)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 15)
            readable.selection = try Selection(of: "Three.", in: text)
            let readsBefore = readable.selectedTexts.count
            try await stopped.wait(timeout: 15)
            let read = readable.history.compactMap(readable.text(of:)).filter { !$0.isEmpty }
            #expect(read == ["One sentence that takes a while to read out loud.", "Three.", "Four."])
            #expect(!readable.selectedTexts[readsBefore...].contains("Three."), "the user's selection isn't spoken")
        }

        @Test func pauseResumeStop() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)

            try await pauseAndResume()

            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        /// Selection changes synchronously, so assert right away (before speech advances on its own).
        @Test func skipForwardAndBackward() {
            let readable = MockReadable("First one here. Second one here. Third one here. Fourth one here.")
            #expect(reader.start(reading: readable))
            #expect(readable.selectedUnit == "First one here.")
            #expect(reader.skip(.forward))
            #expect(readable.selectedUnit == "Second one here.")
            #expect(reader.skip(.backward))
            #expect(readable.selectedUnit == "First one here.")
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

        /// Never reads (its late `didStart` is ignored), and ends reading though the state didn't change.
        @Test func stopBeforeSpeechStartsStops() async throws {
            let readable = MockReadable("First one here. Second one here.")
            #expect(reader.start(reading: readable))
            #expect(reader.stop())
            await settle(0.5)
            #expect(reader.state == .stopped)
            #expect(!recorder.events.contains(.reading))
            #expect(readable.endReadings == 1)
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
            #expect(other.selectedUnit == "Other text here.")
        }

        @Test func stopWhenNotReadingFails() {
            #expect(!reader.stop())
            #expect(reader.state == .stopped)
        }

        @Test func skipBackwardAtStartKeepsReading() {
            let readable = MockReadable("First one here. Second one here.")
            #expect(reader.start(reading: readable))
            #expect(reader.skip(.backward))
            #expect(readable.selectedUnit == "First one here.")
        }

        /// A held skip backward restarts the first unit once, not at every repeat.
        @Test func repeatingSkipBackwardStopsAtFirstUnit() async throws {
            let readable = MockReadable(longText)
            #expect(reader.start(reading: readable))
            #expect(reader.beginRepeatingSkip(.backward, firstRepeatAfter: 0.05))
            let reads = readable.selectedTextReads
            await settle(0.5)
            reader.endRepeatingSkip()
            #expect(readable.selectedTextReads == reads)
        }

        /// A speech-setting restart (`play` while reading) doesn't begin reading again: Books would copy the selection.
        @Test func playWhileReadingDoesNotBeginAgain() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            #expect(reader.play(from: .word))
            #expect(readable.beginReadings == 1)
        }

        @Test func endsReadingOnceWhenStartingOtherTextWhilePaused() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            #expect(reader.start(reading: MockReadable(longText)))
            #expect(readable.endReadings == 1)
        }

        @Test func finishingSetsHasFinishedUntilStopped() async throws {
            let readable = MockReadable("One. Two.")
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            #expect(reader.hasFinished)
            #expect(reader.stop())
            #expect(!reader.hasFinished)
        }

        @Test func stoppingByUserIsNotFinishing() async throws {
            let readable = MockReadable("One sentence that takes a while to read out loud. Two.")
            let reading = recorder.expect(.reading)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 15)
            #expect(reader.stop())
            try await stopped.wait(timeout: 15)
            #expect(!reader.hasFinished)
        }

        @Test func rereadFinishedIgnoresNewSelection() async throws {
            let text = "One. Two."
            let readable = MockReadable(text)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            readable.selection = try Selection(of: "Two.", in: text)
            let reading = recorder.expect(.reading)
            #expect(reader.rereadFinished())
            try await reading.wait(timeout: 15)
            #expect(readable.selectedUnit == "One.")
        }

        /// Reading the text again starts at its main content (past a web page's navigation).
        @Test func rereadFinishedStartsAtContentStart() async throws {
            let text = "Home. About. Main one. Main two."
            let readable = MockReadable(text)
            readable.contentStart = try Selection(of: "Main one.", in: text).lowerBound
            readable.selection = Selection(readable.contentStart..<readable.contentStart)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            let reading = recorder.expect(.reading)
            #expect(reader.rereadFinished())
            try await reading.wait(timeout: 15)
            #expect(readable.selectedUnit == "Main one.")
        }

        /// Reading the main content stops at its end, before a web page's footer.
        @Test func finishesAtContentEnd() async throws {
            let text = "Home. Main one. Main two. Footer one."
            let readable = MockReadable(text)
            readable.contentStart = try Selection(of: "Main one.", in: text).lowerBound
            readable.contentEnd = try Selection(of: "Footer one.", in: text).lowerBound
            readable.selection = Selection(readable.contentStart..<readable.contentStart)
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            #expect(reader.hasFinished)
            #expect(readable.selectedTexts.map { $0.trimmingCharacters(in: .whitespaces) } == ["Main one.", "Main two."])
        }

        /// Like the last unit of the text: reading on by itself still finishes there.
        @Test func skipForwardIgnoredAtContentEnd() async throws {
            let text = "Home. Main one. Main two. Footer one."
            let readable = MockReadable(text, selection: try Selection(of: "Main two.", in: text))
            readable.contentStart = try Selection(of: "Main one.", in: text).lowerBound
            readable.contentEnd = try Selection(of: "Footer one.", in: text).lowerBound
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            #expect(!reader.canSkipForward)
            #expect(!reader.skip(.forward))
            #expect(reader.state == .reading)
        }

        /// A selection past the main content reads on to the text's end.
        @Test func readsOnFromSelectionPastContentEnd() async throws {
            let text = "Main one. Footer one. Footer two."
            let readable = MockReadable(text, selection: try Selection(of: "Footer one.", in: text))
            readable.contentEnd = try Selection(of: "Footer one.", in: text).lowerBound
            let stopped = recorder.expect(.stopped)
            #expect(reader.start(reading: readable))
            try await stopped.wait(timeout: 15)
            #expect(readable.selectedTexts.map { $0.trimmingCharacters(in: .whitespaces) } == ["Footer one.", "Footer two."])
        }

        @Test func startingOnSelectionScrollsToIt() throws {
            let text = "First one here. Second one here."
            let second = try Selection(of: "Second one here.", in: text)
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
            let mine = Pronunciation(search: "c", replace: "d", appDomain: "com.example.mine", ignoreCase: true, enabled: true)
            let other = Pronunciation(search: "e", replace: "f", appDomain: "com.example.other", ignoreCase: true, enabled: true)
            Defaults[.pronunciations] = [any, mine, other]
            #expect(reader.pronunciations(with: "com.example.mine") == [any, mine])
            #expect(reader.pronunciations(with: nil) == [any])
        }

        @Test func changedPronunciationsApplyAtOnce() {
            let first = Pronunciation(search: "a", replace: "b")
            Defaults[.pronunciations] = [first]
            #expect(reader.pronunciations(with: nil) == [first])
            let second = Pronunciation(search: "c", replace: "d")
            Defaults[.pronunciations] = [second]
            #expect(reader.pronunciations(with: nil) == [second])
            Defaults.reset(.pronunciations)
            #expect(reader.pronunciations(with: nil) == [])
        }

        @Test func speaksSelectionWithPronunciations() throws {
            Defaults[.pronunciations] = [
                Pronunciation(search: "GUI", replace: "gooey", ignoreCase: false),
                Pronunciation(search: "tomato", replace: "təˈmɑːtəʊ", isPhonetic: true),
            ]
            let readable = MockReadable("A GUI GUIDE with a tomato. Next.")
            #expect(reader.start(reading: readable))
            let spoken = try #require(reader.spokenText)
            #expect(spoken.original == "A GUI GUIDE with a tomato. ")
            #expect(spoken.text == "A gooey GUIDE with a tomato. ")
            #expect(spoken.hasPhonetics)
        }

        /// Resuming maps the synthesizer's offset in the replaced text back to the original, then re-applies the pronunciations.
        @Test func resumeFromWordWithLongerReplacement() async throws {
            Defaults[.pronunciations] = [Pronunciation(search: "GUI", replace: "graphical user interface")]
            let long = Array(repeating: "GUI", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            await settle(2)  // a long utterance's first `willSpeakRange` lags ~0.5–1.2 s
            try await pauseAndResume()
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

        /// With the word boundary macOS reports the word it stops *before* as spoken, then `didFinish`: must not skip ahead.
        @Test func pauseInLastWordResumesSameSentence() async throws {
            Defaults[.speechStopBoundary] = .word
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate
            let readable = MockReadable("Alpha. Bravo.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let first = readable.selection
            try await pauseAndResume()
            #expect(readable.selection == first)
        }

        /// Pausing mid-utterance then resuming keeps reading the same sentence (any stop boundary).
        @Test(arguments: [EasyReader.StopBoundary.immediate, .word])
        func pauseMidSentenceResumesSameSentence(boundary: EasyReader.StopBoundary) async throws {
            Defaults[.speechStopBoundary] = boundary
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            await settle(0.3)
            let first = readable.selection
            try await pauseAndResume()
            #expect(readable.selection == first)
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            try await stopped.wait(timeout: 10)
        }

        @Test func pauseWithSelectionBoundaryFinishesUnit() async throws {
            Defaults[.speechStopBoundary] = .selection
            let words = Array(repeating: "word", count: 40).joined(separator: " ")
            let readable = MockReadable("\(words). Second sentence. Third.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            #expect(reader.state == .reading)
            try await paused.wait(timeout: 15)
            #expect(readable.selectedText?.hasPrefix("Second sentence.") == true)
            let resumed = recorder.expect(.reading)
            #expect(reader.togglePlayPause())
            try await resumed.wait(timeout: 10)
            #expect(reader.spokenText?.text.hasPrefix("Second sentence.") == true)
        }

        @Test func secondPauseWithSelectionBoundaryPausesInUnit() async throws {
            Defaults[.speechStopBoundary] = .selection
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let first = readable.selection
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            #expect(readable.selection == first)
        }

        @Test func stopWithSelectionBoundaryOnLastUnitFinishes() async throws {
            Defaults[.speechStopBoundary] = .selection
            let words = Array(repeating: "word", count: 40).joined(separator: " ")
            let readable = MockReadable("\(words).")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            #expect(reader.state == .reading)
            try await stopped.wait(timeout: 15)
            #expect(reader.hasFinished)
        }

        /// With the selection boundary, stopping in a unit that isn't the last reads it to its end, then stops on the next one.
        @Test func stopWithSelectionBoundaryStopsOnNextUnit() async throws {
            Defaults[.speechStopBoundary] = .selection
            let words = Array(repeating: "word", count: 40).joined(separator: " ")
            let readable = MockReadable("\(words). Second sentence. Third.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            #expect(reader.stop())
            #expect(reader.state == .reading)
            try await stopped.wait(timeout: 15)
            #expect(readable.selectedUnit == "Second sentence.")
            #expect(!reader.hasFinished)
        }

        /// `resumeUnit = .selection` resumes from the unit's start, not from the word where it paused.
        @Test func resumeFromSelectionRereadsWholeUnit() async throws {
            Defaults[.resumeUnit] = .selection
            let long = Array(repeating: "word", count: 200).joined(separator: " ")
            let readable = MockReadable("\(long). Second sentence.")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            await settle(2)  // a long utterance's first `willSpeakRange` lags ~0.5–1.2 s
            try await pauseAndResume()
            #expect(reader.spokenText?.original == "\(long). ")
        }

        /// The pause goes before units reading moves on to by itself, not before starting or skipping.
        @Test func pausesBetweenUnitsOnlyWhenAdvancing() async throws {
            Defaults[.pauseBetweenUnits] = 0.5
            let readable = MockReadable("One. Two. Three. Four. Five.")
            let started = recorder.expectUtteranceStart()
            #expect(reader.start(reading: readable))
            #expect(reader.currentUtterance?.preUtteranceDelay == 0)
            try await started.wait(timeout: 10)
            let advanced = recorder.expectUtteranceStart()
            try await advanced.wait(timeout: 10)
            #expect(readable.selectedUnit != "One.")
            #expect(reader.currentUtterance?.preUtteranceDelay == 0.5)
            #expect(reader.skip(.forward))
            #expect(reader.currentUtterance?.preUtteranceDelay == 0)
        }

        /// Pausing ends a held skip.
        @Test func pauseEndsRepeatingSkip() async throws {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            Defaults[.repeatingSkipInterval] = 0.05
            #expect(reader.beginRepeatingSkip(.forward, firstRepeatAfter: 0.05))
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let selections = readable.history.count
            await settle(0.3)
            #expect(readable.history.count == selections)
        }

        /// A held skip ends at the last unit: it doesn't skip on from a selection made there afterwards.
        @Test func failedSkipEndsRepeatingSkip() async throws {
            Defaults[.speechRate] = AVSpeechUtteranceMinimumSpeechRate  // the last unit lasts while the test waits
            Defaults[.repeatingSkipInterval] = 0.05
            let text = "One. Two. The last sentence takes a while to read."
            let readable = MockReadable(text)
            #expect(reader.start(reading: readable))
            #expect(reader.beginRepeatingSkip(.forward, firstRepeatAfter: 0.05))
            try await waitUntil(timeout: 5, "the last unit") { !reader.canSkipForward }
            await settle(0.2)  // the next repeat fails
            let first = try Selection(of: "One.", in: text)
            readable.selection = first
            await settle(0.3)
            #expect(readable.selection == first)
        }

        /// Whatever the stop boundary: the rest of a long unit isn't read, and it doesn't count as finished.
        @Test(arguments: [EasyReader.StopBoundary.immediate, .word, .selection])
        func stopsAndDropsReadableWhenInvalidated(boundary: EasyReader.StopBoundary) async throws {
            Defaults[.speechStopBoundary] = boundary
            let readable = MockReadable(Array(repeating: "word", count: 300).joined(separator: " ") + ".")
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            readable.onInvalidate?()
            try await stopped.wait(timeout: 5)
            #expect(reader.readable == nil)
            #expect(readable.onInvalidate == nil)
            #expect(!reader.hasFinished)
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

        /// A skipped utterance's late callback must not count as the next one finishing and advance again.
        @Test func quickSkipsAdvanceOncePerSkip() async throws {
            let sentences = (1...4).map { "Sentence \($0) is long enough to keep the voice busy well past the time this test waits." }
            let readable = MockReadable(sentences.joined(separator: " "))
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            #expect(reader.skip(.forward))
            #expect(reader.skip(.forward))
            await settle(0.5)
            #expect(readable.selectedUnit == sentences[2])
            #expect(reader.state == .reading)
        }
    }
}
