import ApplicationServices

/// Delivers one app's AX notifications on the main run loop until released, on main (`deinit` removes the unretained refcon's source).
final class AXNotificationObserver {
    private let observer: AXObserver
    private let handler: @MainActor (AXElement, AXNotification) -> Void

    init(pid: pid_t, handler: @escaping @MainActor (AXElement, AXNotification) -> Void) throws {
        var observer: AXObserver?
        let error = AXObserverCreate(
            pid,
            { _, element, notification, refcon in
                guard let refcon else { return }
                // Source is on the main run loop, so nothing crosses threads.
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
        // Common modes: destruction is reported during menu tracking too.
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
