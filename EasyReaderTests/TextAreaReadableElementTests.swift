import AVFoundation
import AppKit
import Defaults
import SwiftUI
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct TextAreaReadableElementTests {
        private struct TextAreaNotFound: Error, CustomStringConvertible {
            var description: String { "no AXTextArea found" }
        }

        private let window: NSWindow
        private let scrollView: NSScrollView
        private let textView: NSTextView
        private let recorder = StateRecorder()
        private let text = (1...80).map { "Sentence 😀 number \($0)." }.joined(separator: "\n")

        init() async throws {
            scrollView = NSTextView.scrollableTextView()
            textView = try #require(scrollView.documentView as? NSTextView)
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
            let window = window
            Teardown.add { window.close() }
            await settle()
        }

        private func makeReader() -> EasyReader {
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            let reader = EasyReader()
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            Teardown.add { reader.stop() }  // runs before the window closes (newest first)
            return reader
        }

        private func axWindow(for window: NSWindow) throws -> AXElement {
            let app = AXElement.application(pid: getpid())
            let windows = try #require(try app.attribute(.windows))
            return try #require(
                windows.first(where: { (try? $0.attribute(.title) as String?) == window.title }),
                "test window not found in AX tree"
            )
        }

        private func readable() throws -> TextAreaReadableElement {
            var queue = [try axWindow(for: window)]
            while !queue.isEmpty {
                let element = queue.removeFirst()
                if let readable = try element.readableElement() {
                    return try #require(readable as? TextAreaReadableElement)
                }
                queue += (try? element.attribute(.children)) ?? []
            }
            throw TextAreaNotFound()
        }

        @Test func findsTextAreaWithFullText() throws {
            let readable = try readable()
            #expect(readable.fullText == text)
            #expect(readable.appDomain == Bundle.main.bundleIdentifier)
            #expect(readable.title == window.title)
        }

        /// A key whose type doesn't match what the app vends throws (instead of crashing); a missing attribute is nil.
        @Test func typedAttributesCheckValueTypes() throws {
            let handle = try readable().handle
            #expect(try handle.attribute(.frame) != nil)
            #expect(throws: AXFailure.self) { try handle.attribute(AXAttribute<CGRect>(kAXValueAttribute)) }
            #expect(try handle.attribute(AXAttribute<String>("AXNoSuchAttribute")) == nil)
            #expect(try handle.attribute(.boundsForRange, for: CFRange(location: 0, length: 3))?.isEmpty == false)
        }

        @Test func settingSelectionUpdatesTextView() throws {
            let readable = try readable()
            readable.selection = Selection(3..<9)
            #expect(textView.selectedRange() == NSRange(location: 3, length: 6))
            #expect(readable.selection == Selection(3..<9))
            #expect(readable.selectedText == (text as NSString).substring(with: NSRange(location: 3, length: 6)))
        }

        @Test func readsSelectionChangedInTextView() throws {
            let readable = try readable()
            textView.setSelectedRange(NSRange(location: 20, length: 4))
            #expect(readable.selection == Selection(20..<24))
        }

        /// AX ranges are UTF-16; each 😀 is two code units, so offsets drift if treated as Characters.
        @Test func selectorStepsThroughNonBMPTextViaAX() throws {
            let readable = try readable()
            let selector = NLTextSelector(unit: .sentence)
            readable.selection = Selection()
            for n in 1...3 {
                let next = selector.select(.forward, from: try #require(readable.selection), in: try #require(readable.fullText))
                readable.selection = next
                #expect(readable.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines) == "Sentence 😀 number \(n).")
            }
        }

        @Test func scrollBringsSelectionIntoView() async throws {
            let readable = try readable()
            #expect(scrollView.contentView.bounds.origin.y == 0)
            let last = Selection((text as NSString).range(of: "Sentence 😀 number 80."))
            readable.selection = last
            scrollView.contentView.scroll(to: .zero)  // selecting may auto-scroll; reset to test our scroll code
            await settle()
            readable.scroll(to: last, options: ScrollOptions(padding: 16, duration: 0))
            await settle()
            #expect(scrollView.contentView.bounds.origin.y > 0)
        }

        /// SwiftUI's `TextEditor` reports only its visible frame, so the full text's bounds give the document size.
        @Test func scrollsSwiftUITextEditor() async throws {
            struct Editor: View {
                @State var text = (1...80).map { "Sentence number \($0)." }.joined(separator: " ")
                var body: some View { TextEditor(text: $text).font(.system(size: 24)) }
            }
            let editorWindow = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 400, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            editorWindow.isReleasedWhenClosed = false
            editorWindow.title = "AX SwiftUI Test \(UUID().uuidString)"
            editorWindow.contentView = NSHostingView(rootView: Editor())
            editorWindow.makeKeyAndOrderFront(nil)
            editorWindow.makeFirstResponder(nil)  // like Settings before any click
            Teardown.add { editorWindow.close() }
            await settle(0.5)

            let reader = makeReader()
            #expect(reader.start(reading: .element(try axWindow(for: editorWindow))))
            reader.stop()
            let readable = try #require(reader.readable as? TextAreaReadableElement)
            let fullText = try #require(readable.fullText)
            let target = Selection((fullText as NSString).range(of: "Sentence number 70."))

            let scrollArea = try #require(try readable.handle.parent(with: .scrollArea))
            let scrollBar = try #require(try scrollArea.attribute(.verticalScrollBar))
            readable.selection = target
            await settle(0.3)
            try scrollBar.set(.value, to: CGFloat(0))  // selecting may auto-scroll; reset
            await settle(0.3)
            readable.scroll(to: target, options: ScrollOptions(padding: 16, duration: 0))
            await settle(0.3)
            let value: CGFloat = try #require(try scrollBar.attribute(.value))
            #expect(value > 0.5)
        }

        @Test(
            arguments: [
                (50, 100, 0.5),
                (-16, 100, 0),
                (150, 100, 1),
                (10, 0, 0),
                (10, -20, 0),
            ] as [(CGFloat, CGFloat, CGFloat)])
        func scrollValueIsClamped(offset: CGFloat, scrollableLength: CGFloat, expected: CGFloat) {
            #expect(ScrollBarScroller.scrollValue(offset: offset, scrollableLength: scrollableLength) == expected)
        }

        /// `findReadableElement` descends via `.childrenInNavigationOrder`; AppKit supports it (other apps may not).
        @Test func findsTextAreaStartingFromWindow() throws {
            let reader = makeReader()
            let start = try axWindow(for: window)
            #expect(reader.start(reading: .element(start)))
        }

        /// The search must not climb past the window and find (and focus) a text area in another window.
        @Test func doesNotLeaveStartingWindow() async throws {
            let other = NSWindow(contentRect: NSRect(x: 650, y: 200, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.title = "AX Other \(UUID().uuidString)"
            other.contentView = NSButton(title: "No text here", target: nil, action: nil)
            other.makeKeyAndOrderFront(nil)
            defer { other.close() }
            await settle()
            let reader = makeReader()
            let start = try axWindow(for: other)
            #expect(!reader.start(reading: .element(start)))
        }

        @Test func stopsWhenTextViewIsRemoved() async throws {
            textView.string = Array(repeating: "word", count: 400).joined(separator: " ") + "."
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: try readable()))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            window.contentView = NSView()
            await settle()
            try await stopped.wait(timeout: 3)
        }

        /// Closing the window only destroys the window element; the text area still answers AX.
        @Test func stopsWhenWindowCloses() async throws {
            textView.string = Array(repeating: "word", count: 400).joined(separator: " ") + "."
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: try readable()))
            try await reading.wait(timeout: 10)
            let stopped = recorder.expect(.stopped)
            window.close()
            try await stopped.wait(timeout: 3)
        }
    }
}

struct TextAreaContentFrameTests {
    private let scrollArea = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test(
        arguments: [
            (CGRect(x: 0, y: -500, width: 385, height: 2000), false),  // NSTextView: as tall as its text, as wide as the scroll area
            (CGRect(x: 0, y: 0, width: 400, height: 300), true),  // TextEditor: its visible rect
            (CGRect(x: 0, y: 0, width: 385, height: 120), true),  // short text that fits: cheap either way
        ] as [(CGRect, Bool)])
    func visibleRectOnlyByHeight(elementFrame: CGRect, expected: Bool) {
        #expect(TextAreaReadableElement.showsOnlyVisibleRect(elementFrame: elementFrame, scrollAreaFrame: scrollArea) == expected)
    }
}
