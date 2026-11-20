import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// `WebAreaReadableElement` against `WebTestPage`: the same cross-process AX path as Safari.
    @MainActor
    @Suite(.axTrusted)
    struct WebAreaReadableElementTests {
        private let browser: Process
        private let recorder = StateRecorder()

        init() async throws {
            let browser = try WebTestPage.launch()
            self.browser = browser
            Teardown.add {
                browser.terminate()
                if (try? await waitUntil(timeout: 3) { !browser.isRunning }) == nil { kill(browser.processIdentifier, SIGKILL) }
            }
        }

        private func makeReader() -> EasyReader { makeSilentReader(recorder: recorder) }

        private func browserWindow() -> AXElement? {
            (try? AXElement.application(pid: browser.processIdentifier).attribute(.windows))?.first
        }

        private func readable() async throws -> WebAreaReadableElement {
            var readable: WebAreaReadableElement?
            try await waitUntil(timeout: 10, "web test page") {
                guard let window = browserWindow(), let element = findElement(role: .webArea, in: window) else { return false }
                readable = try element.readableElement() as? WebAreaReadableElement
                return readable?.fullText?.contains("The end of the test page.") == true
            }
            return try #require(readable)
        }

        @Test func readsPageText() async throws {
            let text = try #require(try await readable().fullText)
            #expect(text.contains("EasyReader test page"))
            #expect(text.contains("Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀."))
        }

        /// The marker for an offset maps back to it (AX index APIs alone drift), found from earlier markers or, fresh, from the page start.
        @Test func markerOffsetsRoundTrip() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let offsets = [
                0, 5, try Selection(of: "😀", in: text).lowerBound, try Selection(of: "🚀", in: text).lowerBound,
                try Selection(of: "🚀", in: text).upperBound, try Selection(of: "Paragraph 30 ", in: text).lowerBound,
                try Selection(of: "Paragraph 31 ", in: text).lowerBound, try Selection(of: "Paragraph 2 ", in: text).lowerBound,
                // Past the last `AXTextMarkerForIndex` index (indices run behind offsets).
                try Selection(of: "The end of", in: text).lowerBound + 4, text.utf16.count - 2, text.utf16.count,
            ]
            for offset in offsets {
                let marker = try #require(readable.marker(at: offset, in: text))
                let fresh = try #require(try readable.handle.readableElement() as? WebAreaReadableElement)
                #expect(fresh.offset(of: marker, in: text) == offset, "offset \(offset)")
            }
        }

        @Test func selectionRoundTrips() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let sentence = "Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀."
            let selection = try Selection(of: sentence, in: text)
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
            let start = try Selection(of: "Emoji take", in: text).lowerBound
            readable.selection = Selection(start..<start)
            for expected in ["Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀.", "This sentence comes after them."] {
                readable.selection = selector.select(.forward, from: try #require(readable.selection), in: text)
                #expect(readable.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
            }
        }

        @Test func readerFindsWebAreaFromWindowAndAdvances() async throws {
            let page = try await readable()
            let text = try #require(page.fullText)
            let first = try Selection(of: "This page tests reading web content.", in: text)
            page.selection = first
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: .element(try #require(browserWindow()))))
            try await reading.wait(timeout: 10)
            let readable = try #require(reader.readable as? WebAreaReadableElement)
            try await waitUntil(timeout: 5, "reading to advance") { (readable.selection?.lowerBound ?? 0) > first.lowerBound }
        }

        /// Starting from text inside the page (like focus on a link) climbs to the web area.
        @Test func findsWebAreaAsAncestor() async throws {
            let page = try await readable()
            let link = try #require(findElement(role: .staticText, in: page.handle) { (try? $0.attribute(.value) as String?) == "links" })
            let reader = makeReader()
            #expect(reader.start(reading: .element(link)))
            reader.stop()
            #expect((reader.readable as? WebAreaReadableElement)?.handle == page.handle)
        }

        /// A text area inside the page is read itself, not the page around it.
        @Test func textAreaInPageWins() async throws {
            let page = try await readable()
            let textArea = try #require(findElement(role: .textArea, in: page.handle))
            let reader = makeReader()
            #expect(reader.start(reading: .element(textArea)))
            reader.stop()
            #expect(reader.readable is TextAreaReadableElement)
        }

        @Test func scrollBringsSelectionIntoView() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let last = try Selection(of: "The end of the test page.", in: text)
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
            let target = try Selection(of: "Paragraph 30 ", in: text)
            let scrollArea = try #require(try readable.handle.parent(with: .scrollArea))
            let scrollBar = try #require(try scrollArea.attribute(.verticalScrollBar))
            func value() throws -> CGFloat { try #require(try scrollBar.attribute(.value)) }
            #expect(try value() == 0)

            let scrollFrame = try #require(try scrollArea.attribute(.frame))
            let marker = try #require(readable.marker(at: target.lowerBound, in: text))
            let range = try #require(try readable.handle.attribute(.textMarkerRangeForUnorderedTextMarkers, for: [marker, marker]))
            func top() throws -> CGFloat { try #require(try readable.handle.attribute(.boundsForTextMarkerRange, for: range)).minY }

            readable.scroll(to: target, options: ScrollOptions(padding: 16, duration: 0.6))
            try await waitUntil(timeout: 2, "scrolling to start") { try value() > 0 }
            let midway = try value()
            try? await waitUntil(timeout: 3, "selection at the top") { try abs(top() - (scrollFrame.minY + 16)) <= 2 }
            let final = try value()
            #expect(midway < final, "not animated: \(midway) → \(final)")
            let y = try top()
            #expect(abs(y - (scrollFrame.minY + 16)) <= 2, "selection at \(y), scroll area top \(scrollFrame.minY)")
        }

        @Test func startsAtMainContent() async throws {
            try WebPageChecks.startsAtMainContent(try await readable())
        }

        /// `WKWebView` has no `AXStartTextMarkerForBounds`.
        @Test func startsAtVisibleTop() async throws {
            try await WebPageChecks.startsAtVisibleTop(try await readable())
        }

        /// The app-wide AX flags (for Chromium's full AX tree) are on only while reading, and restored afterwards.
        @Test func togglesAppAccessibilityFlagsWhileReading() async throws {
            let page = try await readable()
            let app = AXElement.application(pid: browser.processIdentifier)
            func enhanced() -> Bool? { try? app.attribute(.enhancedUserInterface) }
            try #require(enhanced() != true, "flag already on before reading")
            let text = try #require(page.fullText)
            page.selection = try Selection(of: "Paragraph 1 of", in: text)
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
            page.selection = try Selection(of: "Paragraph 1 of", in: text)
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
