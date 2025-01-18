//
//  ReadableElement.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa
import AXSwift

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
    
    private static var values: [Role: ReadableElement.Type] = [
        .textArea: TextAreaReadableElement.self,
//        .webArea: WebAreaReadableElement.self,
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
    }
    
    func scroll(to selection: Selection) {}
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
