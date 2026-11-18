import SwiftUI
import Defaults
import KeyboardShortcuts
import LaunchAtLogin

struct SettingsGeneralView: View {
    @Default(.nowPlayingCenterIntegration) private var nowPlayingCenterIntegration
    @Default(.playWhenFinished) private var playWhenFinished
    @Default(.appPresence) private var appPresence
    @Default(.quitClosesWindows) private var quitClosesWindows
    @Default(.readerOpensNewWindows) private var readerOpensNewWindows
    @Default(.readerDarkBackground) private var readerDarkBackground
    @Default(.readSelectedTextFallback) private var readSelectedTextFallback

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        Form {
                            HStack(spacing: 4) {
                                LaunchAtLogin.Toggle("Launch at login")
                                InfoButton(
                                    "Start EasyReader when you log in.",
                                    title: "Launch at Login",
                                    "EasyReader starts in the background when you log in, ready for its shortcuts and media keys.",
                                    "You can also turn this off in System Settings → General → Login Items."
                                )
                            }

                            HStack(spacing: 4) {
                                Picker("Show in:", selection: $appPresence) {
                                    Text("Menu bar").tag(AppDelegate.Presence.menuBar)
                                    Text("Dock").tag(AppDelegate.Presence.dock)
                                    Text("Both").tag(AppDelegate.Presence.both)
                                }
                                .fixedSize()
                                InfoButton(
                                    "Where EasyReader and its controls live.",
                                    title: "Show In",
                                    "Menu bar: the menu bar icon has the controls. EasyReader shows in the Dock only while one of its windows is open.",
                                    "Dock: EasyReader stays in the Dock and ⌘-Tab. Right-click its Dock icon for the controls.",
                                    "Opening EasyReader again (Finder, Spotlight, the Dock) opens Settings."
                                )
                            }

                            HStack(spacing: 4) {
                                Toggle("Keep in menu bar on ⌘Q", isOn: $quitClosesWindows)
                                InfoButton(
                                    "⌘Q closes EasyReader's windows instead of quitting.",
                                    title: "Keep in Menu Bar on ⌘Q",
                                    "When EasyReader is only in the menu bar, ⌘Q (or Quit in its app menu) closes its windows and leaves it running in the menu bar.",
                                    "Quit in the menu bar icon's menu always quits."
                                )
                            }
                            .disabled(appPresence != .menuBar)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("App", systemImage: "menubar.rectangle")
                    }

                    GroupBox {
                        Form {
                            HStack(spacing: 4) {
                                Toggle("Open each document in a new window", isOn: $readerOpensNewWindows)
                                InfoButton(
                                    "Each file or web page gets a window of its own.",
                                    title: "Reader Windows",
                                    "The Reader window (menu bar icon → Open… or Open URL…) shows files, web pages and text you send it, and reads them like any other app.",
                                    "On: each file or page opens in a new window (or the front one, if it's empty).",
                                    "Off: there's one Reader window, and opening something replaces its text."
                                )
                            }

                            HStack(spacing: 4) {
                                Toggle("Show documents in Dark Mode", isOn: $readerDarkBackground)
                                InfoButton(
                                    "When your Mac is in Dark Mode, show documents light on dark.",
                                    title: "Show Documents in Dark Mode",
                                    "On: when your Mac is in Dark Mode, the Reader window is dark too, and the document's colors are adjusted to stay readable (black text turns light), like TextEdit's \"Use Dark Background for Windows\".",
                                    "Off: documents always show light, the way they'd print."
                                )
                            }

                            HStack(spacing: 4) {
                                Toggle("Open selection for unsupported apps", isOn: $readSelectedTextFallback)
                                InfoButton(
                                    "In apps EasyReader can't read, Start reads your selection in a Reader window.",
                                    title: "Unsupported Apps",
                                    "EasyReader reads text views, web pages, PDFs and Apple Books in place, selecting each sentence as it reads.",
                                    "Other apps usually can't be read because they share little or nothing with accessibility.",
                                    "With this on, Start in those apps opens the text you selected in a Reader window and reads it there, like the open selection shortcut.",
                                    "If the app doesn't share its selection with accessibility, EasyReader copies it (⌘C), then puts your clipboard back. Clipboard history apps may still catch the copy."
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Reader Window", systemImage: "doc.richtext")
                    }

                    GroupBox {
                        Form {
                            HStack(spacing: 4) {
                                Picker("When finished, play key:", selection: $playWhenFinished) {
                                    Text("Does nothing").tag(NowPlayingManager.PlayWhenFinished.off)
                                    Text("Rereads same text").tag(NowPlayingManager.PlayWhenFinished.sameText)
                                    Text("Reads from same app").tag(NowPlayingManager.PlayWhenFinished.sameApp)
                                    Text("Reads from any app").tag(NowPlayingManager.PlayWhenFinished.anyText)
                                }
                                .fixedSize()
                                InfoButton(
                                    "What the play key (and the play/pause shortcut) reads once reading reaches the end.",
                                    title: "When Finished, Play Key",
                                    "Does nothing: the media keys go back to other apps (Music…).",
                                    "Otherwise EasyReader stays in Now Playing, paused at the end, until another app plays, you stop reading, or the text's window closes. Play then:",
                                    "• Rereads same text: what it just finished, from the start, whatever you've selected or switched to since.\n• Reads from same app: if that app is in front, your new selection there, or the same text from the start. If another app is in front, it beeps instead of guessing.\n• Reads from any app: same as Start, in whatever app is in front."
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!nowPlayingCenterIntegration)
                    } label: {
                        HStack(spacing: 4) {
                            Toggle("Use media keys and Now Playing", isOn: $nowPlayingCenterIntegration)
                            InfoButton(
                                "Control reading with the media keys and see it in Now Playing.",
                                title: "Media Keys and Now Playing",
                                "The keyboard's media keys (and headphone buttons) play/pause and skip while EasyReader reads.",
                                "What's being read (the app and window) also shows in Control Center's Now Playing, like music."
                            )
                        }
                    }
                }

                shortcuts.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                AccessibilityStatus()
                ChromiumSelectionInfo()
            }

            SettingsFooter {
                ResetDefaultsButton(
                    for: "general",
                    keys: [
                        .appPresence, .quitClosesWindows, .readerOpensNewWindows, .readerDarkBackground, .readSelectedTextFallback,
                        .nowPlayingCenterIntegration, .playWhenFinished,
                    ])
            }
        }
    }

    private var shortcuts: some View {
        GroupBox {
            Form {
                KeyboardShortcuts.Recorder("Start/stop:", name: .toggleStartStop)
                KeyboardShortcuts.Recorder("Faster:", name: .increaseRate)
                KeyboardShortcuts.Recorder("Slower:", name: .decreaseRate)
                KeyboardShortcuts.Recorder("Normal speed:", name: .defaultRate)
                HStack(spacing: 4) {
                    KeyboardShortcuts.Recorder("Open selection:", name: .readSelectionInReaderWindow)
                    InfoButton(
                        "Read the selected text of any app in a Reader window.",
                        title: "Open Selection",
                        "Like Services → \"Read with EasyReader\", but it works in any app and you pick the shortcut.",
                        "It gets the app's selection through accessibility, or by copying it (⌘C) when the app doesn't share it, then puts your clipboard back. Clipboard history apps may still catch the copy.",
                        "The text opens in a Reader window and is read from the start. Formatting isn't kept."
                    )
                }

                GroupBox {
                    Form {
                        KeyboardShortcuts.Recorder("Play/pause:", name: .togglePlayPause)
                        KeyboardShortcuts.Recorder("Skip forward:", name: .skipForward)
                        KeyboardShortcuts.Recorder("Skip back:", name: .skipBackward)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Optional with media keys")
                        InfoButton(
                            "With media keys on, you may not need these.",
                            title: "Optional with Media Keys",
                            "When \"Use media keys and Now Playing\" is on, the keyboard's media keys (▶︎❙❙, ◀︎◀︎, ▶︎▶︎) play/pause and skip, so these shortcuts are optional.",
                            "They work the same as the media keys: holding a skip shortcut keeps skipping, and play/pause follows \"When finished, play key\"."
                        )
                    }
                }
                .padding(.top, 8)
            }
        } label: {
            Label("Global Shortcuts", systemImage: "command")
        }
    }
}

struct AccessibilityStatus: View {
    @State private var isTrusted = AXElement.isProcessTrusted()

    var body: some View {
        HStack {
            Image(systemName: isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isTrusted ? .green : .orange)
            Text(isTrusted ? "Accessibility access is on." : "EasyReader needs Accessibility access to read other apps.")
            if !isTrusted {
                Spacer()
                // The system prompt also adds the app to the Accessibility list.
                Button("Allow Access…") { isTrusted = AXElement.isProcessTrusted(prompt: true) }
            }
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
