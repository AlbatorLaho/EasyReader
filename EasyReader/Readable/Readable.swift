//
//  Readable.swift
//  EasyReader
//
//  Created by Ewalk on 24/12/12.
//

import Cocoa

@MainActor
protocol Readable: AnyObject {
    var title: String? { get }
    var groupTitle: String? { get }
    var appDomain: String? { get }
    var icon: NSImage? { get }
    var fullText: String? { get }
    var selectedText: String? { get }
    var selection: Selection? { get set }
    /// Called when the readable goes away (e.g. its text view leaves the window or the window closes).
    var onInvalidate: (() -> Void)? { get set }

    func scroll(to selection: Selection, options: ScrollOptions);

    /// Called before reading starts or resumes from stopped; may be called again while reading (must be idempotent).
    func beginReading()
    /// Called once reading stops, the readable is replaced, or the app quits. Undo what `beginReading` changed.
    func endReading()
}

extension Readable {
    func beginReading() {}
    func endReading() {}
}

//protocol ReadableURL: Readable {
//    init(_ url: URL);
//}

struct ScrollOptions {
    let padding: Int
    let smooth: Bool
    let duration: Double
    let updateRate: Double
}
