import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

// MARK: - Integration suite

/// Parent of every suite touching shared state (Defaults, synthesizer, windows, status items): runs them one at a time.
@MainActor
@Suite(.serialized, .teardown)
struct IntegrationTests {
    // Tests write `Defaults` freely: only safe while the store is in-memory.
    @Test func settingsStoreIsInMemory() {
        #expect(UserDefaults.app !== UserDefaults.standard)
    }
}

/// Per-test teardown, like XCTest's `addTeardownBlock`: blocks run newest-first after each test case, also after a throw.
@MainActor
enum Teardown {
    fileprivate static var blocks: [@MainActor () async -> Void] = []
    fileprivate static var isRunningTest = false

    static func add(_ block: @escaping @MainActor () async -> Void) {
        blocks.append(block)
    }

    fileprivate static func begin(_ test: String) {
        #expect(!isRunningTest, "integration test \(test) overlaps another one: serialization broken")
        isRunningTest = true
        // Each test starts from the defaults (the in-memory store lasts the whole run), silent
        Defaults.removeAll(suite: .app)
        Defaults[.speechVolume] = 0
        // Window tests expect a regular app (Dock icon, activation), and closing Settings must not hide the host
        Defaults[.appPresence] = .both
        NSApp.setActivationPolicy(.regular)
    }

    fileprivate static func end() async {
        while let block = blocks.popLast() { await block() }
        isRunningTest = false
    }
}

struct TeardownTrait: SuiteTrait, TestTrait, TestScoping {
    // Wraps every test case of every nested suite, not the suite once.
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        await Teardown.begin(test.name)
        do {
            try await function()
        } catch {
            await Teardown.end()
            throw error
        }
        await Teardown.end()
    }
}

extension Trait where Self == TeardownTrait {
    static var teardown: Self { Self() }
}

// MARK: - Traits

extension Trait where Self == ConditionTrait {
    /// For suites driving another process through AX (the test host is trusted only with the Debug app's grant).
    static var axTrusted: Self {
        .enabled(if: AXIsProcessTrusted(), "needs Accessibility permission for the test host (Debug EasyReader)")
    }
}

// MARK: - Known crashes

extension Trait where Self == ConditionTrait {
    /// Known crashes take down the test process: run one with `TEST_RUNNER_EASYREADER_CRASH_REPROS=1 xcodebuild test ... -only-testing:…`.
    static var crashRepro: Self {
        .enabled(
            if: ProcessInfo.processInfo.environment["EASYREADER_CRASH_REPROS"] == "1",
            "Known crash; set TEST_RUNNER_EASYREADER_CRASH_REPROS=1 to reproduce"
        )
    }
}

// MARK: - Waiting on reader state

struct StateTimeout: Error, CustomStringConvertible {
    let state: EasyReader.State
    let timeout: TimeInterval
    var description: String { "timed out after \(timeout)s waiting for state \(state)" }
}

/// Records state changes. Call `expect(_:)` *before* the action: fast transitions would be missed afterwards.
@MainActor
final class StateRecorder: EasyReader.Delegate {
    @MainActor
    final class Expectation {
        let state: EasyReader.State
        /// Index of the fulfilling event among all recorded events.
        fileprivate(set) var order: Int?
        private var continuation: CheckedContinuation<Void, any Error>?
        private var timeoutTask: Task<Void, Never>?

        fileprivate init(state: EasyReader.State) { self.state = state }

        fileprivate func fulfill(order: Int) {
            self.order = order
            continuation?.resume()
            continuation = nil
            timeoutTask?.cancel()
        }

        func wait(timeout: TimeInterval) async throws {
            guard order == nil else { return }
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(seconds: timeout)
                    guard let self, let continuation = self.continuation else { return }
                    self.continuation = nil
                    continuation.resume(throwing: StateTimeout(state: self.state, timeout: timeout))
                }
            }
        }
    }

    private(set) var events: [EasyReader.State] = []
    private(set) var progressAtStarts: [EasyReader.Progress?] = []
    private var pending: [Expectation] = []
    private var pendingStarts: [Expectation] = []

    func easyReaderDidStartUtterance(_ reader: EasyReader) {
        progressAtStarts.append(reader.progress)
        for expectation in pendingStarts { expectation.fulfill(order: progressAtStarts.count - 1) }
        pendingStarts.removeAll()
    }

    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        events.append(state)
        for expectation in pending where expectation.state == state { expectation.fulfill(order: events.count - 1) }
        pending.removeAll { $0.state == state }
    }

    func expect(_ state: EasyReader.State) -> Expectation {
        let expectation = Expectation(state: state)
        pending.append(expectation)
        return expectation
    }

    /// The next utterance start (also restarts and resumes, which stay `.reading`); `order` indexes `progressAtStarts`.
    func expectUtteranceStart() -> Expectation {
        let expectation = Expectation(state: .reading)
        pendingStarts.append(expectation)
        return expectation
    }
}

// MARK: - Helpers

@MainActor
final class MockReadable: Readable {
    let title: String? = "Mock"
    let groupTitle: String? = nil
    let appDomain: String?
    let icon: NSImage? = nil
    let fullText: String?
    var selection: Selection? {
        didSet { if let selection { history.append(selection) } }
    }
    var onInvalidate: (() -> Void)?
    var contentStart = 0
    var contentEnd: Int?
    private(set) var history: [Selection] = []
    private(set) var scrolls: [Selection] = []
    /// EasyReader reads `selectedText` once per utterance it starts.
    private(set) var selectedTextReads = 0
    private(set) var selectedTexts: [String] = []
    var selectedText: String? {
        selectedTextReads += 1
        guard let fullText, let selection, let range = Range(selection, in: fullText) else { return nil }
        let text = String(fullText[range])
        selectedTexts.append(text)
        return text
    }

    init(_ text: String, selection: Selection = Selection(), appDomain: String? = nil) {
        fullText = text
        self.selection = selection
        self.appDomain = appDomain
    }

    /// The selected unit, trimmed.
    var selectedUnit: String? { selection.flatMap(text(of:)) }

    func text(of selection: Selection) -> String? {
        guard let fullText, let range = Range(selection, in: fullText) else { return nil }
        return String(fullText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scroll(to selection: Selection, options: ScrollOptions) {
        scrolls.append(selection)
    }

    private(set) var beginReadings = 0
    private(set) var endReadings = 0
    func beginReading() { beginReadings += 1 }
    func endReading() { endReadings += 1 }
}

let longText = Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " ")

/// Suspends the test so the main run loop keeps running (AX, AppKit and speech callbacks).
func settle(_ seconds: TimeInterval = 0.1) async {
    try? await Task.sleep(seconds: seconds)
}

struct WaitTimeout: Error, CustomStringConvertible {
    let what: String
    let timeout: TimeInterval
    var description: String { "timed out after \(timeout)s waiting for \(what)" }
}

/// Polls `condition` (every `interval`, run loop running) until it holds; throws once `timeout` has passed.
@MainActor
func waitUntil(
    timeout: TimeInterval, interval: TimeInterval = 0.05, _ what: String = "condition", _ condition: () throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try !condition() {
        guard Date() < deadline else { throw WaitTimeout(what: what, timeout: timeout) }
        await settle(interval)
    }
}

/// Closes every reader window, newest first: the oldest is the one kept for reuse, so windows made by a test are dropped.
@MainActor
func closeReaderWindows() {
    for readerWindow in ReaderWindow.windows.reversed() { readerWindow.window.close() }
}

func isClose(_ a: Float, _ b: Float, tolerance: Float = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

struct NotFound: Error, CustomStringConvertible {
    let what: String
    var description: String { "\(what) not found" }
}

extension Selection {
    /// Where `string` first occurs in `text` (last with `.backwards`).
    init(of string: String, in text: String, options: NSString.CompareOptions = []) throws {
        let range = (text as NSString).range(of: string, options: options)
        try #require(range.location != NSNotFound, "\(string.debugDescription) not in \(text.prefix(200).debugDescription)")
        self.init(range)
    }
}

// MARK: - Readers, windows, AX

/// A silent reader (volume 0 from `Teardown.begin`, maximum rate) reporting to `recorder`; stopped at teardown (waiting for it with a recorder).
@MainActor
func makeSilentReader(recorder: StateRecorder? = nil, unit: Selection.Unit = .sentence) -> EasyReader {
    Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
    let reader = EasyReader()
    reader.delegate = recorder
    reader.textSelector = NLTextSelector(unit: unit)
    Teardown.add {
        // Also cancels an utterance that hasn't started yet (synchronous tests)
        guard let recorder, reader.state != .stopped else {
            reader.stop()
            return
        }
        let stopped = recorder.expect(.stopped)
        reader.stop()
        do { try await stopped.wait(timeout: 5) } catch { Issue.record(error) }
    }
    return reader
}

/// A titled window showing `content`, key and in front, closed at teardown; `axWindow(of:)` finds it by its accessibility identifier.
@MainActor
func makeTestWindow(
    _ content: NSView? = nil, title: String = "Test", frame: NSRect = NSRect(x: 200, y: 200, width: 400, height: 200)
) -> NSWindow {
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "\(title) \(UUID().uuidString)"
    window.setAccessibilityIdentifier(UUID().uuidString)
    if let content { window.contentView = content }
    window.makeKeyAndOrderFront(nil)
    Teardown.add { window.close() }
    return window
}

/// `window`'s element in the host's AX tree.
@MainActor
func axWindow(of window: NSWindow) throws -> AXElement {
    let windows = try #require(try AXElement.application(pid: getpid()).attribute(.windows))
    let identifier = window.accessibilityIdentifier()
    return try #require(windows.first { (try? $0.attribute(.identifier)) == identifier }, "window \(window.title) not in the AX tree")
}

/// The first readable element in `window`, breadth-first.
@MainActor
func readableElement<T: ReadableElement>(in window: NSWindow, as type: T.Type = T.self) throws -> T {
    var queue = [try axWindow(of: window)]
    while !queue.isEmpty {
        let element = queue.removeFirst()
        if let readable = try element.readableElement() { return try #require(readable as? T, "found \(Swift.type(of: readable))") }
        queue += (try? element.attribute(.children)) ?? []
    }
    throw NotFound(what: "readable element in \(window.title)")
}

/// Breadth-first, at most 5000 elements (web pages).
@MainActor
func findElement(role: AXRole, in root: AXElement, where predicate: (AXElement) -> Bool = { _ in true }) -> AXElement? {
    var queue = [root]
    var visited = 0
    while !queue.isEmpty, visited < 5000 {
        let element = queue.removeFirst()
        visited += 1
        if (try? element.role()) == role, predicate(element) { return element }
        queue += (try? element.attribute(.children)) ?? []
    }
    return nil
}

@MainActor
func firstSubview<T: NSView>(_ type: T.Type, in view: NSView?, where predicate: (T) -> Bool = { _ in true }) -> T? {
    guard let view else { return nil }
    if let match = view as? T, predicate(match) { return match }
    for subview in view.subviews {
        if let match = firstSubview(type, in: subview, where: predicate) { return match }
    }
    return nil
}

/// A pasteboard of its own, released at teardown.
@MainActor
func uniquePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyReaderTests-\(UUID().uuidString)"))
    Teardown.add { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    return pasteboard
}

// MARK: - Web pages (WebKit and Chromium suites)

enum WebPageChecks {
    /// Without a page selection, reading starts at the main content, past the page's navigation, and ends before its footer.
    @MainActor
    static func startsAtMainContent(_ page: WebAreaReadableElement) throws {
        let text = try #require(page.fullText)
        let heading = try Selection(of: "EasyReader test page", in: text).lowerBound
        #expect(page.contentStart == heading)
        let end = try #require(page.contentEnd)
        #expect(try Selection(of: "The end of the test page.", in: text).upperBound <= end)
        #expect(end <= (try Selection(of: "Page footer.", in: text)).lowerBound)
        #expect(page.selection == Selection(heading..<heading))
    }

    /// Without a page selection, reading starts at the first visible text, not the top of the page.
    @MainActor
    static func startsAtVisibleTop(_ page: WebAreaReadableElement) async throws {
        let text = try #require(page.fullText)
        let target = try Selection(of: "Paragraph 30 ", in: text)
        page.scroll(to: target, options: ScrollOptions(padding: 16, duration: 0))
        await settle(0.5)
        let fresh = try #require(try page.handle.readableElement() as? WebAreaReadableElement)
        let start = try #require(fresh.selection)
        #expect(start.isEmpty)
        #expect(start.lowerBound > (try Selection(of: "Paragraph 10 ", in: text)).lowerBound)
        #expect(start.lowerBound <= target.lowerBound)
    }
}
