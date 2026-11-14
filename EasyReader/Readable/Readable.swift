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
    var onInvalidate: (() -> Void)? { get set }

    func scroll(to selection: Selection, options: ScrollOptions)

    /// The block (paragraph, heading…) holding `offset` of `fullText`, for text without line breaks between blocks; nil: split at line breaks.
    func textBlock(containing offset: Int) -> Selection?

    /// Speech reached `offset` of `selectedText`; returns the piece (in `fullText`) now selected, if units are selected piece by piece.
    func didReach(_ offset: Int) -> Selection?

    /// Must be idempotent: may be called again while reading.
    func beginReading()
    /// Undoes what `beginReading` changed.
    func endReading()
}

extension Readable {
    func textBlock(containing offset: Int) -> Selection? { nil }
    func didReach(_ offset: Int) -> Selection? { nil }
    func beginReading() {}
    func endReading() {}
}

struct ScrollOptions {
    let padding: Int
    let smooth: Bool
    let duration: Double
    let updateRate: Double
}
