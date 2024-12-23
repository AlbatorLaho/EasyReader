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
    var icon: NSImage? { NSApplication.shared.applicationIconImage }
    var fullText: String? { textView.string }
    var selectedText: String? {
        guard let text = fullText, let selection = selection, let textSelection = Range(selection, in: text) else { return nil }
        return String(text[textSelection])
    }
    var selection: Selection? {
        get {
            Selection(textView.selectedRange())
        }
        set {
            guard let newSelection = newValue else { return }
            textView.setSelectedRange(NSRange(newSelection))
        }
    }
    
    init(_ textView: NSTextView) {
        self.textView = textView
    }
    
    func scroll(to selection: Selection) {
        textView.scrollRangeToVisible(NSRange(selection))
    }
}
