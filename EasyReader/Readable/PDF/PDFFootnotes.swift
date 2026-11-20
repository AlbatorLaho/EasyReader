import Cocoa

// Footnotes and their marks.
extension PDFReadableElement {
    /// The first marked leaf among the trailing small-print leaves, unless `isLow` says it's in the upper half (nil: unknown); `leaves.count` if none.
    nonisolated static func footnoteStart(_ leaves: [(fontSize: CGFloat?, length: Int, isMarked: Bool)], isLow: (Int) -> Bool?) -> Int {
        guard let body = dominantSize(leaves.map { ($0.fontSize, $0.length) }) else { return leaves.count }
        var start = leaves.count
        while start > 0, isSmaller(leaves[start - 1].fontSize, than: body) { start -= 1 }
        return leaves.indices[start...].first { leaves[$0].isMarked && isLow($0) != false } ?? leaves.count
    }

    /// The mark a footnote starts with, digits as ASCII: "12. Text" → "12", "[3]" → "3", "¹Text" → "1", "a Jer." → "a", "†Text" → "†".
    nonisolated static func footnoteLabel(_ text: String) -> String? {
        let start = text.drop { $0.isWhitespace || $0 == "[" || $0 == "(" }
        let digits = start.prefix { $0.wholeNumberValue != nil }
        if !digits.isEmpty { return digits.map { String($0.wholeNumberValue!) }.joined() }
        let symbols = start.prefix { "*†‡§¶".contains($0) }
        if !symbols.isEmpty { return String(symbols) }
        return start.first.flatMap { $0.isLowercase ? String($0) : nil }
    }

    /// `footnoteLabel`, and for scripture ("19 a Text", "1 1a Text") the letter too: the body marks are letters.
    nonisolated static func footnoteLabels(ofLine text: String) -> [String] {
        guard let label = footnoteLabel(text) else { return [] }
        let verse = #"^\s*\d{1,3}\s*\d{0,3}\s*([a-z])(?:\s|$)"#
        guard let match = text.range(of: verse, options: .regularExpression) else { return [label] }
        let letter = text[match].last { $0.isLetter }.map(String.init)
        return [label] + (letter.map { [$0] } ?? [])
    }

    /// Whether a footnote label is a mark in the body: glued to the text, a small leaf of its own, else a small font run.
    func hasMark(in body: ArraySlice<KeptLeaf>, labels: Set<String>) -> Bool {
        if body.contains(where: { leaf in labels.contains { Self.hasGluedMark($0, in: leaf.info.text) } }) { return true }
        let bodySize = Self.dominantSize(body.map { ($0.bodySize, $0.utf16.count) })
        if body.contains(where: { Self.isMarkLeaf($0.info.text, size: $0.bodySize, bodySize: bodySize, labels: labels) }) { return true }
        return body.contains { leaf in
            leaf.isSettable
                && !Self.markerRanges(fontRuns(of: leaf.element, length: leaf.utf16.count), in: leaf.info.text, labels: labels).isEmpty
        }
    }

    /// A label alone in a leaf, in small type or of unknown size (tagged marks): not a stray page number ("5").
    nonisolated static func isMarkLeaf(_ text: String, size: CGFloat?, bodySize: CGFloat?, labels: Set<String>) -> Bool {
        labels.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) && (size == nil || isSmaller(size, than: bodySize))
    }

    /// A digit or symbol label glued to a word's end: "ruling.12 Next", "boxes*", not "Form 1212" (letters can't be told).
    nonisolated static func hasGluedMark(_ label: String, in text: String) -> Bool {
        guard !label.isEmpty, !label.contains(where: \.isLetter) else { return false }
        let superscripts = Array("⁰¹²³⁴⁵⁶⁷⁸⁹")
        let ascii = String(text.map { char in superscripts.firstIndex(of: char).map { Character(String($0)) } ?? char })
        let pattern = #"(?<=[\p{L}.,;:?!)\]”’"])"# + NSRegularExpression.escapedPattern(for: label) + #"(?=[\s\p{P}\p{S}]|$)"#
        return ascii.range(of: pattern, options: .regularExpression) != nil
    }

    /// UTF-16 length of the rule lines ("——————", "____") a leaf starts with, as before footnotes: no words to read.
    nonisolated static func ruleLength(_ text: String) -> Int {
        let rule = #"^(?:\s*(?:[-‐‑‒–—―⸺⸻_─━][ \t]*){2,}(?:\R|$))+"#
        return text.range(of: rule, options: .regularExpression).map { text.utf16.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
    }

    /// "1 Text", "12. Text", "[3]", "(4)", "a Jer. 5:3", "*Text", "¹Text".
    nonisolated static func startsWithMark(_ text: String) -> Bool {
        let mark = #"^\s*(?:(?:\d{1,3}|[a-z]|\[\d{1,3}\]|\(\d{1,3}\))[.):]?(?:\s|$)|[*†‡§¶¹²³⁰⁴-⁹])"#
        return text.range(of: mark, options: .regularExpression) != nil
    }

    /// The font size most characters have.
    nonisolated static func dominantSize(_ runs: [(fontSize: CGFloat?, length: Int)]) -> CGFloat? {
        var lengths: [Int: (size: CGFloat, length: Int)] = [:]
        for run in runs {
            guard let size = run.fontSize else { continue }
            let key = Int((size * 10).rounded())
            lengths[key] = (size, (lengths[key]?.length ?? 0) + run.length)
        }
        return lengths.values.max { $0.length < $1.length }?.size
    }

    /// In-leaf ranges of footnote marks; only selectable leaves have font info.
    func markers(of leaf: PlacedLeaf) -> [NSRange] {
        if let cached = markerCache[leaf.element] { return cached }
        let labels = footnoteLabels[leaf.page] ?? []
        let runs = leaf.isSettable && !labels.isEmpty ? fontRuns(of: leaf.element, length: leaf.length) : []
        let markers = runs.isEmpty ? [] : Self.markerRanges(runs, in: string(in: Selection(leaf.offset..<leaf.end)), labels: labels)
        if markerCache.count > 2000 { markerCache = [:] }
        markerCache[leaf.element] = markers
        return markers
    }

    /// A leaf's font sizes by run (one AX call, ~50 ms), cached.
    private func fontRuns(of element: AXElement, length: Int) -> [FontRun] {
        if let cached = runCache[element] { return cached }
        var runs: [FontRun] = []
        if let string = try? element.attribute(.attributedStringForRange, for: CFRange(location: 0, length: length))?.string {
            string.enumerateAttribute(.axFont, in: NSRange(location: 0, length: string.length)) {
                font, range, _ in
                runs.append(FontRun(range: range, fontSize: (font as? [String: Any]).flatMap(Self.fontSize(in:))))
            }
        }
        if runCache.count > 2000 { runCache = [:] }
        runCache[element] = runs
        return runs
    }

    /// Trimmed runs of 1–3 alphanumerics or `*†‡§¶` under 75% of the leaf's dominant size that match one of `labels` (the page's footnotes).
    nonisolated static func markerRanges(_ runs: [FontRun], in text: String, labels: Set<String>) -> [NSRange] {
        guard let body = dominantSize(runs.map { ($0.fontSize, $0.range.length) }) else { return [] }
        let text = text as NSString
        let markChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*†‡§¶"))
        return runs.compactMap { run in
            guard let size = run.fontSize, size < body * 0.75, NSMaxRange(run.range) <= text.length else { return nil }
            let mark = text.substring(with: run.range)
            let trimmed = mark.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...3).contains(trimmed.count), trimmed.unicodeScalars.allSatisfy(markChars.contains),
                footnoteLabel(trimmed).map(labels.contains) == true
            else { return nil }
            let inner = (mark as NSString).range(of: trimmed)
            return NSRange(location: run.range.location + inner.location, length: inner.length)
        }
    }

    /// The median of the middle, first and last characters' sizes; else the middle's.
    nonisolated static func bodySize(_ sizes: [CGFloat?]) -> CGFloat? {
        let known = sizes.compactMap { $0 }.sorted()
        return known.count == 3 ? known[1] : sizes.first.flatMap { $0 } ?? known.first
    }

    /// The page of each skipped footnote leaf on the visible pages matching `predicate`.
    func footnotePages(on visible: [Int], where predicate: (AXElement) throws -> Bool) -> [Int] {
        visible.flatMap { page in (footnoteLeaves[page] ?? []).filter { (try? predicate($0)) == true }.map { _ in page } }
    }

    nonisolated static func isDistinctive(_ report: String) -> Bool {
        report.split { !$0.isLetter && !$0.isNumber }.count >= 2 && report.filter(\.isLetter).count >= 12
    }

    /// Non-selectable (tagged) leaves report a range though they can't be set; PDFKit reports none as `NSNotFound`.
    static func reportsSelection(_ leaf: AXElement) throws -> Bool {
        guard leaf.isSettable(.selectedTextRange), let range = try leaf.attribute(.selectedTextRange) else { return false }
        return range.location != kCFNotFound && range.location != NSNotFound
    }

    /// Puts the page's footnotes in the text, then locates the user's selection again.
    func readFootnotes(on page: Int, locating report: String) -> Selection? {
        Log.accessibility.debug("pdf: user selected in a footnote on page \(page): reading the page's footnotes")
        pagesReadingFootnotes.insert(page)
        footnoteLeaves[page] = nil
        keptLeaves[page] = nil
        if let window = loadedPages {
            loadedPages = nil
            setWindow(window)
        }
        return locate(report, inFootnotes: false)
    }
}
