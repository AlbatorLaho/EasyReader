import Cocoa

/// An app's selected text, as plain text: the focused element's `AXSelectedText`, else copied with ⌘C.
@MainActor
enum AppSelection {
    static func text(in pid: pid_t, focused: AXElement?) -> String? {
        if let focused, let text = try? focused.attribute(.selectedText), hasText(text) {
            Log.accessibility.debug("selected text of focused element (\(text.utf16.count) chars)")
            return text
        }
        if let text = CopiedSelection.copy(from: pid, timeout: 0.5), hasText(text) {
            Log.accessibility.debug("copied selection (\(text.utf16.count) chars)")
            return text
        }
        return nil
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
