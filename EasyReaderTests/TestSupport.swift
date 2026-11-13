import AppKit
import Testing

@testable import EasyReader

// MARK: - Integration suite

/// Parent of every suite that touches shared global state: the settings store (`Defaults` / `UserDefaults.app`),
/// the real `AVSpeechSynthesizer`, NSWindows and key-window focus, status items.
/// Swift Testing runs tests in parallel (one process) by default; `.serialized` is inherited by the nested suites
/// (declared in `extension IntegrationTests` in their own files) and their parameterized cases, so these run one at a time.
/// Pure-logic suites stay top-level and parallel. `.teardown` runs each test's `Teardown.add` blocks.
@MainActor
@Suite(.serialized, .teardown)
struct IntegrationTests {
    /// Tests write `Defaults` freely; that is only safe while the store is in-memory (`Defaults.swift` detects the test run).
    @Test func settingsStoreIsInMemory() {
        #expect(UserDefaults.app !== UserDefaults.standard)
    }
}

/// Per-test teardown, like XCTest's `addTeardownBlock`. Suites register cleanup in `init` (a struct has no `deinit`,
/// and `deinit` can't be async); the `.teardown` trait runs the blocks newest-first after each test case,
/// also when the test throws. It also checks that no two integration tests overlap.
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
    }

    fileprivate static func end() async {
        while let block = blocks.popLast() { await block() }
        isRunningTest = false
    }
}

struct TeardownTrait: SuiteTrait, TestTrait, TestScoping {
    /// Recursive: the default `scopeProvider` then wraps every test case of every nested suite, not the suite once.
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
    /// Repros of known crashes take down the whole test process, so they only run on request:
    ///
    ///     TEST_RUNNER_EASYREADER_CRASH_REPROS=1 xcodebuild test ... '-only-testing:EasyReaderTests/SelectionTests/outOfRangeOffsetCrashes()'
    ///
    /// (`xcodebuild` strips the `TEST_RUNNER_` prefix and passes the rest to the test process.)
    /// Run them one at a time with `-only-testing`; the first crash ends the run.
    /// Once a bug is fixed, remove the trait so the test runs (and guards the fix) by default.
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

/// `EasyReaderDelegate` that records state changes, so tests can await one that happens later.
/// Create the expectation with `expect(_:)` *before* the action that triggers it: fast transitions
/// (e.g. reading → stopped on a short text) would be missed by polling or by subscribing afterwards.
@MainActor
final class StateRecorder: EasyReaderDelegate {
    @MainActor
    final class Expectation {
        let state: EasyReader.State
        /// Position of the fulfilling event among all recorded events (for checking order).
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

        /// Returns once the state was entered (since `expect`), or throws `StateTimeout`.
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
    private var pending: [Expectation] = []

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

/// In-memory readable that records what EasyReader does to it.
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
    /// What `selectedText` returned, in order.
    private(set) var selectedTexts: [String] = []
    var selectedText: String? {
        selectedTextReads += 1
        guard let fullText, let selection, let range = Range(selection, in: fullText) else { return nil }
        selectedTexts.append(String(fullText[range]))
        return String(fullText[range])
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

/// Lets AX, AppKit and speech callbacks settle: suspends the test so the host app's main run loop keeps running.
func settle(_ seconds: TimeInterval = 0.1) async {
    try? await Task.sleep(seconds: seconds)
}
