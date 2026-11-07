extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Collection where Element == UInt16 {
    /// Whether `other` occurs at `offset` (false when it doesn't fit).
    func matches<Other: Collection>(_ other: Other, at offset: Int) -> Bool where Other.Element == UInt16 {
        guard offset >= 0, offset + other.count <= count else { return false }
        return self[index(startIndex, offsetBy: offset)...].starts(with: other)
    }
}

extension Task where Success == Never, Failure == Never {
    /// `sleep(for:)` needs macOS 13.
    static func sleep(seconds: Double) async throws {
        try await sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
