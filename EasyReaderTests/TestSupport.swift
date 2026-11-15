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

    func easyReaderDidStartUtterance(_ reader: EasyReader) {
        progressAtStarts.append(reader.progress)
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
