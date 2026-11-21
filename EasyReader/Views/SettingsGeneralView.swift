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

    private static var loginItemsPath: String {
        if #available(macOS 13.0, *) { "System Settings → General → Login Items" } else { "System Preferences → Users & Groups → Login Items" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    FormBox {
                        LaunchAtLogin.Toggle("Launch at login")
                            .info(
                                "Start EasyReader when you log in.",
                                "EasyReader starts in the background when you log in, ready for its shortcuts and media keys.",
                                "You can also turn this off in \(Self.loginItemsPath)."
                            )

                        AppPresencePicker("Show in:", selection: $appPresence)
                            .info(
                                "Where EasyReader and its controls live.",
                                "Menu bar: the menu bar icon has the controls. EasyReader shows in the Dock only while one of its windows is open.",
                                "Dock: EasyReader stays in the Dock and ⌘-Tab. Right-click its Dock icon for the controls.",
                                "Both: the menu bar icon and the Dock icon, as above.",
                                "Opening EasyReader again (Finder, Spotlight, the Dock) opens Settings."
                            )

                        Toggle("Keep in menu bar on ⌘Q", isOn: $quitClosesWindows)
                            .info(
                                "⌘Q closes EasyReader's windows instead of quitting.",
                                "When EasyReader is only in the menu bar, ⌘Q (or Quit in its app menu) closes its windows and leaves it running in the menu bar.",
                                "Quit in the menu bar icon's menu always quits."
                            )
                            .disabled(appPresence != .menuBar)
                    } label: {
                        Label("App", systemImage: "menubar.rectangle")
                    }

                    FormBox {
                        Toggle("Open each document in a new window", isOn: $readerOpensNewWindows)
                            .info(
                                "Each file or web page gets a window of its own.",
                                "The Reader window (Open… ⌘O or Open URL… ⌘L, in the menu bar icon's menu or EasyReader's File menu) shows files, web pages and text you send it, and reads them like any other app.",
                                "On: each file or page opens in a new window (or the front one, if it's empty).",
                                "Off: there's one Reader window, and opening something replaces its text."
                            )

                        Toggle("Show documents in Dark Mode", isOn: $readerDarkBackground)
                            .info(
                                "When your Mac is in Dark Mode, show documents light on dark.",
                                "On: when your Mac is in Dark Mode, the Reader window is dark too, and the document's colors are adjusted to stay readable (black text turns light), like TextEdit's \"Use Dark Background for Windows\".",
                                "Off: documents always show light, the way they'd print."
                            )

                        Toggle("Open selection for unsupported apps", isOn: $readSelectedTextFallback)
                            .info(
                                "In apps EasyReader can't read, Start reads your selection in a Reader window.",
                                "EasyReader reads text views, web pages, PDFs and Apple Books in place, selecting each sentence as it reads.",
                                "Other apps usually can't be read because they share little or nothing with accessibility.",
                                "With this on, Start in those apps opens the text you selected in a Reader window and reads it there, like the open selection shortcut.",
                                "If the app doesn't share its selection with accessibility, EasyReader copies it (⌘C), then puts your clipboard back. Clipboard history apps may still catch the copy."
                            )
                    } label: {
                        Label("Reader Window", systemImage: "doc.richtext")
                    }

                    FormBox {
                        Picker("When finished, play key:", selection: $playWhenFinished) {
                            Text("Does nothing").tag(NowPlayingManager.PlayWhenFinished.off)
                            Text("Rereads same text").tag(NowPlayingManager.PlayWhenFinished.sameText)
                            Text("Reads from same app").tag(NowPlayingManager.PlayWhenFinished.sameApp)
                            Text("Reads from any app").tag(NowPlayingManager.PlayWhenFinished.anyText)
                        }
                        .fixedSize()
                        .info(
                            "What the play key (and the play/pause shortcut) reads once reading reaches the end.",
                            "Does nothing: the media keys go back to other apps (Music…).",
                            "Otherwise EasyReader stays in Now Playing, paused at the end, until another app plays, you stop reading, or the text's window closes. Play then:",
                            "• Rereads same text: what it just finished, from the start, whatever you've selected or switched to since.\n• Reads from same app: if that app is in front, your new selection there, or the same text from the start. If another app is in front, it beeps instead of guessing.\n• Reads from any app: same as Start, in whatever app is in front."
                        )
                        .disabled(!nowPlayingCenterIntegration)
                    } label: {
                        Toggle("Use media keys and Now Playing", isOn: $nowPlayingCenterIntegration)
                            .info(
                                "Control reading with the media keys and see it in Now Playing.",
                                "The keyboard's media keys (and headphone buttons) play/pause and skip while EasyReader reads.",
                                "What's being read (the app and window) also shows in Control Center's Now Playing, like music."
                            )
                    }
                }

                shortcuts.fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 12) {
                AccessibilityStatus()
                ChromiumSelectionInfo()
            }

            SettingsFooter {
                ResetDefaultsButton(for: "general", keys: Defaults.Keys.generalTab)
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
                KeyboardShortcuts.Recorder("Open selection:", name: .readSelectionInReaderWindow)
                    .info(
                        "Read the selected text of any app in a Reader window.",
                        "Like Services → \"Read with EasyReader\", but it works in any app and you pick the shortcut.",
                        "It gets the app's selection through accessibility, or by copying it (⌘C) when the app doesn't share it, then puts your clipboard back. Clipboard history apps may still catch the copy.",
                        "The text opens in a Reader window and is read from the start. Formatting isn't kept."
                    )

                GroupBox {
                    Form {
                        KeyboardShortcuts.Recorder("Play/pause:", name: .togglePlayPause)
                        KeyboardShortcuts.Recorder("Skip forward:", name: .skipForward)
                        KeyboardShortcuts.Recorder("Skip backward:", name: .skipBackward)
                    }
                } label: {
                    Text("Optional with media keys")
                        .info(
                            "With media keys on, you may not need these.",
                            "When \"Use media keys and Now Playing\" is on, the keyboard's media keys (▶︎❙❙, ◀︎◀︎, ▶︎▶︎) play/pause and skip, so these shortcuts are optional.",
                            "They work the same as the media keys: holding a skip shortcut keeps skipping, and play/pause follows \"When finished, play key\"."
                        )
                }
                .padding(.top, 8)
            }
        } label: {
            Label("Global Shortcuts", systemImage: "command")
        }
    }
}

/// Form rows in a group box as wide as its column.
private struct FormBox<Content: View, BoxLabel: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let label: BoxLabel

    var body: some View {
        GroupBox {
            Form { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            label
        }
    }
}

struct AppPresencePicker: View {
    private let title: LocalizedStringKey
    @Binding private var selection: AppDelegate.Presence

    init(_ title: LocalizedStringKey, selection: Binding<AppDelegate.Presence>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Menu bar").tag(AppDelegate.Presence.menuBar)
            Text("Dock").tag(AppDelegate.Presence.dock)
            Text("Both").tag(AppDelegate.Presence.both)
        }
        .fixedSize()
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
