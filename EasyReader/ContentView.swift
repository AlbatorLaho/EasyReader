//
//  ContentView.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/2.
//

import SwiftUI

//TODO:
//support more element roles (check Finder (QuickLook/Info), browsers, text editors, Preview (PDF), Terminal, Mail, Contacts, Notes, Dictionary, NetNewsWire, Numbers, Pages)
//with using the services menu, we could send things like text files to this to read or something... is that worth doing?
//add a reader view that can be a speech playground sorta thing... (could be used the same as cmd-shift-x for TextEdit)
//localization
//don't have any nested types? (since protocols can't be nested, like EasyReaderDelegate) e.g. EasyReader.State > EasyReaderState
//rename to play/pause instead of resume/pause?
struct ContentView: View {
    private let appDelegate: AppDelegate
    
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundColor(.accentColor)
            Text("Hello, world!")
            HStack {
                Button("Play", action: appDelegate.startAction)
                Button("Stop", action: appDelegate.stopAction)
                Button("Pause/Resume", action: appDelegate.toggleAction)
                Button("<<<", action: appDelegate.backwardAction)
                Button(">>>", action: appDelegate.forwardAction)
            }
            Button("Test", action: {
                appDelegate.easyReader.readable = TestingReadable()
                _ = appDelegate.easyReader.start()
            })
        }
        .padding()
    }
}

//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}

extension AXUIElement {
    static let systemWide = AXUIElementCreateSystemWide()
    
    private func get<T>(_ attribute: String, as _: T.Type) -> T? {
        var result: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(self, attribute as CFString, &result)
        if err != .success {
            print("error getting \(self)[\(attribute)]: \(err.rawValue)")
        }
        return result as? T
    }
    
    private func get<T>(_ attribute: String, _ parameter: CFTypeRef, as: T.Type) -> T? {
        var result: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(self, attribute as CFString, parameter, &result)
        if err != .success {
            print("error getting \(self)[\(attribute)(\(parameter))]: \(err.rawValue)")
        }
        return result as? T
    }
    
    var focusedUIElement: AXUIElement? {
        return get(kAXFocusedUIElementAttribute, as: AXUIElement.self)
    }
    
    var processID: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(self, &pid) == .success ? pid : nil
    }
    
    var selectedTextRange: CFRange? {
        return get(kAXSelectedTextRangeAttribute, as: AXValue.self)?.asRange
    }
    
    var value: String? {
        return get(kAXValueAttribute, as: CFString.self) as String?
    }
    
    func bounds(for range: CFRange) -> CGRect? {
        return get(kAXBoundsForRangeParameterizedAttribute,
                   AXValue.range(range),
                   as: AXValue.self)?.asRect
    }
    
    var cursorBounds: CGRect? {
        if let selection = self.selectedTextRange, selection.length == 0 {
            // Getting the bounds for an empty range works in TextMate,
            // but not many other apps.
            // FIXME: can we get the correct bounds when RTL text is involved?
            let queryRange =
                selection.location > 0
                    ? CFRange(location: selection.location - 1, length: 1)
                    : selection
            return bounds(for: queryRange)
        }
        return nil
    }
}

extension AXValue {
    private func get<T>(_ type: AXValueType, initial: T) -> T? {
        var result = initial
        return AXValueGetValue(self, type, &result) ? result : nil
    }
    var asPoint: CGPoint? { return get(.cgPoint, initial: .zero) }
    var asSize: CGSize? { return get(.cgSize, initial: .zero) }
    var asRect: CGRect? { return get(.cgRect, initial: .zero) }
    var asRange: CFRange? { return get(.cfRange, initial: CFRange()) }
    var asError: AXError? { return get(.axError, initial: .success) }
    
    private static func create<T>(_ type: AXValueType, _ value: T) -> AXValue {
        var value = value
        return AXValueCreate(type, &value)!
    }
    static func point(_ v: CGPoint) -> AXValue { return create(.cgPoint, v) }
    static func size(_ v: CGSize) -> AXValue { return create(.cgSize, v) }
    static func rect(_ v: CGRect) -> AXValue { return create(.cgRect, v) }
    static func range(_ v: CFRange) -> AXValue { return create(.cfRange, v) }
    static func error(_ v: AXError) -> AXValue { return create(.axError, v) }
}

//extension UIElement {
//    func parameterizedAttribute<T, U>(_ attribute: String, param: U) throws -> T? {
//        var value: AnyObject?
//        let error = AXUIElementCopyParameterizedAttributeValue(
//            element, attribute as CFString, packAXValue(param), &value
//        )
//
//        if error == .noValue || error == .attributeUnsupported {
//            return nil
//        }
//
//        guard error == .success else {
//            throw error
//        }
//
//        return (unpackAXValue(value!) as! T)
//    }
//}
