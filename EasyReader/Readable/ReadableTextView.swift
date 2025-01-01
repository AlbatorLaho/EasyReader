//
//  ReadableTextView.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/20.
//

import Cocoa

final class ReadableTextView: Readable {
    private let textView: NSTextView
    
    var title: String? { NSApplication.shared.accessibilityTitle() }
//    var title: String? { NSApplication.shared.mainMenu?.title }
    var groupTitle: String? { textView.window?.title }
//    var groupTitle: String? { textView.window?.accessibilityTitle() }
    var appDomain: String? { Bundle.main.bundleIdentifier }
    var icon: NSImage? { NSApplication.shared.applicationIconImage }
    var fullText: String? { textView.string }
    var selectedText: String? {
        guard let fullText, let selection, let textSelection = Range(selection, in: fullText) else { return nil }
        return String(fullText[textSelection])
    }
    var selection: Selection? {
        get {
            Selection(textView.selectedRange())
        }
        set {
            guard let newValue else { return }
            textView.setSelectedRange(NSRange(newValue))
        }
    }
    
    init(_ textView: NSTextView) {
        self.textView = textView
    }
    
    func scroll(to selection: Selection) {
        textView.scrollRangeToVisible(NSRange(selection))
    }
}
