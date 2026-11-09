//
//  AXNotificationObserver.swift
//  EasyReader
//

import ApplicationServices

/// Delivers AX notifications from one app on the main run loop; stops when released.
///
/// Must be released on the main thread: the notification callback reaches it through an unretained pointer, which is
/// safe only because callbacks run on the main run loop and the run loop source is removed in `deinit`.
final class AXNotificationObserver {
    private let observer: AXObserver
    private let handler: @MainActor (AXElement, AXNotification) -> Void

    init(pid: pid_t, handler: @escaping @MainActor (AXElement, AXNotification) -> Void) throws {
        var observer: AXObserver?
        let error = AXObserverCreate(
            pid,
            { _, element, notification, refcon in
                guard let refcon else { return }
                // Runs on the main run loop (see `init`), so nothing actually crosses threads.
                nonisolated(unsafe) let observer = Unmanaged<AXNotificationObserver>.fromOpaque(refcon).takeUnretainedValue()
                nonisolated(unsafe) let element = AXElement(element)
                let notification = AXNotification(name: notification as String)
                MainActor.assumeIsolated {
                    observer.handler(element, notification)
                }
            },
            &observer)
        guard error == .success, let observer else { throw AXFailure.error(error, "observe pid \(pid)") }
        self.observer = observer
        self.handler = handler
        // Common modes: destruction is reported during menu tracking too
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func add(_ notification: AXNotification, for element: AXElement) throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let error = AXObserverAddNotification(observer, element.raw, notification.name as CFString, refcon)
        guard error == .success else { throw AXFailure.error(error, "observe \(notification.name)") }
    }

    deinit {
        dispatchPrecondition(condition: .onQueue(.main))
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
