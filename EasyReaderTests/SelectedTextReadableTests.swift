import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    // An `AXTextField` has no readable element; its selection comes from `AXSelectedText` (can't copy from our own process).
    @MainActor
    struct SelectedTextReadableTests {
        private let window: NSWindow
        private let field: NSTextField
        private let reader = EasyReader()
        private let recorder = StateRecorder()
        private let text = "Alpha one. Beta two. Gamma three."

        init() async throws {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.speechDelayBefore] = 0
            Defaults[.speechDelayAfter] = 0
            Defaults[.speechStopBoundary] = .immediate
            Defaults[.pronunciations] = []
            reader.delegate = recorder
            reader.textSelector = NLTextSelector(unit: .sentence)
            field = NSTextField(string: text)
            window = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 400, height: 60),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Fallback Test \(UUID().uuidString)"
            window.contentView = field
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            let reader = reader
            let window = window
            Teardown.add { window.close() }
            Teardown.add { reader.stop() }
            await settle()
            let editor = try #require(field.currentEditor())
            editor.selectedRange = (text as NSString).range(of: "Beta two. Gamma three.")
            await settle()
        }

        private func start() -> Bool {
            reader.start(reading: .app(NSRunningApplication.current))
        }

        @Test func offByDefault() {
            Defaults[.readSelectedTextFallback] = false
            #expect(!start())
            #expect(reader.readable == nil)
        }

        @Test func readsTheSelectionThenStops() async throws {
            Defaults[.readSelectedTextFallback] = true
            let reading = recorder.expect(.reading)
            let stopped = recorder.expect(.stopped)
            #expect(start())
            let readable = try #require(reader.readable as? SelectedTextReadable)
            #expect(readable.fullText == "Beta two. Gamma three.")
            #expect(readable.title == window.title)
            try await reading.wait(timeout: 10)
            try await stopped.wait(timeout: 10)
            // went through to the end of the selected text
            let end = "Beta two. Gamma three.".utf16.count
            #expect(readable.selection == Selection(end..<end))
            // nothing was selected in the app
            #expect(field.currentEditor()?.selectedRange == (text as NSString).range(of: "Beta two. Gamma three."))
        }

        @Test func highlightsTheUnitBeingRead() async throws {
            Defaults[.readSelectedTextFallback] = true
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate
            let reading = recorder.expect(.reading)
            #expect(start())
            try await reading.wait(timeout: 10)
            let readable = try #require(reader.readable as? SelectedTextReadable)
            let unit = try #require(readable.highlighted)
            #expect(readable.selectedText == "Beta two. ")
            let rects = try #require(readable.highlightRects(for: unit))
            #expect(rects.count == 1)
            // over the unit's text in the field (AX: top-left origin)
            let screen = try #require(NSScreen.screens.first)
            let fieldFrame = window.convertToScreen(field.convert(field.bounds, to: nil))
            let fieldAX = CGRect(x: fieldFrame.minX, y: screen.frame.maxY - fieldFrame.maxY, width: fieldFrame.width, height: fieldFrame.height)
            let rect = try #require(rects.first)
            #expect(fieldAX.insetBy(dx: -1, dy: -1).contains(rect))
            // starts after "Alpha one. ", narrower than the whole text
            #expect(rect.minX > fieldAX.minX + 20)
            #expect(rect.width < fieldAX.width / 2)
            let stopped = recorder.expect(.stopped)
            reader.stop()
            try await stopped.wait(timeout: 10)
            #expect(readable.highlighted == nil)
        }

        @Test func startingWhilePausedResumesTheSameSelection() async throws {
            Defaults[.readSelectedTextFallback] = true
            Defaults[.speechRate] = AVSpeechUtteranceDefaultSpeechRate
            let reading = recorder.expect(.reading)
            #expect(start())
            try await reading.wait(timeout: 10)
            let readable = try #require(reader.readable)
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            let resumed = recorder.expect(.reading)
            #expect(start())
            try await resumed.wait(timeout: 10)
            #expect(reader.readable === readable)
        }
    }
}
