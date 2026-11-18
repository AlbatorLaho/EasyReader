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
            Defaults[.speechRate] = AVSpeechUtteranceMaximumSpeechRate
            Defaults[.speechPitch] = 1
        }

        private func launch() async -> AppDelegate {
            let previousReader = ReaderWindow.reader
            let previousServicesProvider = NSApp.servicesProvider
            let app = AppDelegate()
            app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            app.easyReader.delegate = recorder
            Teardown.add {
                app.easyReader.stop()
                app.stopObserving()
                ReaderWindow.reader = previousReader
                NSApp.servicesProvider = previousServicesProvider
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
            let menu = app.statusMenu
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

        private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyReaderTests-\(UUID().uuidString)"))
            Teardown.add { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            write(pasteboard)
            return pasteboard
        }

        /// Read with EasyReader (or a drop on the menu bar icon) puts the text in the reader window and reads it there; the controls follow,
        /// with Start and Resume told apart.
        @Test func readServiceReadsTextInReaderWindow() async throws {
            let app = await launch()
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            let reading = recorder.expect(.reading)
            #expect(ReaderWindow.read(pasteboard { $0.setString(longText, forType: .string) }))
            try await reading.wait(timeout: 10)
            let reader = try #require(ReaderWindow.front)
            #expect(reader.textView.string == longText)
            #expect(app.easyReader.readable is TextAreaReadableElement)
            ReaderWindow.updateToolbars()  // the app's own reader delegate does this; here the recorder replaced it
            let items = try #require(reader.window.toolbar?.items)
            #expect(items.first?.label == "Stop")

            let paused = recorder.expect(.paused)
            #expect(app.easyReader.togglePlayPause())
            try await paused.wait(timeout: 5)
            ReaderWindow.updateToolbars()
            #expect(items.map(\.label) == ["Start", "Resume", "Skip Backward", "Skip Forward"])
            let start = PlaybackControl.startStop.appearance(for: app.easyReader)
            let resume = PlaybackControl.playPause.appearance(for: app.easyReader)
            #expect(start.symbols.first != resume.symbols.first)
            #expect(start.image != nil)
            let menuItem = try #require(app.statusMenu.items.first { $0.action == #selector(AppDelegate.toggleStartStopAction) })
            app.statusMenu.update()
            #expect(menuItem.title == "Start")
        }

        /// Read with EasyReader on a file in Finder opens it in the reader window and reads it.
        @Test func readServiceReadsFile() async throws {
            _ = await launch()
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReadService-\(UUID().uuidString).txt")
            try longText.write(to: url, atomically: true, encoding: .utf8)
            Teardown.add { try? FileManager.default.removeItem(at: url) }
            let reading = recorder.expect(.reading)
            #expect(ReaderWindow.read(pasteboard { $0.writeObjects([url as NSURL]) }))
            try await reading.wait(timeout: 10)
            let reader = try #require(ReaderWindow.front)
            #expect(reader.textView.string == longText)
            #expect(reader.window.title == url.lastPathComponent)
        }

        /// A window whose text field (an `AXTextField`: nothing readable) has "Beta two. Gamma three." selected.
        private func selectionSource() async throws -> NSWindow {
            Teardown.add { for readerWindow in ReaderWindow.windows { readerWindow.window.close() } }
            let text = "Alpha one. Beta two. Gamma three."
            let field = NSTextField(string: text)
            let source = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
            source.isReleasedWhenClosed = false
            source.title = "Selection Source \(UUID().uuidString)"
            source.contentView = field
            source.makeKeyAndOrderFront(nil)
            source.makeFirstResponder(field)
            Teardown.add { source.close() }
            await settle()
            try #require(field.currentEditor()).selectedRange = (text as NSString).range(of: "Beta two. Gamma three.")
            await settle()
            return source
        }

        /// The Read Selection in Reader shortcut reads the front app's selection in a reader window titled after the app's window.
        @Test func readSelectionShortcutReadsSelectionInReaderWindow() async throws {
            _ = await launch()
            let source = try await selectionSource()
            let reading = recorder.expect(.reading)
            #expect(ReaderWindow.readSelection(of: getpid()))
            try await reading.wait(timeout: 10)
            let reader = try #require(ReaderWindow.front)
            #expect(reader.textView.string == "Beta two. Gamma three.")
            #expect(reader.window.title == source.title)
        }

        /// With `readSelectedTextFallback`, Start in an app with nothing readable reads its selection in a reader window.
        @Test func startInUnsupportedAppReadsSelectionInReaderWindow() async throws {
            let app = await launch()
            Defaults[.readSelectedTextFallback] = true
            let source = try await selectionSource()
            let reading = recorder.expect(.reading)
            #expect(app.easyReader.start(reading: .app(.current)))
            try await reading.wait(timeout: 10)
            let reader = try #require(ReaderWindow.front)
            #expect(reader.textView.string == "Beta two. Gamma three.")
            #expect(reader.window.title == source.title)
        }

        @Test func startInUnsupportedAppFailsWithFallbackOff() async throws {
            let app = await launch()
            Defaults[.readSelectedTextFallback] = false
            _ = try await selectionSource()
            #expect(!app.easyReader.start(reading: .app(.current)))
            #expect(ReaderWindow.windows.allSatisfy { !$0.window.isVisible })
        }

        @Test func readServiceRefusesBlankText() async {
            _ = await launch()
            #expect(!ReaderWindow.read(pasteboard { $0.setString(" \n", forType: .string) }))
        }

        /// The status menu shows the same shortcuts as the File menu (Open…, Open URL…); there's no New Reader Window.
        @Test func statusMenuShortcutsMatchFileMenu() async throws {
            let app = await launch()
            let fileMenu = try #require(NSApp.mainMenu?.items.first { $0.submenu?.items.contains { $0.title == "Open…" } == true }?.submenu)
            fileMenu.delegate?.menuNeedsUpdate?(fileMenu)  // SwiftUI fills its items when the menu opens
            #expect(!fileMenu.items.contains { $0.title.contains("New Reader Window") })
            for title in ["Open…", "Open URL…"] {
                let fileItem = try #require(fileMenu.items.first { $0.title == title })
                let statusItem = try #require(app.statusMenu.items.first { $0.title == title })
                #expect(statusItem.keyEquivalent == fileItem.keyEquivalent, "\(title)")
                #expect(statusItem.keyEquivalentModifierMask == fileItem.keyEquivalentModifierMask, "\(title)")
                #expect(!statusItem.keyEquivalent.isEmpty, "\(title)")
            }
        }

        /// The menu bar icon is a template image that shows the reader's state.
        /// Tests launch many delegates: one torn down stops following the settings.
        @Test func stoppedDelegateIgnoresSettings() async {
            let app = await launch()
            #expect(app.statusItem != nil)
            app.stopObserving()
            Defaults[.appPresence] = .dock
            await settle(0.1)
            Defaults[.appPresence] = .both
            await settle(0.1)
            #expect(app.statusItem == nil)
        }

        @Test func statusItemIconFollowsState() async throws {
            let app = await launch()
            let button = try #require(app.statusItem?.button)
            let reader = try #require(app.easyReader)
            #expect(button.image?.name() == "MenuBarIconIdle")
            #expect(button.image?.isTemplate == true)
            #expect(button.image?.accessibilityDescription == "EasyReader")
            _ = try await startReading(reader)
            app.easyReader(reader, didChangeState: reader.state)  // the recorder replaced the app as delegate
            #expect(button.image?.name() == "MenuBarIcon")
            let paused = recorder.expect(.paused)
            #expect(reader.pause())
            try await paused.wait(timeout: 10)
            app.easyReader(reader, didChangeState: reader.state)
            #expect(button.image?.name() == "MenuBarIconPaused")
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
