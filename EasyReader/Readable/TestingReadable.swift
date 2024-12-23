//
//  TestingReadable.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/14.
//

import Cocoa

final class TestingReadable: Readable {
    let title: String? = "Test Title"
    let groupTitle: String? = "Test Group Title"
    let icon: NSImage? = NSWorkspace.shared.frontmostApplication?.icon
    let fullText: String? = "This is a much longer sentance to test with. Because we need better text to test with, \n\n\n and it needs to be pretty long.\nSo I hope it works good!"
    var selectedText: String? {
        guard let text = fullText, let selection = selection, let textSelection = Range(selection, in: text) else { return nil }
        return String(text[textSelection])
    }
    var selection: Selection? = Selection(1..<3)
    
    func scroll(to selection: Selection) {
        print("scroll to: \(selection)")
    }
}
