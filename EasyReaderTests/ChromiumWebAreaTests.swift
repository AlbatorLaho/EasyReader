import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

/// Chrome for Testing from Playwright's cache (`npx playwright install chromium`), newest, with a throwaway profile.
enum ChromeForTesting {
    static let app: URL? = {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/ms-playwright")
        let versions = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        return versions.filter { $0.lastPathComponent.hasPrefix("chromium-") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .lazy.compactMap { version -> URL? in
                let builds = (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
                return builds.lazy.map { $0.appendingPathComponent("Google Chrome for Testing.app") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            }
            .first
    }()

    static var isAvailable: Bool { app != nil }

    /// Opens `url` in a new instance with a temporary profile and `--enable-features=<features>`.
    static func launch(_ url: URL, features: [String] = []) throws -> (Process, profile: URL) {
        let app = try #require(app, "no Chrome for Testing")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("EasyReaderChrome-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = app.appendingPathComponent("Contents/MacOS/Google Chrome for Testing")
        var arguments = [
            "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check", "--disable-sync",
            // Otherwise Chrome asks for the login keychain password (for "Chromium Safe Storage").
            "--use-mock-keychain", "--password-store=basic",
            "--window-position=100,100", "--window-size=900,700",
        ]
        if !features.isEmpty { arguments += ["--enable-features=\(features.joined(separator: ","))"] }
        process.arguments = arguments + [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, profile)
    }

    /// Opens `WebTestPage` in a new instance, killed at teardown.
    @MainActor
    static func launchTestPage(features: [String] = []) throws -> Process {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent("EasyReaderChromiumTestPage.html")
        try WebTestPage.html.write(to: page, atomically: true, encoding: .utf8)
        let (browser, profile) = try launch(page, features: features)
        Teardown.add {
            // SIGTERM only closes Chrome's windows
            kill(browser.processIdentifier, SIGKILL)
            try? await waitUntil(timeout: 5) { !browser.isRunning }
            try? FileManager.default.removeItem(at: profile)
        }
        return browser
    }

    @MainActor
    static func window(of browser: Process) -> AXElement? {
        (try? AXElement.application(pid: browser.processIdentifier).attribute(.windows))?.first
    }

    /// The test page's web area, once loaded (turns on Chromium's AX mode like `EasyReader`).
    @MainActor
    static func readable(in browser: Process) async throws -> WebAreaReadableElement {
        var readable: WebAreaReadableElement?
        var lastEnabled = Date.distantPast
        var state = "no window"
        do {
            try await waitUntil(timeout: 20, interval: 0.1, "Chrome test page") {
                if Date().timeIntervalSince(lastEnabled) >= 1 {
                    _ = AppAccessibility.enable(pid: browser.processIdentifier)
                    lastEnabled = Date()
                }
                guard let window = window(of: browser) else { return false }
                guard let element = findElement(role: .webArea, in: window) else {
                    state = "no web area in window \((try? window.attribute(.title)) ?? "?")"
                    return false
                }
                readable = try element.readableElement() as? WebAreaReadableElement
                state = "page text \(readable?.fullText?.utf16.count ?? -1) long"
                return readable?.fullText?.contains("The end of the test page.") == true
            }
        } catch is WaitTimeout {
            throw WaitTimeout(what: "Chrome test page (\(state))", timeout: 20)
        }
        return try #require(readable)
    }
}

extension IntegrationTests {
    /// `WebAreaReadableElement` against Chromium: overlay instead of selection, no block separators, leaf-based layout.
    @MainActor
    @Suite(
        .axTrusted,
        .enabled(if: ChromeForTesting.isAvailable, "needs Chrome for Testing: npx playwright install chromium")
    )
    struct ChromiumWebAreaTests {
        private let browser: Process
        private let recorder = StateRecorder()

        init() async throws {
            browser = try ChromeForTesting.launchTestPage()
        }

        private func makeReader() -> EasyReader { makeSilentReader(recorder: recorder) }

        private func readable() async throws -> WebAreaReadableElement { try await ChromeForTesting.readable(in: browser) }

        private func string(_ selection: Selection, in text: String) -> String {
            (text as NSString).substring(with: NSRange(selection)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Why blocks are needed: Chromium runs them together.
        @Test func pageTextHasNoBlockSeparators() async throws {
            let text = try #require(try await readable().fullText)
            #expect(text.contains("EasyReader test pageThis page tests reading web content."))
        }

        @Test func textBlocksAreParagraphs() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let heading = try Selection(of: "EasyReader test page", in: text)
            #expect(readable.textBlock(containing: heading.lowerBound + 3) == heading)
            let paragraph = "Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀. This sentence comes after them."
            let block = try #require(readable.textBlock(containing: try Selection(of: "offsets must", in: text).lowerBound))
            #expect(string(block, in: text) == paragraph)
            // A paragraph with a link and bold text in it is still one block.
            let mixed = try #require(readable.textBlock(containing: try Selection(of: "italic", in: text).lowerBound))
            #expect(string(mixed, in: text).hasPrefix("This page tests reading web content."))
            #expect(string(mixed, in: text).hasSuffix("text read inline."))
        }

        /// List items (with their bullet) and table rows are blocks of their own, also inline ones (Chromium makes each cell a paragraph).
        @Test(arguments: [("First item", "Second item"), ("Bulleted one", "Bulleted two"), ("Row one", "Row two")] as [(String, String)])
        func itemsAreBlocks(item: String, next: String) async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            func block(of string: String) throws -> String {
                let block = try #require(readable.textBlock(containing: try Selection(of: string, in: text).lowerBound + 1))
                return self.string(block, in: text).replacingOccurrences(of: "• ", with: "")
            }
            #expect(try block(of: item) == item)
            #expect(try block(of: next).hasPrefix(next.prefix(9)))
        }

        /// Sentences stop at block ends: the heading is read on its own.
        @Test func sentencesStayInBlocks() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let selector = NLTextSelector(unit: .sentence)
            let blocks: (Int) -> Selection? = { readable.textBlock(containing: $0) }
            let start = try Selection(of: "EasyReader test page", in: text).lowerBound
            var current = Selection(start..<start)
            var read: [String] = []
            for _ in 0..<4 {
                current = selector.select(.forward, from: current, in: text, blocks: blocks)
                read.append(string(current, in: text))
            }
            #expect(
                read == [
                    "EasyReader test page", "This page tests reading web content.",
                    "Select a sentence, then press the start shortcut.",
                    "Reading should continue sentence by sentence, with links, bold and italic text read inline.",
                ])
            let back = selector.select(.backward, from: try Selection(of: "Emoji take", in: text), in: text, blocks: blocks)
            #expect(string(back, in: text) == "Reading should continue sentence by sentence, with links, bold and italic text read inline.")
        }

        @Test func selectionIsHighlightedByOverlay() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let sentence = try Selection(of: "Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀.", in: text)
            #expect(!readable.canSelectByTextOperation)
            readable.selection = sentence
            #expect(readable.selection == sentence)
            let rects = try #require(readable.highlightRects(for: sentence))
            try #require(!rects.isEmpty)
            let frame = try #require(try readable.handle.attribute(.frame) as CGRect?)
            for rect in rects { #expect(frame.contains(rect)) }
            // The highlight is narrower than the page: just the sentence, not the whole web area.
            #expect(rects.allSatisfy { $0.width < frame.width - 40 && $0.height < 100 })
            #expect(readable.highlighted == sentence)
            readable.endReading()
            #expect(readable.highlighted == nil)
        }

        /// Page text drops the space a line wraps at, also when it starts the next leaf (" wraps here." after a link).
        @Test func highlightsLeafAfterCollapsedSpace() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let start = try Selection(of: "Narrow", in: text).lowerBound
            let end = try Selection(of: "here.", in: text).upperBound
            let rects = try #require(readable.highlightRects(for: Selection(start..<end)))
            // One word per line: "Narrow", "link", "wraps", "here.".
            #expect(Set(rects.map(\.minY)).count == 4, "\(rects)")
        }

        @Test func scrollBringsSelectionIntoView() async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let last = try Selection(of: "The end of the test page.", in: text)
            #expect(readable.highlightRects(for: last)?.isEmpty != false, "end of page visible before scrolling")
            readable.scroll(to: last, options: ScrollOptions(padding: 16, duration: 0))
            try await waitUntil(timeout: 2, "end of page visible after scrolling") { readable.highlightRects(for: last)?.isEmpty == false }
        }

        @Test func startsAtVisibleTop() async throws {
            try await WebPageChecks.startsAtVisibleTop(try await readable())
        }

        @Test func startsAtMainContent() async throws {
            try WebPageChecks.startsAtMainContent(try await readable())
        }

        @Test func readerAdvancesWithHighlight() async throws {
            let page = try await readable()
            let text = try #require(page.fullText)
            let first = try Selection(of: "This page tests reading web content.", in: text)
            page.selection = first
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: page))
            try await reading.wait(timeout: 10)
            try await waitUntil(timeout: 5, "reading to advance") { (page.selection?.lowerBound ?? 0) > first.lowerBound }
            let current = try #require(page.selection)
            #expect(page.highlighted == current)
            let stopped = recorder.expect(.stopped)
            reader.stop()
            try await stopped.wait(timeout: 5)
            #expect(page.highlighted == nil)
        }

        /// A fresh Chromium vends no page content until the reader turns its AX mode on (and off again on stop).
        @Test func readerEnablesPageContentInFreshBrowser() async throws {
            try await waitUntil(timeout: 10, "browser window") { ChromeForTesting.window(of: browser) != nil }
            let browserWindow = try #require(ChromeForTesting.window(of: browser))
            // Else the check below would pass with nothing loaded
            try await waitUntil(timeout: 5, "page loaded") {
                (try? browserWindow.attribute(.title) as String?)?.contains("EasyReader Test Page") == true
            }
            #expect(findElement(role: .webArea, in: browserWindow) == nil, "page content already vended")
            let app = AXElement.application(pid: browser.processIdentifier)
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: .element(browserWindow)))
            try await reading.wait(timeout: 15)
            #expect(reader.readable is WebAreaReadableElement)
            #expect((try? app.attribute(.enhancedUserInterface)) == true)
            let stopped = recorder.expect(.stopped)
            reader.stop()
            try await stopped.wait(timeout: 5)
            #expect((try? app.attribute(.enhancedUserInterface)) == false)
        }
    }

    /// Chromium with chrome://flags/#enable-accessibility-text-operation: a real selection via `AXTextOperation`.
    @MainActor
    @Suite(
        .axTrusted,
        .enabled(if: ChromeForTesting.isAvailable, "needs Chrome for Testing: npx playwright install chromium")
    )
    struct ChromiumTextOperationTests {
        private let browser: Process
        private let recorder = StateRecorder()

        init() async throws {
            browser = try ChromeForTesting.launchTestPage(features: ["MacAccessibilityTextOperation"])
        }

        private func readable() async throws -> WebAreaReadableElement {
            let readable = try await ChromeForTesting.readable(in: browser)
            try #require(readable.canSelectByTextOperation)
            return readable
        }

        private func makeReader() -> EasyReader { makeSilentReader(recorder: recorder) }

        private func browserSelectedText(_ readable: WebAreaReadableElement) -> String? {
            try? readable.handle.attribute(.selectedText)
        }

        @Test(arguments: [
            // Across a link, bold and italic text (several leaves).
            "Reading should continue sentence by sentence, with links, bold and italic text read inline.",
            // Emoji: marker steps are characters, offsets UTF-16 units.
            "Emoji take two UTF-16 code units 😀, so offsets must not drift 🚀.",
            "This sentence comes after them.",
            "The end of the test page.",
        ])
        func selectsInBrowser(sentence: String) async throws {
            let readable = try await readable()
            let text = try #require(readable.fullText)
            let target = try Selection(of: sentence, in: text)
            readable.selection = target
            // Applied asynchronously
            try? await waitUntil(timeout: 2) { browserSelectedText(readable) == sentence }
            #expect(browserSelectedText(readable) == sentence)
            #expect(readable.highlighted == nil)
            #expect(readable.selection == target)
        }

        @Test func readerAdvancesWithBrowserSelection() async throws {
            let page = try await readable()
            let text = try #require(page.fullText)
            let first = try Selection(of: "This page tests reading web content.", in: text)
            page.selection = first
            let reader = makeReader()
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: page))
            try await reading.wait(timeout: 10)
            try await waitUntil(timeout: 5, "reading to advance") { (page.selection?.lowerBound ?? 0) > first.lowerBound }
            let current = try #require(page.selection)
            #expect(browserSelectedText(page) == page.selectedText)
            #expect(page.highlighted == nil)
            let stopped = recorder.expect(.stopped)
            reader.stop()
            try await stopped.wait(timeout: 5)
        }
    }
}
