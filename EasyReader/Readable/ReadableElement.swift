//
//  ReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa

@MainActor
class ReadableElement: Readable {
//    private let handle: UIElement
//    private let app: NSRunningApplication?
    let handle: AXElement
    let app: NSRunningApplication?
    
    var title: String? {
        let window = try? handle.attribute(.window)
//        let window = try? handle.parent(with: .window)
        return try? window?.attribute(.title)
    }
    var groupTitle: String? {
//        return app?.localizedName ?? (try? (try? handle.parent(with: .application))?.attribute(.title))
        if let name = app?.localizedName { return name }
//        let window = try? handle.attribute(.window)
//        let windowApp: UIElement? = try? window?.attribute(.parent)
//        return try? windowApp?.attribute(.title)
        let application = try? handle.parent(with: .application)
        return try? application?.attribute(.title)
    }
    var appDomain: String? { app?.bundleIdentifier }
    var icon: NSImage? { app?.icon }
    var fullText: String? { nil }
    var selectedText: String? { nil }
    var selection: Selection?
    /// Destruction is observed only while a handler is set, so a readable nobody listens to
    /// (e.g. one created and dropped during a search) holds no AX observer.
    var onInvalidate: (() -> Void)? {
        didSet {
            if onInvalidate == nil {
                observer = nil
            } else if observer == nil {
                observeDestruction()
            }
        }
    }
    private var observer: AXNotificationObserver?

    private static let values: [AXRole: ReadableElement.Type] = [
        .textArea: TextAreaReadableElement.self,
        .webArea: WebAreaReadableElement.self,
    ]

    /// Roles too generic to register (`AXGroup`), told apart by subrole.
    private static let subroleValues: [AXRole: [String: ReadableElement.Type]] = [
        .group: ["AXSharedDocumentContainer": PDFReadableElement.self]
    ]

    /// The readable type for an element with `role`; `subrole` is fetched only for roles registered by subrole.
    static func type(for role: AXRole, subrole: () throws -> String?) rethrows -> ReadableElement.Type? {
        if let type = values[role] { return type }
        guard let types = subroleValues[role], let subrole = try subrole() else { return nil }
        return types[subrole]
    }

    required init(_ element: AXElement) {
        handle = element
        app = (try? handle.pid()).flatMap({ pid in
            NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        })
        Log.accessibility.debug("\(Self.self) for \(app?.bundleIdentifier ?? "unknown app")")
    }

    /// AppKit posts `AXUIElementDestroyed` for the element when it leaves its window (even if the view
    /// lives on), and for the window when it closes (the element itself stays valid then), so watch both.
    private func observeDestruction() {
        guard let pid = try? handle.pid() else { return }
        let observer: AXNotificationObserver
        do {
            observer = try AXNotificationObserver(pid: pid) { [weak self] _, _ in
                Log.accessibility.debug("readable element or its window destroyed")
                self?.onInvalidate?()
            }
        } catch {
            Log.accessibility.error("Unable to observe readable element destruction: \(error)")
            return
        }
        // Each separately: either one alone still invalidates.
        let targets = [handle] + [try? handle.attribute(.window)].compactMap { $0 }
        var observed = false
        for target in targets {
            do {
                try observer.add(.uiElementDestroyed, for: target)
                observed = true
            } catch {
                Log.accessibility.error("Unable to observe destruction: \(error)")
            }
        }
        if observed { self.observer = observer }
    }
    
    func scroll(to selection: Selection, options: ScrollOptions) {}
    func textBlock(containing offset: Int) -> Selection? { nil }
    func didReach(_ offset: Int) -> Selection? { nil }
    // Declared here (not only in the protocol extension) so subclasses can override them.
    func beginReading() {}
    func endReading() {}
}

extension AXElement {
    /// The readable for this element, if its role (or for generic roles, subrole) has one.
    @MainActor func readableElement() throws -> ReadableElement? {
        guard let role = try role(),
            let readableType = try ReadableElement.type(for: role, subrole: { try attribute(.subrole) })
        else { return nil }
        return readableType.init(self)
    }
}
