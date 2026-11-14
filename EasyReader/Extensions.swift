import CoreGraphics

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

extension CGEvent {
    /// Key down and up, posted to `pid` (also reaches a background app).
    static func postKeystroke(_ key: CGKeyCode, flags: CGEventFlags = [], unicode: UniChar? = nil, to pid: pid_t) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = flags
            if var unicode { event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode) }
            event?.postToPid(pid)
        }
    }
}
