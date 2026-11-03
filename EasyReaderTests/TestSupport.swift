import AppKit
import XCTest

@testable import EasyReader

/// Repros of known crashes take down the whole test process, so they only run on request:
///
///     TEST_RUNNER_EASYREADER_CRASH_REPROS=1 xcodebuild test ... -only-testing:EasyReaderTests/SelectionTests/testOutOfRangeOffsetCrashes
///
/// (`xcodebuild` strips the `TEST_RUNNER_` prefix and passes the rest to the test process.)
/// Run them one at a time with `-only-testing`; the first crash ends the run.
/// Once a bug is fixed, delete the call so the test runs (and guards the fix) by default.
func skipUnlessCrashReprosEnabled() throws {
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["EASYREADER_CRASH_REPROS"] == "1",
        "Known crash; set TEST_RUNNER_EASYREADER_CRASH_REPROS=1 to reproduce"
    )
}

/// In-memory readable that records what EasyReader does to it.
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
    var selectedText: String? {
        selectedTextReads += 1
        guard let fullText, let selection, let range = Range(selection, in: fullText) else { return nil }
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

func spinRunLoop(_ seconds: TimeInterval = 0.1) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}
