import AppKit
import SwiftUI
import Defaults
import LaunchAtLogin

/// Shown at launch the first time, and again while Accessibility access is missing.
@MainActor
enum SetupGuide {
    nonisolated static let windowID = "SetupGuide"
    private static var window: NSWindow?

    static var isNeeded: Bool {
        !UserDefaults.isUnderTest && (!Defaults[.hasShownSetupGuide] || !AXElement.isProcessTrusted())
    }

    static func showIfNeeded() {
        if isNeeded { show() }
    }

    static func show() {
        Defaults[.hasShownSetupGuide] = true
        if window == nil {
            let controller = NSHostingController(rootView: SetupGuideView { close() })
            let window = NSWindow(contentViewController: controller)
            window.identifier = NSUserInterfaceItemIdentifier(windowID)
            window.title = "Set Up EasyReader"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Sized before centering: SwiftUI sizes it later, growing it from the centered origin.
            window.setContentSize(controller.view.fittingSize)
            window.center()
            self.window = window
        }
        if let window { SettingsOpener.present(window) }
    }

    private static func close() {
        window?.close()
    }
}

private struct SetupGuideView: View {
    let done: () -> Void
    @Default(.appPresence) private var appPresence

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to EasyReader").font(.title)
                Text("EasyReader reads text from other apps aloud, selecting each sentence as it goes.")
                    .foregroundColor(.secondary)
            }

            step(1, "Allow Accessibility access") {
                AccessibilityStatus()
            }

            step(2, "Choose how EasyReader runs") {
                LaunchAtLogin.Toggle("Launch at login")
                Picker("Show EasyReader in:", selection: $appPresence) {
                    Text("Menu bar").tag(AppDelegate.Presence.menuBar)
                    Text("Dock").tag(AppDelegate.Presence.dock)
                    Text("Both").tag(AppDelegate.Presence.both)
                }
                .fixedSize()
                Text(presenceNote).foregroundColor(.secondary)
            }

            step(3, "Using a Chromium browser? (optional)") {
                ChromiumSelectionInfo()
            }

            step(4, "Try it") {
                HStack {
                    Button("Read Sample Text") { ReaderWindow.openSample(reading: true) }
                    Text("Then try Start in any app, from the \(appPresence == .dock ? "Dock icon's menu" : "menu bar icon").")
                        .foregroundColor(.secondary)
                }
            }

            step(5, "Make it yours") {
                HStack {
                    Button("Open \(SettingsOpener.menuTitle)") { SettingsOpener.open() }
                    Text("Pick a voice, fix pronunciations, and set up shortcuts.").foregroundColor(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var presenceNote: String {
        switch appPresence {
            case .menuBar: "The menu bar icon has the controls. Open EasyReader again to get to \(SettingsOpener.name)."
            case .dock: "Right-click the Dock icon for the controls."
            case .both: "Use the menu bar icon or right-click the Dock icon for the controls."
        }
    }

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}
