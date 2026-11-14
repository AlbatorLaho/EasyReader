import AVFoundation
import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    @MainActor
    struct AppDelegateTests {
        private let recorder = StateRecorder()

        init() {
            Defaults[.speechVolume] = 0
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.speechPitch] = 1
            Defaults[.speechDelayBefore] = 0
            Defaults[.speechDelayAfter] = 0
            Defaults[.speechStopBoundary] = .immediate
        }

        private func launch() async -> AppDelegate {
            let app = AppDelegate()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.easyReader.delegate = recorder
            Teardown.add {
                app.easyReader.stop()
                NSStatusBar.system.removeStatusItem(app.statusItem)
            }
            await settle(0.3)  // let the Defaults.updates loops subscribe
            return app
        }

        /// The readable's `selectedTextReads` counts utterances started.
        private func startReading(_ reader: EasyReader) async throws -> MockReadable {
            let readable = MockReadable(longText)
            let reading = recorder.expect(.reading)
            #expect(reader.start(reading: readable))
            try await reading.wait(timeout: 10)
            return readable
        }

        /// Settings… opens the settings window, and brings it to the front when it's already open behind another window.
        @Test func settingsMenuBringsOpenSettingsWindowToFront() async throws {
            let app = await launch()
            Teardown.add { SettingsOpener.window?.close() }
            let menu = try #require(app.statusItem.menu)
            let index = try #require(menu.items.firstIndex { $0.action == #selector(SettingsOpener.open) })
            menu.performActionForItem(at: index)
            await settle(1)
            let settings = try #require(SettingsOpener.window)
            #expect(settings.isVisible)
            let other = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
                defer: false)
            other.isReleasedWhenClosed = false
            Teardown.add { other.close() }
            other.makeKeyAndOrderFront(nil)
            await settle(0.3)
            #expect(!settings.isKeyWindow)
            menu.performActionForItem(at: index)
            await settle(0.5)
            #expect(NSApp.isActive)
            #expect(settings.isKeyWindow)
            #expect(NSApp.orderedWindows.first == settings)
        }

        @Test func speechSettingChangeRestartsReading() async throws {
            let app = await launch()
            let readable = try await startReading(app.easyReader)
            let reads = readable.selectedTextReads
            Defaults[.speechPitch] = 1.2
            await settle(0.5)
            #expect(readable.selectedTextReads > reads, "changing a speech setting should restart the utterance")
        }

        /// A change while not reading must not end the speech-settings loop.
        @Test func speechSettingChangeWhileStoppedStillRestartsLater() async throws {
            let app = await launch()
            Defaults[.speechPitch] = 1.1  // while stopped
            await settle(0.3)
            let readable = try await startReading(app.easyReader)
            let reads = readable.selectedTextReads
            Defaults[.speechPitch] = 1.2
            await settle(0.5)
            #expect(readable.selectedTextReads > reads)
        }

        /// Now Playing publishes `SpeechRate.multiplier(forRate:)`; the rate command must map it back.
        @Test(arguments: [Float(0.4), 0.7])
        func nowPlayingRateRoundTrips(rate: Float) {
            Defaults[.speechRate] = rate
            let published = SpeechRate.multiplier(forRate: rate)  // NowPlayingManager.playbackInfo
            NowPlayingManager.setSpeechRate(fromPlaybackRate: published)
            #expect(isClose(Defaults[.speechRate], rate))
        }

        @Test func rateChangesClampAtWriteSite() {
            NowPlayingManager.setSpeechRate(fromPlaybackRate: 10)
            #expect(Defaults[.speechRate] == AVSpeechUtteranceMaximumSpeechRate)
        }
    }
}
