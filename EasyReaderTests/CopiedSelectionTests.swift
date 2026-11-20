import Carbon.HIToolbox
import Testing

@testable import EasyReader

// Text Input Sources must be used on main.
@MainActor
struct CopiedSelectionTests {
    private func layout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try #require(sources?.first, "keyboard layout \(id) not installed")
    }

    @Test(
        arguments: [
            ("com.apple.keylayout.US", 8), ("com.apple.keylayout.Dvorak", 34), ("com.apple.keylayout.DVORAK-QWERTYCMD", 8),
        ] as [(String, CGKeyCode)])
    func copyKeyFollowsLayout(id: String, expected: CGKeyCode) throws {
        #expect(CopiedSelection.keyCode(for: "c", in: try layout(id)) == expected)
    }
}
