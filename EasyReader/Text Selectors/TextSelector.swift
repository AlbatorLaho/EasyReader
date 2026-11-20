import Foundation

protocol TextSelector {
    func select(_ direction: Selection.Direction, from selection: Selection, in string: String) -> Selection
}

extension TextSelector {
    /// Keeps units inside the blocks `block(offset)` reports (nil: whole string), skipping blank ones, for text without block separators (Chromium).
    func select(
        _ direction: Selection.Direction, from selection: Selection, in string: String, blocks block: (Int) -> Selection?
    ) -> Selection {
        let count = string.utf16.count
        var position = direction == .forward ? selection.upperBound : selection.lowerBound
        let maxBlocks = 200
        for _ in 0..<maxBlocks {
            guard direction == .forward ? position < count : position > 0 else { return Selection(position..<position) }
            guard let range = block(direction == .forward ? position : position - 1),
                range.lowerBound <= position, position <= range.upperBound, !range.isEmpty
            else { break }
            let localStart = range.startIndex(in: string)
            let local = range.substring(of: string)
            // Rounded down to a character boundary: results are offset from there.
            let base = string.utf16.distance(from: string.utf16.startIndex, to: localStart)
            let localPosition = position - base
            let found = select(direction, from: Selection(localPosition..<localPosition), in: local)
            if !Self.isBlank(found, in: local) {
                return Selection(base + found.lowerBound..<base + found.upperBound)
            }
            // Only whitespace up to the boundary (e.g. the space after a sentence): step over it, else leave the block.
            let next = base + (direction == .forward ? found.upperBound : found.lowerBound)
            let movedOn = direction == .forward ? next > position && next < range.upperBound : next < position && next > range.lowerBound
            position = movedOn ? next : (direction == .forward ? range.upperBound : range.lowerBound)
        }
        return selectSkippingBlanks(direction, from: position, in: string)
    }

    /// Steps over units with nothing to read (blank lines, U+FFFC); empty when only blanks are left.
    private func selectSkippingBlanks(_ direction: Selection.Direction, from position: Int, in string: String) -> Selection {
        var position = position
        for _ in 0..<1000 {
            let found = select(direction, from: Selection(position..<position), in: string)
            guard Self.isBlank(found, in: string) else { return found }
            let next = direction == .forward ? found.upperBound : found.lowerBound
            guard next != position else { break }
            position = next
        }
        return Selection(position..<position)
    }

    private static func isBlank(_ selection: Selection, in string: String) -> Bool {
        selection.substring(of: string).unicodeScalars.allSatisfy {
            $0 == "\u{FFFC}" || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
