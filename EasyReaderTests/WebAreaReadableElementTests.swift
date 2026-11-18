import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// `WebAreaReadableElement` against `WebTestPage`: the same cross-process AX path as Safari.
    @MainActor
    @Suite(.enabled(if: AXIsProcessTrusted(), "needs Accessibility permission for the test host (Debug EasyReader)"))
    struct WebAreaReadableElementTests {
        private struct Timeout: Error, CustomStringConvertible {
            let what: String
            var description: String { "timed out waiting for \(what)" }
        }

        private let browser: Process
        private let recorder = StateRecorder()

        init() async throws {
            let browser = try WebTestPage.launch()
            self.browser = browser
            Teardown.add {
                browser.terminate()
                for _ in 0..<30 where browser.isRunning { await settle() }
            }
        }

        /// Silent reader, as in EasyReaderSpeechTests.
        private func makeReader() -> EasyReader {
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            let reader = EasyReader()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            Teardown.add { reader.stop() }
            return reader
        }

        private func browserWindow() -> AXElement? {
            (try? AXElement.application(pid: browser.processIdentifier).attribute(.windows))?.first
        }

        private func find(role: String, in root: AXElement, where predicate: (AXElement) -> Bool = { _ in true }) -> AXElement? {
            var queue = [root]
            var visited = 0
            while !queue.isEmpty, visited < 5000 {
                let element = queue.removeFirst()
                visited += 1
                if (try? element.role())?.rawValue == role, predicate(element) { return element }
                queue += (try? element.attribute(.children)) ?? []
            }
            return nil
        }

        private func readable() async throws -> WebAreaReadableElement {
            for _ in 0..<100 {
                if let window = browserWindow(), let element = find(role: "AXWebArea", in: window),
                    let readable = try element.readableElement() as? WebAreaReadableElement,
                    readable.fullText?.contains("The end of the test page.") == true
                {
                    return readable
                }
                await settle()
            }
            throw Timeout(what: "web test page")
        }

        private func selection(of string: String, in text: String) throws -> Selection {
            let range = (text as NSString).range(of: string)
            try #require(range.location != NSNotFound, "\(string) not in page text")
            return Selection(range)
        }

        @Test func readsPageText() async throws {
            let text = try #require(try await readable().fullText)
            #expect(text.contains("EasyReader test page"))
            #expect(text.contains("Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀."))
        }

        /// The marker for an offset maps back to the same offset (the AX index APIs alone drift).
        @Test func markerOffsetsRoundTrip() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let offsets = [
                0, 5, try selection(of: "😀", in: text).lowerBound, try selection(of: "🚀", in: text).upperBound,
                try selection(of: "Paragraph 30 ", in: text).lowerBound, text.utf16.count,
            ]
            for offset in offsets {
                let marker = try #require(readable.marker(at: offset, in: text))
                #expect(readable.offset(of: marker, in: text) == offset, "offset \(offset)")
            }
        }

        @Test func selectionRoundTrips() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let sentence = "Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀."
            let selection = try selection(of: sentence, in: text)
            readable.selection = selection
            #expect(readable.selection == selection)
            #expect(readable.selectedText == sentence)
            // A fresh readable has no tracked selection: this is what the page itself reports.
            let fresh = try #require(try readable.handle.readableElement() as? WebAreaReadableElement)
            #expect(fresh.selection == selection)
        }

        /// A selection made in the page (from raw AX index markers, which don't match text offsets) is read back.
        @Test(arguments: [100, 400, 1000])
        func readsSelectionMadeInPage(index: Int) async throws {
            let readable = try await readable()
            let element = readable.handle
            let start = try #require(try element.attribute(.textMarkerForIndex, for: index))
            let end = try #require(try element.attribute(.textMarkerForIndex, for: index + 30))
            let range = try #require(try element.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [start, end]))
            try element.set(.selectedTextMarkerRange, to: range)
            await settle()
            let reportedRange = try #require(try element.attribute(.selectedTextMarkerRange))
            let expected = try #require(try element.attribute(.stringForTextMarkerRange, for: reportedRange))
            let fresh = try #require(try readable.handle.readableElement() as? WebAreaReadableElement)
            #expect(fresh.selectedText == expected)
            #expect(!expected.isEmpty)
        }

        @Test func selectorStepsThroughSentences() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let selector = NLTextSelector(unit: .sentence)
            let start = try selection(of: "Emoji take", in: text).lowerBound
            readable.selection = Selection(start..<start)
            for expected in ["Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀.", "This sentence comes after them."] {
                readable.selection = selector.select(.forward, from: try #require(readable.selection), in: text)
                #expect(readable.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
            }
        }

        @Test func readerFindsWebAreaFromWindowAndAdvances() async throws {
            let page = try await readable()
            let text = try #require(page.fullText)
            let first = try selection(of: "This page tests reading web content.", in: text)
            page.selection = first
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: .element(try #require(browserWindow()))))
            try await reading.wait(timeout: 10)
            let readable = try #require(reader.readable as? WebAreaReadableElement)
            for _ in 0..<50 where (readable.selection?.lowerBound ?? 0) <= first.lowerBound { await settle() }
            #expect(try #require(readable.selection).lowerBound > first.lowerBound, "reading did not advance")
        }

        /// Starting from text inside the page (like focus on a link) climbs to the web area.
        @Test func findsWebAreaAsAncestor() async throws {
            let page = try await readable()
            let link = try #require(find(role: "AXStaticText", in: page.handle) { (try? $0.attribute(.value) as String?) == "links" })
            let reader = makeReader()
            #expect(reader.start(reading: .element(link)))
            reader.stop()
            #expect((reader.readable as? WebAreaReadableElement)?.handle == page.handle)
        }

        /// A text area inside the page is read itself, not the page around it.
        @Test func textAreaInPageWins() async throws {
            let page = try await readable()
            let textArea = try #require(find(role: "AXTextArea", in: page.handle))
            let reader = makeReader()
            #expect(reader.start(reading: .element(textArea)))
            reader.stop()
            #expect(reader.readable is TextAreaReadableElement)
        }

        @Test func scrollBringsSelectionIntoView() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let last = try selection(of: "The end of the test page.", in: text)
            let marker = try #require(readable.marker(at: last.lowerBound, in: text))
            func top() -> CGFloat? {
                guard let range = try? readable.handle.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [marker, marker]),
                    let bounds = try? readable.handle.attribute(.boundsForTextMarkerRange, for: range)
                else { return nil }
                return bounds.minY
            }
            let before = try #require(top())
            readable.scroll(to: last, options: ScrollOptions(padding: 16, duration: 0))
            await settle(0.5)
            let after = try #require(top())
            #expect(after < before, "selection did not move up into view (\(before) → \(after))")
        }

        /// Smooth scrolling animates WebKit's scroll bar and ends with the selection at the scroll area's top + padding.
        @Test func smoothScrollAnimatesScrollBar() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let target = try selection(of: "Paragraph 30 ", in: text)
            let scrollArea = try #require(try readable.handle.parent(with: .scrollArea))
            let scrollBar = try #require(try scrollArea.attribute(.verticalScrollBar))
            func value() throws -> CGFloat { try #require(try scrollBar.attribute(.value)) }
            #expect(try value() == 0)

            readable.scroll(to: target, options: ScrollOptions(padding: 16, duration: 0.6))
            await settle(0.3)
            let midway = try value()
            await settle(0.6)
            let final = try value()
            #expect(midway > 0 && midway < final, "not animated: \(midway) → \(final)")

            let scrollFrame = try #require(try scrollArea.attribute(.frame))
            let marker = try #require(readable.marker(at: target.lowerBound, in: text))
            let range = try #require(try readable.handle.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [marker, marker]))
            let rect = try #require(try readable.handle.attribute(.boundsForTextMarkerRange, for: range))
            #expect(abs(rect.minY - (scrollFrame.minY + 16)) <= 2, "selection at \(rect.minY), scroll area top \(scrollFrame.minY)")
        }

        /// The app-wide AX flags (for Chromium's full AX tree) are on only while reading, and restored afterwards.
        @Test func togglesAppAccessibilityFlagsWhileReading() async throws {
            let page = try await readable()
            let app = AXElement.application(pid: browser.processIdentifier)
            func enhanced() -> Bool? { try? app.attribute(.enhancedUserInterface) }
            try #require(enhanced() != true, "flag already on before reading")
            let text = try #require(page.fullText)
            page.selection = try selection(of: "Paragraph 1 of", in: text)
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: page))
            try await reading.wait(timeout: 10)
            #expect(enhanced() == true)
            let stopped = recorder.expect(.stopped)
            reader.stop()
            try await stopped.wait(timeout: 5)
            #expect(enhanced() == false)
        }

        @Test func stopsWhenBrowserQuits() async throws {
            let page = try await readable()
            let text = try #require(page.fullText)
            page.selection = try selection(of: "Paragraph 1 of", in: text)
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: page))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            browser.terminate()
            try await stopped.wait(timeout: 5)
        }
    }
}
