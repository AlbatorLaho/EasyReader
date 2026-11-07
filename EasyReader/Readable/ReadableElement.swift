//
//  ReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa
import AXSwift

@MainActor
class ReadableElement: Readable {
//    private let handle: UIElement
//    private let app: NSRunningApplication?
    let handle: UIElement
    let app: NSRunningApplication?
    
    var title: String? {
        let window: UIElement? = try? handle.attribute(.window)
//        let window = try? handle.parent(with: .window)
        return try? window?.attribute(.title)
    }
    var groupTitle: String? {
//        return app?.localizedName ?? (try? (try? handle.parent(with: .application))?.attribute(.title))
        if let name = app?.localizedName { return name }
//        let window: UIElement? = try? handle.attribute(.window)
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
                observer?.stop()
                observer = nil
            } else if observer == nil {
                observeDestruction()
            }
        }
    }
    private var observer: Observer?

    private static var values: [Role: ReadableElement.Type] = [
        .textArea: TextAreaReadableElement.self,
        .webArea: WebAreaReadableElement.self,
    ]

    static subscript(role: Role) -> ReadableElement.Type? {
        get { values[role] }
        set { values[role] = newValue }
    }

    required init(_ element: UIElement) {
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
        do {
            let observer = try Observer(processID: pid) { [weak self] _, _, _ in
                Log.accessibility.debug("readable element or its window destroyed")
                self?.onInvalidate?()
            }
            try observer.addNotification(.uiElementDestroyed, forElement: handle)
            if let window: UIElement = try? handle.attribute(.window) {
                try observer.addNotification(.uiElementDestroyed, forElement: window)
            }
            observer.start()
            self.observer = observer
        } catch {
            Log.accessibility.error("Unable to observe readable element destruction: \(error)")
        }
    }
    
    func scroll(to selection: Selection, options: ScrollOptions) {}
    // Declared here (not only in the protocol extension) so subclasses can override them.
    func beginReading() {}
    func endReading() {}
}

extension ReadableElement {
    //struct Role: RawRepresentable, Hashable, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    struct Role: RawRepresentable, Hashable, ExpressibleByStringLiteral {
        let rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(stringLiteral value: String) {
            self.init(rawValue: value)
        }

        init(_ value: String) {
            self.init(rawValue: value)
        }
    }
}

//extension ReadableElement.Role {
//    static let test = Self(kAXSystemWideRole)
//    static let textArea = Self(kAXTextAreaRole)
//    static let textField = Self(kAXTextFieldRole)
//    static let staticText = Self(kAXStaticTextRole)
////    static let test: Self = "AXSystemWide"
////    static let textArea: Self = "AXTextArea"
////    static let textField: Self = "AXTextField"
////    static let staticText: Self = "AXStaticText"
//    static let webArea: Self = "AXWebArea"
//}

extension UIElement {
    func parent() throws -> UIElement? {
        return try attribute(.parent)
    }

    func parent(with role: Role) throws -> UIElement? {
        return try parent(with: role.rawValue)
    }

    func parent(with role: String) throws -> UIElement? {
        guard let parent: UIElement = try parent() else { return nil }
        guard role == (try parent.attribute(.role)) else { return try parent.parent(with: role) }
        return parent
    }
}
