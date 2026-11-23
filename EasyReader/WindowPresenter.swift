import AppKit
import Defaults

/// Shows the app's windows as a regular app (Dock icon, ⌘-Tab) and returns to the resting policy once the last one closes.
@MainActor
enum WindowPresenter {
    /// The policy while none of the app's windows is open.
    static var restingPolicy: NSApplication.ActivationPolicy {
        Defaults[.appPresence] == .menuBar ? .accessory : .regular
    }

    /// Windows that keep the Dock icon while open: Settings, Reader windows, the setup guide; not alerts, open panels or About.
    private static func isPresented(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && isPresented($0) }
    }

    private static var closeObserver: NSObjectProtocol?

    /// Shows one of the app's windows; `then` runs once it's key (or after 1 s).
    static func present(_ window: NSWindow, then action: (@MainActor () -> Void)? = nil) {
        showAsRegular()
        window.makeKeyAndOrderFront(nil)
        Task {
            await activateAfterPolicyChange { window }
            for _ in 0..<18 where !window.isKeyWindow {
                try? await Task.sleep(seconds: 0.05)
            }
            action?()
        }
    }

    // A Dock icon while open, so the window can be found with ⌘-Tab and the Dock.
    static func showAsRegular() {
        NSApp.setActivationPolicy(.regular)
        observeClose()
        // Closing the window hid an accessory app, and a hidden app's windows stay hidden.
        NSApp.unhide(nil)
    }

    // Activated before the policy change lands, the app isn't put first in ⌘-Tab.
    static func activateAfterPolicyChange(_ window: () -> NSWindow?) async {
        try? await Task.sleep(seconds: 0.1)
        NSApp.activate(ignoringOtherApps: true)
        window()?.makeKeyAndOrderFront(nil)
    }

    private static func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            nonisolated(unsafe) let window = notification.object
            MainActor.assumeIsolated {
                guard let window = window as? NSWindow, isPresented(window) else { return }
                // Still visible while it closes.
                guard !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && isPresented($0) })
                else { return }
                didClose()
            }
        }
    }

    static func applyRestingPolicy() {
        guard !hasOpenWindow else { return }
        NSApp.setActivationPolicy(restingPolicy)
    }

    private static func didClose() {
        guard NSApp.activationPolicy() != restingPolicy else { return }
        NSApp.setActivationPolicy(restingPolicy)
        // Hands focus back to the app the user came from instead of leaving no app frontmost.
        if restingPolicy == .accessory { NSApp.hide(nil) }
    }
}
