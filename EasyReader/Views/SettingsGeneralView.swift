import SwiftUI
import Defaults
import KeyboardShortcuts

struct SettingsGeneralView: View {
    @Default(.nowPlayingCenterIntegration) private var nowPlayingCenterIntegration

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
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
                            Text("Not needed with \"Now Playing Center\"")
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

            HStack(spacing: 4) {
                Toggle("\"Now Playing Center\" integration", systemImage: "play.circle", isOn: $nowPlayingCenterIntegration)
                InfoButton(
                    "Control reading with the media keys and see it in Now Playing.",
                    title: "Now Playing Center",
                    "Lets the keyboard's media keys (and headphone buttons) play/pause and skip while EasyReader reads.",
                    "Also shows what's being read (the app and window) in Control Center's Now Playing, like music."
                )
            }

            Spacer()

            ChromiumSelectionInfo()

            HStack {
                AccessibilityPermissionButton()
                Spacer()
                ResetDefaultsButton(for: "all") {
                    KeyboardShortcuts.resetAll()
                    Defaults.removeAll()
                } label: {
                    Label("Reset all settings…", systemImage: "exclamationmark.triangle.fill")
                }
            }
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
