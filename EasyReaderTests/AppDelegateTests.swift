import AVFoundation
import AppKit
import Defaults
import KeyboardShortcuts
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
            // The loops start in order; the Now Playing one acting on its initial value means all have subscribed.
            try? await waitUntil(timeout: 2, "settings loops") { app.nowPlayingManager.isEnabled }
            await settle(0.05)
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
            try await waitUntil(timeout: 5, "Settings window") { SettingsOpener.window?.isVisible == true }
            let settings = try #require(SettingsOpener.window)
            #expect(settings.isVisible)
            #expect(SettingsOpener.reportedWindow === settings, "found without SwiftUI's identifier (macOS 12 has another)")
            let other = makeTestWindow(frame: NSRect(x: 100, y: 100, width: 300, height: 200))
            try? await waitUntil(timeout: 2) { !settings.isKeyWindow }
            #expect(!settings.isKeyWindow)
            menu.performActionForItem(at: index)
            try? await waitUntil(timeout: 3) { NSApp.isActive && settings.isKeyWindow && NSApp.orderedWindows.first == settings }
            #expect(NSApp.isActive)
            #expect(settings.isKeyWindow)
            #expect(NSApp.orderedWindows.first == settings)
        }

        private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
            let pasteboard = uniquePasteboard()
            write(pasteboard)
            return pasteboard
        }

        /// Read with EasyReader (or a menu bar icon drop) reads the text in the reader window; the controls tell Start and Resume apart.
        @Test func readServiceReadsTextInReaderWindow() async throws {
            let app = await launch()
            Teardown.add { closeReaderWindows() }
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

        @Test func readServiceReadsFile() async throws {
            _ = await launch()
            Teardown.add { closeReaderWindows() }
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
            Teardown.add { closeReaderWindows() }
            let text = "Alpha one. Beta two. Gamma three."
            let field = NSTextField(string: text)
            let source = makeTestWindow(field, title: "Selection Source", frame: NSRect(x: 200, y: 200, width: 400, height: 60))
            source.makeFirstResponder(field)
            await settle()
            try #require(field.currentEditor()).selectedRange = (text as NSString).range(of: "Beta two. Gamma three.")
            await settle()
            return source
        }

        /// The Open Selection shortcut reads the front app's selection in a reader window titled after the app's window.
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

        /// ⌘Q with windows open only closes them in menu bar mode (unless turned off); in the Dock it quits.
        @Test(
            arguments: [
                (AppDelegate.Presence.menuBar, true, false), (.menuBar, false, true), (.both, true, true), (.dock, true, true),
            ] as [(AppDelegate.Presence, Bool, Bool)])
        func quitWithWindowsOpen(presence: AppDelegate.Presence, closesWindows: Bool, quits: Bool) {
            Defaults[.appPresence] = presence
            Defaults[.quitClosesWindows] = closesWindows
            let window = makeTestWindow()
            #expect(AppDelegate().applicationShouldTerminate(NSApp) == (quits ? .terminateNow : .terminateCancel))
            #expect(window.isVisible == quits)
        }

        @Test func quitWithoutWindowsQuits() {
            Defaults[.appPresence] = .menuBar
            for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) { window.close() }
            #expect(AppDelegate().applicationShouldTerminate(NSApp) == .terminateNow)
        }

        @Test func reopenWithoutWindowsOpensSettings() async throws {
            Teardown.add { SettingsOpener.window?.close() }
            #expect(AppDelegate().applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            #expect(!AppDelegate().applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
            try await waitUntil(timeout: 5, "Settings window") { SettingsOpener.window?.isVisible == true }
        }

        /// A recorder focused by the window, not a click or Tab (Settings opening on macOS 12), doesn't keep the focus and record.
        @Test func recorderFocusedWithoutClickOrTabIsUnfocused() async throws {
            Teardown.add { SettingsOpener.window?.close() }
            SettingsOpener.open()
            try await waitUntil(timeout: 5, "Settings window") { SettingsOpener.window?.isVisible == true }
            let settings = try #require(SettingsOpener.window)
            try await waitUntil(timeout: 2, "key") { settings.isKeyWindow }
            let recorder = try #require(firstSubview(KeyboardShortcuts.RecorderCocoa.self, in: settings.contentView))
            #expect(settings.makeFirstResponder(recorder))
            try await waitUntil(timeout: 2, "recorder unfocused") { (settings.firstResponder as? NSText)?.delegate !== recorder }
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

        /// Tests launch many delegates: one torn down stops following the settings.
        @Test func stoppedDelegateIgnoresSettings() async {
            let app = await launch()
            #expect(app.statusItem != nil)
            app.stopObserving()
            Defaults[.appPresence] = .dock
            await settle(0.1)
            Defaults[.appPresence] = .both
            await settle(0.1)  // a live loop would have recreated the item by now
            #expect(app.statusItem == nil)
        }

        /// The menu bar icon is a template image that shows the reader's state.
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
            _ = try await startReading(app.easyReader)
            let restarted = recorder.expectUtteranceStart()
            Defaults[.speechPitch] = 1.2
            try await restarted.wait(timeout: 5)
        }

        /// A change while not reading must not end the speech-settings loop.
        @Test func speechSettingChangeWhileStoppedStillRestartsLater() async throws {
            let app = await launch()
            Defaults[.speechPitch] = 1.1  // while stopped
            await settle(0.3)  // the loop sees it
            _ = try await startReading(app.easyReader)
            let restarted = recorder.expectUtteranceStart()
            Defaults[.speechPitch] = 1.2
            try await restarted.wait(timeout: 5)
        }

        @Test func speedSettingChangeEndsTemporaryRate() async throws {
            let app = await launch()
            let reader: EasyReader = app.easyReader
            _ = try await startReading(reader)
            let restarted = recorder.expectUtteranceStart()
            reader.changeRate(to: AVSpeechUtteranceDefaultSpeechRate)
            try await restarted.wait(timeout: 5)
            #expect(reader.currentUtterance?.rate == AVSpeechUtteranceDefaultSpeechRate)
            #expect(Defaults[.speechRate] == AVSpeechUtteranceMaximumSpeechRate, "setting unchanged")

            let restartedAgain = recorder.expectUtteranceStart()
            Defaults[.speechRate] = 0.9
            try await restartedAgain.wait(timeout: 5)
            #expect(reader.temporaryRate == nil)
            #expect(reader.currentUtterance?.rate == 0.9)
        }

        @Test func changingRateToSettingLeavesNoTemporaryRate() async {
            let app = await launch()
            let reader: EasyReader = app.easyReader
            reader.changeRate(to: AVSpeechUtteranceDefaultSpeechRate)
            #expect(reader.temporaryRate == AVSpeechUtteranceDefaultSpeechRate)
            reader.changeRate(to: nil)
            #expect(reader.temporaryRate == nil)
            #expect(reader.rate == Defaults[.speechRate])
            reader.changeRate(to: Defaults[.speechRate])
            #expect(reader.temporaryRate == nil)
        }
    }
}
