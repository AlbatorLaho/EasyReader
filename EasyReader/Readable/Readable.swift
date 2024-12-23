//
//  Readable.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/12.
//

import Cocoa

protocol Readable {
    var title: String? { get }
    var groupTitle: String? { get }
//    var appDomain: String? { get }
    var icon: NSImage? { get }
    var fullText: String? { get }
    var selectedText: String? { get }
    var selection: Selection? { get set }

    func scroll(to selection: Selection);
}

//protocol ReadableURL: Readable {
//    init(_ url: URL);
//}
