import AppKit
import KeyboardShortcuts

/// Tab skips shortcut recorders (else it went recorder to recorder, never leaving them); a clicked one keeps Tab until Esc or a click elsewhere.
@MainActor
enum RecorderKeyboardFocus {
    private static var observer: NSObjectProtocol?
    private static var monitor: Any?
    private static weak var activeRecorder: KeyboardShortcuts.RecorderCocoa?
    // A recorder that Tab just ended (its own monitor ran before ours), to give the focus back.
    private static var endedByTab: (recorder: KeyboardShortcuts.RecorderCocoa, event: NSEvent)?
    private static var isRefocusing = false

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"), object: nil, queue: .main
        ) { notification in
            let isActive = notification.userInfo?["isActive"] as? Bool == true
            MainActor.assumeIsolated { isActive ? didBecomeActive() : didEnd() }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { keepsTab(event) } ? nil : event
        }
    }

    /// Swallows Tab while a recorder records, whichever monitor runs first.
    private static func keepsTab(_ event: NSEvent) -> Bool {
        guard isTab(event) else { return false }
        if recordingRecorder(in: NSApp.keyWindow) != nil { return true }
        guard let ended = endedByTab, ended.event.timestamp == event.timestamp else { return false }
        endedByTab = nil
        isRefocusing = true
        ended.recorder.window?.makeFirstResponder(ended.recorder)
        isRefocusing = false
        return true
    }

    private static func isTab(_ event: NSEvent) -> Bool {
        event.type == .keyDown && (event.specialKey == .tab || event.specialKey == .backTab)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .function]).isEmpty
    }

    private static func recordingRecorder(in window: NSWindow?) -> KeyboardShortcuts.RecorderCocoa? {
        (window?.firstResponder as? NSText)?.delegate as? KeyboardShortcuts.RecorderCocoa
    }

    private static func didEnd() {
        if let recorder = activeRecorder, let event = NSApp.currentEvent, isTab(event) {
            endedByTab = (recorder, event)
        }
        activeRecorder = nil
    }

    private static func didBecomeActive() {
        guard let window = NSApp.keyWindow, let recorder = recordingRecorder(in: window) else { return }
        activeRecorder = recorder
        guard !isRefocusing else { return }
        guard let event = NSApp.currentEvent, isTab(event) || (event.type == .leftMouseDown && event.window === window) else {
            // Focused by the window itself (the first recorder when Settings opens on macOS 12).
            DispatchQueue.main.async { window.makeFirstResponder(nil) }
            return
        }
        guard isTab(event) else { return }
        // Reached by Tab: pass the focus on, after this responder change finishes.
        let backward = event.modifierFlags.contains(.shift) || event.specialKey == .backTab
        DispatchQueue.main.async {
            var view: NSView = recorder
            for _ in 0..<100 {
                guard let next = backward ? view.previousValidKeyView : view.nextValidKeyView, next !== recorder else { break }
                if !(next is KeyboardShortcuts.RecorderCocoa) {
                    window.makeFirstResponder(next)
                    return
                }
                view = next
            }
            window.makeFirstResponder(nil)
        }
    }
}
