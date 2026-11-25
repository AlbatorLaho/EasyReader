import AppKit
import Defaults
import Testing

@testable import EasyReader

extension IntegrationTests {
    /// Open URL… (and Open…, through the same `WindowPresenter.runModal`) run without a Dock icon, so the dialog must stay findable.
    @MainActor
    struct OpenDialogTests {
        @MainActor private final class Steps {
            var step = 0
            var stepStart = Date()
            var dialog: NSWindow?
            var shownLevel: NSWindow.Level?
            var allSpaces = false
            var visibleAfterSwitch = false
            var levelAfterSwitch: NSWindow.Level?
            var sameDialogAgain = false
            var activeAgain = false
            var keyAgain = false
        }

        /// Shown above other apps' windows on every Space, still there after switching away, and Open URL… again brings it back.
        @Test(arguments: [AppDelegate.Presence.menuBar, .both])
        func openURLDialogStaysFindable(presence: AppDelegate.Presence) async throws {
            Defaults[.appPresence] = presence
            NSApp.setActivationPolicy(presence == .menuBar ? .accessory : .regular)
            let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
            Teardown.add { NSApp.unhide(nil) }
            func switchAway() {
                finder.activate()
                NSApp.deactivate()
            }
            switchAway()
            try await waitUntil(timeout: 3, "app inactive") { !NSApp.isActive }
            let s = Steps()
            // runModal blocks this task; a timer in the modal run loop drives the dialog.
            let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
                nonisolated(unsafe) let timer = timer
                MainActor.assumeIsolated {
                    guard let modal = NSApp.modalWindow else { return }
                    let elapsed = -s.stepStart.timeIntervalSinceNow
                    switch s.step {
                        case 0 where elapsed > 0.5:
                            s.dialog = modal
                            s.shownLevel = modal.level
                            s.allSpaces = modal.collectionBehavior.contains(.canJoinAllSpaces)
                            switchAway()
                            (s.step, s.stepStart) = (1, Date())
                        case 1 where elapsed > 0.5:
                            s.visibleAfterSwitch = modal.isVisible
                            s.levelAfterSwitch = modal.level
                            ReaderWindow.openWebPage()
                            (s.step, s.stepStart) = (2, Date())
                        case 2 where (NSApp.isActive && modal.isKeyWindow) || elapsed > 2:
                            s.sameDialogAgain = modal === s.dialog
                            s.activeAgain = NSApp.isActive
                            s.keyAgain = modal.isKeyWindow
                            timer.invalidate()
                            NSApp.stopModal(withCode: .alertSecondButtonReturn)
                        default: break
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            Teardown.add { timer.invalidate() }
            ReaderWindow.openWebPage()
            #expect(s.step == 2)
            #expect(s.shownLevel == .modalPanel)
            #expect(s.allSpaces)
            #expect(s.visibleAfterSwitch)
            #expect(s.levelAfterSwitch == .modalPanel)
            #expect(s.sameDialogAgain, "brings the open dialog back instead of opening another")
            #expect(s.activeAgain)
            #expect(s.keyAgain)
            if presence == .menuBar {
                // Cancelled with no window open: focus goes back instead of staying with a windowless app.
                try await waitUntil(timeout: 2, "focus handed back") { !NSApp.isActive }
            }
        }
    }
}
