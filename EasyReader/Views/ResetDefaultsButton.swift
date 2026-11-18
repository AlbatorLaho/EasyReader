import SwiftUI
import Defaults
import KeyboardShortcuts

/// A tab's reset button; holding ⌥ turns it into "Reset All Settings…".
struct ResetDefaultsButton: View {
    private let title: String
    private let confirmation: Confirmation
    private let isEnabled: Bool
    @ObservedObject private var optionKey = OptionKey.shared

    init(_ title: String, confirmation: Confirmation, isEnabled: Bool = true) {
        self.title = title
        self.confirmation = confirmation
        self.isEnabled = isEnabled
    }

    init(for name: String, action: @escaping @MainActor () -> Void) {
        self.init(
            "Reset \(name.capitalized)…",
            confirmation: Confirmation(
                title: "Reset \(name) settings?",
                message: "The \(name) settings go back to their defaults.",
                button: "Reset",
                action: action))
    }

    init(for name: String, keys: [Defaults.Keys]) {
        self.init(for: name, action: { Defaults.reset(keys) })
    }

    var body: some View {
        button
            .disabled(!isEnabled && !optionKey.isDown)
            .help("Hold ⌥ to reset all settings.")
    }

    @ViewBuilder private var button: some View {
        if #available(macOS 12.0, *) {
            Button(role: .destructive, action: confirm) { label }
        } else {
            Button(action: confirm) { label }
        }
    }

    @ViewBuilder private var label: some View {
        if optionKey.isDown {
            Label("Reset All Settings…", systemImage: "exclamationmark.triangle.fill")
        } else {
            Text(title)
        }
    }

    private func confirm() {
        (NSEvent.modifierFlags.contains(.option) ? .resetAll : confirmation).ask()
    }

    struct Confirmation {
        let title: String
        let message: String
        let button: String
        let action: @MainActor () -> Void

        static var resetAll: Confirmation {
            Confirmation(
                title: "Reset all settings?",
                message: "Every setting and shortcut goes back to its default, and all pronunciations are deleted.",
                button: "Reset All",
                action: {
                    KeyboardShortcuts.resetAll()
                    Defaults.removeAll(suite: .app)
                })
        }

        // `NSAlert`: SwiftUI's alert can't put the keyboard focus on Cancel.
        @MainActor func ask() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: button).hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: "Cancel")
            alert.layout()
            alert.window.initialFirstResponder = cancel
            let action = action
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { action() }
                }
                alert.window.makeFirstResponder(cancel)
            } else if alert.runModal() == .alertFirstButtonReturn {
                action()
            }
        }
    }
}

@MainActor private final class OptionKey: ObservableObject {
    static let shared = OptionKey()
    @Published private(set) var isDown = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let isDown = event.modifierFlags.contains(.option)
            MainActor.assumeIsolated { self?.isDown = isDown }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDown = NSEvent.modifierFlags.contains(.option) }
        }
    }
}
