import Cocoa

// Running headers and footers.
extension PDFReadableElement {
    /// A single short line of a page: a possible running header/footer.
    struct MarginLine {
        /// In the page's `rawLeaves`.
        let index: Int
        let element: AXElement
        let key: String
        /// Among the page's first or last two lines.
        let isEdge: Bool
    }

    static func marginLines(_ statics: [RawLeaf]) -> [MarginLine] {
        let nonBlank = statics.indices.filter { statics[$0].value.contains { !$0.isWhitespace } }
        let edges = Set(nonBlank.prefix(2) + nonBlank.suffix(2))
        return nonBlank.compactMap { index in
            let value = statics[index].value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.contains(where: \.isNewline), value.count <= 80 else { return nil }
            return MarginLine(index: index, element: statics[index].element, key: marginKey(value), isEdge: edges.contains(index))
        }
    }

    /// Possible running headers/footers by index in `rawLeaves`: lines in the top or bottom margin, or (no frame) among the first or last two.
    func marginCandidates(_ lines: [MarginLine], pageFrame: CGRect?) -> [Int: (key: String, inMargin: Bool)] {
        var candidates: [Int: (key: String, inMargin: Bool)] = [:]
        for line in lines {
            if let pageFrame, let frame = Self.usableFrame(of: line.element) {
                if Self.isInMargin(frame, of: pageFrame) { candidates[line.index] = (line.key, true) }
            } else if line.isEdge {
                candidates[line.index] = (line.key, false)
            }
        }
        return candidates
    }

    /// A page's margin candidates' keys: all, and those confirmed in the margin by their frame.
    struct MarginKeys {
        var all: Set<String> = []
        var confirmed: Set<String> = []
        /// A candidate that had no frame (page off screen): the keys are computed again once it has one.
        var frameless: AXElement?
        let lines: [MarginLine]

        init(_ candidates: [Int: (key: String, inMargin: Bool)], lines: [MarginLine]) {
            self.lines = lines
            for line in lines {
                guard let candidate = candidates[line.index] else { continue }
                all.insert(candidate.key)
                if candidate.inMargin { confirmed.insert(candidate.key) } else { frameless = line.element }
            }
        }
    }

    /// Walks the page once; after that, only its lines' frames are read again (once a frameless candidate has one).
    func marginKeys(ofPage page: Int) -> MarginKeys {
        let cached = pageMarginKeys[page]
        if let cached, !(cached.frameless.map(Self.hasFrame) ?? false) { return cached }
        let lines = cached?.lines ?? Self.marginLines(rawLeaves(ofPage: page))
        let keys = MarginKeys(marginCandidates(lines, pageFrame: try? pages[page].attribute(.frame)), lines: lines)
        setMarginKeys(keys, ofPage: page)
        return keys
    }

    func setMarginKeys(_ keys: MarginKeys, ofPage page: Int) {
        pageMarginKeys[page] = keys
        confirmedMarginKeys.formUnion(keys.confirmed)
    }

    private static func hasFrame(_ element: AXElement) -> Bool { usableFrame(of: element) != nil }

    static func usableFrame(of element: AXElement) -> CGRect? {
        guard let frame = try? element.attribute(.frame), !frame.isEmpty, frame.minY.isFinite else { return nil }
        return frame
    }

    /// Page numbers (digits, roman numerals) normalized, so "Page 3 of 9" and "xii" match on other pages.
    nonisolated static func marginKey(_ text: String) -> String {
        var key = text.lowercased()
        for pattern in [#"\d+"#, romanNumeral] {
            key = key.replacingOccurrences(of: pattern, with: "#", options: .regularExpression)
        }
        return key.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Valid numerals only, so words of those letters ("did", "civil") stay; the lookarounds rule out an empty match.
    private nonisolated static let romanNumeral = #"\b(?=[ivxlcdm])m{0,3}(?:cm|cd|d?c{0,3})(?:xc|xl|l?x{0,3})(?:ix|iv|v?i{0,3})\b(?<=[ivxlcdm])"#

    nonisolated static func isInMargin(_ frame: CGRect, of pageFrame: CGRect) -> Bool {
        guard !frame.isEmpty, frame.minY.isFinite, !pageFrame.isEmpty else { return false }
        let margin = pageFrame.height * 0.08
        return frame.maxY <= pageFrame.minY + margin || frame.minY >= pageFrame.maxY - margin
    }
}
