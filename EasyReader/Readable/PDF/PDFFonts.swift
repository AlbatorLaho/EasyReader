import Cocoa

// Fonts: sizes, bold and headings.
extension PDFReadableElement {
    /// Size: max of first/middle char; body size: median with the last; bold: all three; superscript: first <75% of middle.
    static func font(of element: AXElement, utf16: [UInt16])
        -> (size: CGFloat?, bodySize: CGFloat?, isBold: Bool?, startsSuperscript: Bool)
    {
        let fonts = [utf16.count / 2, 0, utf16.lastIndex { !isBlank($0) } ?? 0].map { font(of: element, at: $0) }
        let startsSuperscript = fonts[1]?.size.map { first in fonts[0]?.size.map { first < $0 * 0.75 } ?? false } ?? false
        return (fonts.prefix(2).compactMap { $0?.size }.max(), bodySize(fonts.map { $0?.size }), isBold(fonts), startsSuperscript)
    }

    static func font(of element: AXElement, at index: Int) -> (size: CGFloat?, name: String?)? {
        guard let string = try? element.attribute(.attributedStringForRange, for: CFRange(location: index, length: 1))?.string,
            string.length > 0,
            let font = string.attribute(.axFont, at: 0, effectiveRange: nil) as? [String: Any]
        else { return nil }
        return (fontSize(in: font), font["AXFontName"] as? String)
    }

    /// nil if any font name is unknown.
    static func isBold(_ fonts: [(size: CGFloat?, name: String?)?]) -> Bool? {
        let names = fonts.map { $0?.name }
        return names.contains(nil) ? nil : names.allSatisfy { isBold(fontName: $0!) }
    }

    /// The line break ending a heading the leaf starts with: up to 3 lines bold (both ends) or larger, before one that isn't and starts with a capital.
    static func headingEnd(of element: AXElement, utf16: [UInt16], lineBreaks: [Int]) -> Int? {
        var lineStart = 0
        for lineBreak in lines(lineBreaks).prefix(3) {
            guard let lineEnd = utf16[lineStart..<lineBreak].lastIndex(where: { !isBlank($0) }),
                let next = utf16[(lineBreak + 1)...].firstIndex(where: { !isBlank($0) }),
                Unicode.Scalar(utf16[next]).map(CharacterSet.uppercaseLetters.contains) == true
            else { return nil }
            let line = [lineStart, lineEnd].map { font(of: element, at: $0) }
            let after = font(of: element, at: next)
            let lineSize = line.compactMap { $0?.size }.min()
            if isSmaller(after?.size, than: lineSize) || (isBold(line) == true && isBold([after]) == false) { return lineBreak }
            // Only a bold heading runs on to more lines.
            guard isBold(line) == true, isBold([after]) == true else { return nil }
            lineStart = lineBreak + 1
        }
        return nil
    }

    /// PostScript names carry the weight: "Arial-BoldMT", "ABCDEF+Inter-SemiBold", "Arial-Black".
    nonisolated static func isBold(fontName: String) -> Bool {
        let name = fontName.lowercased()
        return ["bold", "black", "heavy"].contains { name.contains($0) }
    }

    // PDFKit vends AXFontSize as a string ("10.296").
    nonisolated static func fontSize(in font: [String: Any]) -> CGFloat? {
        switch font["AXFontSize"] {
            case let size as NSNumber: return CGFloat(size.doubleValue)
            case let size as String: return Double(size).map { CGFloat($0) }
            default: return nil
        }
    }
}

extension NSAttributedString.Key {
    static let axFont = Self("AXFont")
}
