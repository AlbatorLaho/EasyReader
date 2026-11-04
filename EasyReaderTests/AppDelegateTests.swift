import AVFoundation
import AppKit
import Defaults
import XCTest

@testable import EasyReader

/// Exercises `AppDelegate` wiring. Each test launches its own delegate (status item, settings loops)
/// rather than relying on the test host's, so the loops start fresh.
final class AppDelegateTests: XCTestCase, EasyReaderDelegate {
    private var app: AppDelegate?
    private var pending: [(state: EasyReader.State, expectation: XCTestExpectation)] = []

    override func setUp() {
        super.setUp()
        Defaults[.speechVolume] = 0
        Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
        Defaults[.speechPitch] = 1
        Defaults[.speechDelayBefore] = 0
        Defaults[.speechDelayAfter] = 0
        Defaults[.speechStopBoundary] = .immediate
    }

    override func tearDown() {
        if let app {
            app.easyReader.stop()
            NSStatusBar.system.removeStatusItem(app.statusItem)
        }
        app = nil
        pending = []
        super.tearDown()
    }

    func easyReader(_ reader: EasyReader, didChangeState state: EasyReader.State) {
        for entry in pending where entry.state == state { entry.expectation.fulfill() }
        pending.removeAll { $0.state == state }
    }

    private func expect(_ state: EasyReader.State) -> XCTestExpectation {
        let expectation = expectation(description: "state \(state)")
        pending.append((state, expectation))
        return expectation
    }

    private func launch() -> AppDelegate {
        let app = AppDelegate()
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        app.easyReader.delegate = self
        self.app = app
        spinRunLoop(0.3)  // let the Defaults.updates loops subscribe
        return app
    }

    /// Starts reading long text; the readable's `selectedTextReads` counts utterances started.
    private func startReading(_ reader: EasyReader) -> MockReadable {
        let readable = MockReadable(Array(repeating: "This is a fairly long sentence to keep speaking.", count: 20).joined(separator: " "))
        let reading = expect(.reading)
        XCTAssertTrue(reader.start(reading: readable))
        wait(for: [reading], timeout: 10)
        return readable
    }

    func testSpeechSettingChangeRestartsReading() {
        let app = launch()
        let readable = startReading(app.easyReader)
        let reads = readable.selectedTextReads
        Defaults[.speechPitch] = 1.2
        spinRunLoop(0.5)
        XCTAssertGreaterThan(readable.selectedTextReads, reads, "changing a speech setting should restart the utterance")
    }

    /// A change while not reading must not end the speech-settings loop.
    func testSpeechSettingChangeWhileStoppedStillRestartsLater() {
        let app = launch()
        Defaults[.speechPitch] = 1.1  // while stopped
        spinRunLoop(0.3)
        let readable = startReading(app.easyReader)
        let reads = readable.selectedTextReads
        Defaults[.speechPitch] = 1.2
        spinRunLoop(0.5)
        XCTAssertGreaterThan(readable.selectedTextReads, reads)
    }

    /// Now Playing publishes `SpeechRate.multiplier(forRate:)`; the rate command must map it back.
    func testNowPlayingRateRoundTrips() {
        for rate: Float in [0.4, 0.7] {
            Defaults[.speechRate] = rate
            let published = SpeechRate.multiplier(forRate: rate)  // NowPlayingManager.updatePlaybackInfo
            AppDelegate().setSpeechRate(fromPlaybackRate: published)
            XCTAssertEqual(Defaults[.speechRate], rate, accuracy: 0.001)
        }
    }

    func testRateChangesClampAtWriteSite() {
        let app = AppDelegate()
        app.setSpeechRate(fromPlaybackRate: 10)
        XCTAssertEqual(Defaults[.speechRate], AVSpeechUtteranceMaximumSpeechRate)
    }
}
