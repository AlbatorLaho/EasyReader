import SwiftUI
import Defaults
import KeyboardShortcuts

struct SettingsGeneralView: View {
    @Default(.nowPlayingCenterIntegration) private var nowPlayingCenterIntegration
    @Default(.mediaKeysAfterFinishing) private var mediaKeysAfterFinishing
    @Default(.appPresence) private var appPresence
    @Default(.quitClosesWindows) private var quitClosesWindows

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                Form {
                    KeyboardShortcuts.Recorder("Start/Stop:", name: .toggleStartStop)
                    KeyboardShortcuts.Recorder("Increase Rate:", name: .increaseRate)
                    KeyboardShortcuts.Recorder("Decrease Rate:", name: .decreaseRate)
                    KeyboardShortcuts.Recorder("Default Rate:", name: .defaultRate)

                    GroupBox {
                        Form {
                            KeyboardShortcuts.Recorder("Play/Pause:", name: .togglePlayPause)
                            KeyboardShortcuts.Recorder("Skip Forward:", name: .skipForward)
                            KeyboardShortcuts.Recorder("Skip Backward:", name: .skipBackward)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Redundant with \"Now Playing Center\"")
                            InfoButton(
                                "Media keys already play/pause and skip with Now Playing Center.",
                                title: "Media Keys Cover These",
                                "When \"Now Playing Center\" integration is enabled (below), the keyboard's media keys (▶︎❙❙, ◀︎◀︎, ▶︎▶︎) play/pause and skip backward/forward, so these shortcuts are optional."
                            )
                        }
                    }
                    .padding(.top)
                }
            } label: {
                Label("Global Shortcuts", systemImage: "command")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
                    InfoButton(
                        "Control reading with the media keys and see it in Now Playing.",
                        title: "Now Playing Center",
                        "Lets the keyboard's media keys (and headphone buttons) play/pause and skip while EasyReader reads.",
                        "Also shows what's being read (the app and window) in Control Center's Now Playing, like music."
                    )
                }

                HStack(spacing: 4) {
                    Picker("Media Keys After Finishing:", selection: $mediaKeysAfterFinishing) {
                        Text("Off").tag(NowPlayingManager.AfterFinishing.off)
                        Text("Beep").tag(NowPlayingManager.AfterFinishing.beep)
                        Text("Same Text").tag(NowPlayingManager.AfterFinishing.sameText)
                        Text("Start Reading").tag(NowPlayingManager.AfterFinishing.startReading)
                    }
                    .fixedSize()
                    InfoButton(
                        "Whether the media keys stay with EasyReader once it reaches the end of the text.",
                        title: "Media Keys After Finishing",
                        "Off: the media keys go back to other apps (Music…) when reading reaches the end.",
                        "Otherwise EasyReader stays in Now Playing, paused at the end, until another app plays, you stop reading, or the text's window closes. Play then:",
                        "• Beep: reads what you've selected or switched to since, or beeps if nothing changed.\n• Same Text: reads the finished text again, from your selection in it or from the start.\n• Start Reading: does what Start does: reads the frontmost app, or the same text from the start if nothing changed."
                    )
                }
                .padding(.leading, 20)
                .disabled(!nowPlayingCenterIntegration)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    Picker("Show In:", selection: $appPresence) {
                        Text("Menu Bar").tag(AppDelegate.Presence.menuBar)
                        Text("Dock").tag(AppDelegate.Presence.dock)
                        Text("Both").tag(AppDelegate.Presence.both)
                    }
                    .fixedSize()
                    InfoButton(
                        "Where EasyReader and its controls are.",
                        title: "Show In",
                        "Menu Bar: the menu bar icon holds the controls; EasyReader shows in the Dock only while Settings is open.",
                        "Dock: EasyReader stays in the Dock and ⌘-Tab. Right-click its Dock icon for the controls.",
                        "Opening EasyReader again (Finder, Spotlight, the Dock) opens Settings."
                    )
                }

                HStack(spacing: 4) {
                    Toggle("⌘Q Only Closes Windows", isOn: $quitClosesWindows)
                    InfoButton(
                        "Quitting with windows open closes them instead.",
                        title: "⌘Q Only Closes Windows",
                        "With EasyReader in the menu bar only, ⌘Q (or Quit in its app menu) while Settings is open closes the window and leaves EasyReader running in the menu bar.",
                        "Quit in the menu bar icon's menu always quits."
                    )
                }
                .padding(.leading, 20)
                .disabled(appPresence != .menuBar)
            }

            VStack(alignment: .leading, spacing: 20) {
                ChromiumSelectionInfo()

                HStack {
                    AccessibilityPermissionButton()
                    Spacer()
                    ResetDefaultsButton(for: "general") {
                        KeyboardShortcuts.resetAll()
                        Defaults.reset(.appPresence, .quitClosesWindows, .nowPlayingCenterIntegration, .mediaKeysAfterFinishing)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }

        TextPlayground("General Playground") {
            """
            Welcome to \(NSRunningApplication.current.localizedName!)!
            A text-to-speech menu bar app that selects each sentence as it reads.

            Key features:
            • selects text as it's reading
            • modify selection while reading, to change what will be read next
            • resumes from the word it was paused at
            • can scroll the selection into view while reading
            • can integrate with the "Now Playing Center" and media keys

            Reads:
            • text views (like this one)
            • web pages
            • PDFs
            • books in Apple Books
            • the selected text in unsupported apps (if turned on in Reading settings)

            Behavior:
            • starts reading from your current selection, or from the cursor/top of the page if there is none
            • reading continues from the end of the selection, until the end of the text
            • if you select something else while reading, reading continues from there
            • Start/Stop reads from the focused app, Play/Pause and skipping only work while reading (or paused)

            Caveats/Bugs:
            • some UI elements don't look/behave correctly prior to MacOS 13
            """
        }
    }
}

private struct AccessibilityPermissionButton: View {
    @State private var isTrusted = AXElement.isProcessTrusted()
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        Button {
            if isTrusted {
                // Undocumented URL, still mapped by System Settings on macOS 13+.
                if !NSWorkspace.shared.open(Self.settingsURL) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
                }
            } else {
                // The system prompt also adds the app to the Accessibility list.
                isTrusted = AXElement.isProcessTrusted(prompt: true)
            }
        } label: {
            if #available(macOS 12.0, *) {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(isTrusted ? .green : .red)
            } else {
                Image(systemName: "circle.fill")
                    .imageScale(.small)
                    .foregroundColor(isTrusted ? .green : .red)
            }
            Text(isTrusted ? "Accessibility Settings…" : "Request Accessibility Permission…")
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))) { _ in
            // Posted before the trust check catches up.
            Task {
                try? await Task.sleep(seconds: 0.5)
                refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        isTrusted = AXElement.isProcessTrusted()
    }
}
