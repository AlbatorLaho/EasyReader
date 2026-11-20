import Cocoa

// Text: leaves read from their pages and laid out into blocks.
extension PDFReadableElement {
    func hasText(in range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return false }
        let utf16 = text.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        return utf16[start..<end].contains { !Self.isBlank($0) }
    }

    nonisolated static func isBlank(_ unit: UTF16.CodeUnit) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0xFFFC || unit == 0xA0 || unit == wordJoiner
    }

    /// Blocks joined by line breaks; smaller leaves met while a sentence runs on (footnotes, captions) go after its block.
    func layout() {
        var utf16: [UInt16] = []
        var laidOut: [PlacedLeaf] = []
        var previous: KeptLeaf?
        var previousPage = 0
        var deferred: [(page: Int, index: Int)] = []

        func emit(page: Int, index: Int) {
            let leaf = keptLeaves[page]![index]
            var join = Join.none
            if let previous {
                join = Self.join(previous.info, leaf.info, isWord: Self.isWord)
                if join == .none, !previous.isSettable, !leaf.isSettable, leaf.group != nil, leaf.group == previous.group {
                    join = .space
                }
            }
            if !utf16.isEmpty { Self.appendSeparator(join, before: leaf.utf16, to: &utf16) }
            laidOut.append(
                PlacedLeaf(
                    element: leaf.element, page: page, index: index, offset: utf16.count, length: leaf.utf16.count,
                    lineBreaks: leaf.lineBreaks, isSettable: leaf.isSettable, startsBlock: utf16.isEmpty || join == .none))
            utf16 += leaf.utf16
            previous = leaf
            previousPage = page
        }
        func flush() {
            for (page, index) in deferred { emit(page: page, index: index) }
            deferred = []
        }

        for page in loadedPages ?? 0..<0 {
            for (index, leaf) in (keptLeaves[page] ?? []).enumerated() {
                if let key = leaf.marginKey, confirmedMarginKeys.contains(key) {
                    Log.accessibility.debug("pdf: page \(page): skipping header/footer confirmed since \(leaf.info.text)")
                    continue
                }
                // Deferring stops at the page after the open sentence's.
                if let previous, Self.runsOn(previous.info), page <= previousPage + 1 {
                    if Self.isSmaller(leaf.bodySize, than: previous.bodySize) {
                        deferred.append((page, index))
                        continue
                    }
                    if Self.join(previous.info, leaf.info, isWord: Self.isWord) == .none { flush() }
                } else {
                    flush()
                }
                emit(page: page, index: index)
                if !Self.runsOn(leaf.info) { flush() }
            }
        }
        flush()
        leaves = laidOut
        textLength = utf16.count
        text = String(decoding: utf16, as: UTF16.self)
    }

    private nonisolated static func appendSeparator(_ join: Join, before next: [UInt16], to utf16: inout [UInt16]) {
        switch join {
            case .none: utf16.append(0x0A)
            case .space:
                // No space before closing punctuation ("Wheel" "." → "Wheel⁠.").
                let startsWithPunctuation = next.first.flatMap(Unicode.Scalar.init).map {
                    CharacterSet(charactersIn: ".,;:!?)]}”’").contains($0)
                }
                utf16.append(startsWithPunctuation == true ? wordJoiner : 0x20)
            case .hyphen(let keepsHyphen):
                var end = utf16.count - 1
                while end >= 0, isBlank(utf16[end]) {
                    utf16[end] = wordJoiner
                    end -= 1
                }
                if !keepsHyphen, end >= 0, utf16[end] == 0x2D { utf16[end] = wordJoiner }
                utf16.append(wordJoiner)
        }
    }

    /// Depth first, without footnotes or headers/footers in the margin; frameless ones stay (`layout()` drops them) so leaf indices hold.
    func leaves(ofPage page: Int) -> ([KeptLeaf], [SelectorLeaf]) {
        guard pages.indices.contains(page) else { return ([], []) }
        let statics = rawLeaves(ofPage: page)
        let pageFrame = cleansUp ? try? pages[page].attribute(.frame) : nil
        let lines = cleansUp ? Self.marginLines(statics) : []
        let candidates = marginCandidates(lines, pageFrame: pageFrame)
        var nearbyKeys: Set<String> = []
        if cleansUp {
            setMarginKeys(MarginKeys(candidates, lines: lines), ofPage: page)
            let nearby = (max(page - 2, 0)...min(page + 2, pages.count - 1)).filter { $0 != page }.map(marginKeys(ofPage:))
            nearbyKeys = Set(nearby.flatMap(\.all))
        }
        var leaves: [KeptLeaf] = []
        var texts: [SelectorLeaf] = []
        for (index, rawLeaf) in statics.enumerated() {
            let (element, value, group, inHeading) = (rawLeaf.element, rawLeaf.value, rawLeaf.group, rawLeaf.inHeading)
            let isSettable = element.isSettable(.selectedTextRange)
            texts.append(SelectorLeaf(element: element, value: value, isSettable: isSettable))
            let (flat, lineBreaks) = Self.flattened(value)
            let rule = Self.ruleLength(value)
            var utf16 = Array(flat.utf16)
            utf16.replaceSubrange(..<rule, with: repeatElement(0x20, count: rule))
            guard utf16.contains(where: { !Self.isBlank($0) }) else { continue }
            if let candidate = candidates[index], candidate.inMargin, nearbyKeys.contains(candidate.key) {
                Log.accessibility.debug("pdf: page \(page): skipping header/footer \(flat)")
                continue
            }
            Self.dehyphenate(&utf16, lineBreaks: lineBreaks, isWord: Self.isWord)
            if let lineBreak = Self.headingEnd(of: element, utf16: utf16, lineBreaks: lineBreaks) { utf16[lineBreak] = 0x0A }
            let font = Self.font(of: element, utf16: utf16)
            let text = String(repeating: " ", count: rule) + (String(value.utf16.dropFirst(rule)) ?? "")
            leaves.append(
                KeptLeaf(
                    element: element, utf16: utf16, lineBreaks: lineBreaks,
                    isSettable: isSettable, group: group,
                    info: LeafStyle(text: text, fontSize: font.size, isBold: font.isBold, isHeading: inHeading),
                    bodySize: font.bodySize, isMarked: font.startsSuperscript || Self.startsWithMark(text),
                    marginKey: candidates[index].flatMap { $0.inMargin ? nil : $0.key }))
        }
        guard cleansUp else { return (leaves, texts) }
        // Without the headers/footers `layout()` leaves out.
        let counted = leaves.filter { $0.marginKey.map(confirmedMarginKeys.contains) != true }
        let footnotes = Self.footnoteStart(counted.map { ($0.bodySize, $0.utf16.count, $0.isMarked) }) { index in
            guard let pageFrame, let frame = Self.usableFrame(of: counted[index].element)
            else { return nil }
            return frame.minY > pageFrame.midY
        }
        let labels = Set(
            counted[footnotes...].flatMap { leaf in
                leaf.info.text.split(whereSeparator: \.isNewline).enumerated().flatMap { line, text in
                    (line == 0 && leaf.isMarked) || Self.startsWithMark(String(text)) ? Self.footnoteLabels(ofLine: String(text)) : []
                }
            })
        // Small print that only looks marked (table rows, numbered steps) has no matching mark in the body.
        let isConfirmed = footnotes < counted.count && hasMark(in: counted[..<footnotes], labels: labels)
        footnoteLabels[page] = isConfirmed ? labels : []
        if isConfirmed, !pagesReadingFootnotes.contains(page),
            let start = leaves.firstIndex(where: { $0.element == counted[footnotes].element })
        {
            footnoteLeaves[page] = leaves[start...].map(\.element)
            Log.accessibility.debug("pdf: page \(page): skipping \(leaves.count - start) footnote leaves")
            leaves.removeSubrange(start...)
        }
        return (leaves, texts)
    }

    /// Text leaves depth first.
    func rawLeaves(ofPage page: Int) -> [RawLeaf] {
        var statics: [RawLeaf] = []
        var stack: [(AXElement, AXElement?, Bool)] = [(pages[page], nil, false)]
        while let (element, group, inHeading) = stack.popLast() {
            let role = try? element.role()
            guard role == .staticText else {
                let children = (try? element.attribute(.children)) ?? []
                let childGroup = children.count > 1 ? element : group
                stack += children.reversed().map { ($0, childGroup, role == .heading) }
                continue
            }
            statics.append(RawLeaf(element: element, value: (try? element.attribute(.value)) ?? "", group: group, inHeading: inHeading))
        }
        return statics
    }

    private static func isWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: spellingLanguage, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }

    /// Line breaks → spaces (same UTF-16 length), with their offsets.
    nonisolated static func flattened(_ value: String) -> (String, [Int]) {
        var utf16 = Array(value.utf16)
        var lineBreaks: [Int] = []
        for index in utf16.indices where [0x0A, 0x0D, 0x0C, 0x2028, 0x2029].contains(utf16[index]) {
            utf16[index] = 0x20
            lineBreaks.append(index)
        }
        guard !lineBreaks.isEmpty else { return (value, []) }
        return (String(decoding: utf16, as: UTF16.self), lineBreaks)
    }

    /// Letter-hyphen-break-lowercase: the break (and the hyphen, if the joined word is one) become word joiners.
    nonisolated static func dehyphenate(_ utf16: inout [UInt16], lineBreaks: [Int], isWord: (String) -> Bool) {
        let breaks = Set(lineBreaks)
        for lineBreak in lines(lineBreaks) where lineBreak >= 2 {
            let next = breaks.contains(lineBreak + 1) ? lineBreak + 2 : lineBreak + 1
            guard next < utf16.count, utf16[lineBreak - 1] == 0x2D, isLetter(utf16[lineBreak - 2]), isLowercase(utf16[next]) else {
                continue
            }
            var start = lineBreak - 2
            while start > 0, isLetter(utf16[start - 1]) { start -= 1 }
            var end = next
            while end < utf16.count, isLetter(utf16[end]) { end += 1 }
            let word = String(decoding: utf16[start..<lineBreak - 1] + utf16[next..<end], as: UTF16.self)
            utf16.replaceSubrange(lineBreak..<next, with: repeatElement(wordJoiner, count: next - lineBreak))
            if isWord(word) { utf16[lineBreak - 1] = wordJoiner }
        }
    }

    /// The line breaks, consecutive ones (CR LF) as one: the first.
    nonisolated static func lines(_ lineBreaks: [Int]) -> [Int] {
        zip(lineBreaks, [-2] + lineBreaks).filter { $0 - 1 != $1 }.map(\.0)
    }

    /// Continues when `previous` ends mid-sentence in about the same font, unless it's a heading (`AXHeading`; before a capital: one title-case line or bold).
    nonisolated static func join(_ previous: LeafStyle, _ next: LeafStyle, isWord: (String) -> Bool) -> Join {
        guard !previous.isHeading, endsMidSentence(previous.text),
            !isSmaller(next.fontSize, than: previous.fontSize), !isSmaller(previous.fontSize, than: next.fontSize),
            let first = next.text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) })
        else { return .none }
        if CharacterSet.uppercaseLetters.contains(first),
            (previous.isSingleLine && isTitleCase(previous.text)) || (previous.isBold == true && next.isBold == false)
        {
            return .none
        }
        let end = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if end.hasSuffix("-"), CharacterSet.lowercaseLetters.contains(first) {
            let before = end.dropLast().reversed().prefix { $0.isLetter }
            let after = next.text.drop { $0.isWhitespace }.prefix { $0.isLetter }
            if !before.isEmpty { return .hyphen(keepsHyphen: !isWord(String(before.reversed()) + after)) }
        }
        return .space
    }

    /// A sentence is open at the end of `leaf` (smaller text after it is deferred).
    nonisolated static func runsOn(_ leaf: LeafStyle) -> Bool {
        !leaf.isHeading && endsMidSentence(leaf.text) && !(leaf.isSingleLine && isTitleCase(leaf.text))
    }

    nonisolated static func endsMidSentence(_ text: String) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'”’»)]}").union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "\u{2060}"))
        guard let last = text.unicodeScalars.last(where: { !closing.contains($0) }) else { return false }
        return !".!?…:".unicodeScalars.contains(last)
    }

    /// Words of 4+ letters all capitalized: "PRESENT CODE — ACTIVITY", "Quality of Life".
    nonisolated static func isTitleCase(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }.filter { $0.count >= 4 }
        return !words.isEmpty && words.allSatisfy { $0.first?.isUppercase == true }
    }

    nonisolated static func isSmaller(_ size: CGFloat?, than other: CGFloat?) -> Bool {
        guard let size, let other else { return false }
        return size < other * 0.9
    }

    nonisolated static func isLetter(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.letters.contains($0) } ?? false
    }

    nonisolated static func isLowercase(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit).map { CharacterSet.lowercaseLetters.contains($0) } ?? false
    }

    // PDFKit's reports keep line breaks and hyphens and drop trailing whitespace.
    nonisolated static func comparable(_ string: String) -> String {
        String(String.UnicodeScalarView(string.unicodeScalars.filter { !ignoredInComparison.contains($0) }))
    }

    private nonisolated static let ignoredInComparison = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-\u{2060}\u{AD}"))

    /// Where `report` ends in `text` if it starts at `start`, compared as by `comparable` (our joins differ from PDFKit's).
    nonisolated static func end(of report: String, in text: String, from start: Int) -> Int {
        var remaining = comparable(report).unicodeScalars.count
        let utf16 = text.utf16
        guard remaining > 0, let index = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
            let scalars = index.samePosition(in: text.unicodeScalars)
        else { return min(start, utf16.count) }
        var end = start
        for scalar in text.unicodeScalars[scalars...] {
            guard remaining > 0 else { break }
            end += UTF16.width(scalar)
            if !ignoredInComparison.contains(scalar) { remaining -= 1 }
        }
        return end
    }

    func string(in selection: Selection) -> String {
        guard let range = Range(selection, in: text) else { return "" }
        return String(text[range])
    }
}
