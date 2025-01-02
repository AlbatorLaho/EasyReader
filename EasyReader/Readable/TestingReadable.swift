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
    let appDomain: String? = nil
    let icon: NSImage? = NSWorkspace.shared.frontmostApplication?.icon
    let fullText: String? = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
    var selectedText: String? {
        guard let fullText, let selection, let textSelection = Range(selection, in: fullText) else { return nil }
        return String(fullText[textSelection])
    }
    var selection: Selection? = Selection(1..<3)
    
    func scroll(to selection: Selection) {
        print("scroll to: \(selection)")
    }
}
