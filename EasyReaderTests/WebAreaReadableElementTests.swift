import AVFoundation
import AXSwift
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// Drives `WebAreaReadableElement` against `WebTestPage` (a `WKWebView` with a test page in its own process), the
    /// same cross-process AX path as Safari.
    /// Reading another process needs Accessibility permission, which CI lacks, so these only run where it's granted.
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

        /// Silent reader (see EasyReaderSpeechTests).
        private func makeReader() -> EasyReader {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.speechDelayBefore] = 0
            Defaults[.speechDelayAfter] = 0
            Defaults[.speechStopBoundary] = .immediate
            let reader = EasyReader()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            Teardown.add { reader.stop() }
            return reader
        }

        private func browserWindow() -> UIElement? {
            guard let app = Application(forProcessID: browser.processIdentifier) else { return nil }
            return (try? app.windows())?.first
        }

        private func find(role: String, in root: UIElement, where predicate: (UIElement) -> Bool = { _ in true }) -> UIElement? {
            var queue = [root]
            var visited = 0
            while !queue.isEmpty, visited < 5000 {
                let element = queue.removeFirst()
                visited += 1
                if (try? element.attribute(.role) as String?) == role, predicate(element) { return element }
                queue += (try? element.arrayAttribute(.children) as [UIElement]?) ?? []
            }
            return nil
        }

        /// The test page's web area, once loaded.
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

        /// A selection made in the page (here: from raw AX index markers, which don't line up with text offsets) is
        /// converted from the markers the browser reports.
        @Test(arguments: [100, 400, 1000])
        func readsSelectionMadeInPage(index: Int) async throws {
            let readable = try await readable()
            let element = readable.handle.element
            func value(_ attribute: String, _ parameter: AnyObject) throws -> AnyObject {
                var value: AnyObject?
                try #require(AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value) == .success)
                return try #require(value)
            }
            let start = try value("AXTextMarkerForIndex", index as CFNumber)
            let end = try value("AXTextMarkerForIndex", (index + 30) as CFNumber)
            let range = try value("AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
            try readable.handle.setAttribute("AXSelectedTextMarkerRange", value: range)
            await settle()
            var reported: AnyObject?
            try #require(AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &reported) == .success)
            let reportedRange = try #require(reported)
            let expected = try #require(try value("AXStringForTextMarkerRange", reportedRange) as? String)
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
                var range: AnyObject?
                var bounds: AnyObject?
                guard
                    AXUIElementCopyParameterizedAttributeValue(
                        readable.handle.element, "AXTextMarkerRangeForUnorderedTextMarkers" as CFString, [marker, marker] as CFArray, &range)
                        == .success, let range,
                    AXUIElementCopyParameterizedAttributeValue(readable.handle.element, "AXBoundsForTextMarkerRange" as CFString, range, &bounds)
                        == .success, let bounds
                else { return nil }
                var rect = CGRect.zero
                AXValueGetValue(bounds as! AXValue, .cgRect, &rect)
                return rect.minY
            }
            let before = try #require(top())
            readable.scroll(to: last, options: ScrollOptions(padding: 16, smooth: false, duration: 0, updateRate: 60))
            await settle(0.5)
            let after = try #require(top())
            #expect(after < before, "selection did not move up into view (\(before) → \(after))")
        }

        /// The app-wide AX flags (for Chromium's full AX tree) are on only while reading, and restored afterwards.
        @Test func togglesAppAccessibilityFlagsWhileReading() async throws {
            let page = try await readable()
            let app = try #require(Application(forProcessID: browser.processIdentifier))
            func enhanced() -> Bool? { try? app.attribute("AXEnhancedUserInterface") }
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
