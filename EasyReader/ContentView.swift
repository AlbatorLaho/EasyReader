import SwiftUI

struct ContentView: View {
    @State private var text = """
        This window only shows up in Debug builds, for testing reading. Click anywhere in here and press the Start/Stop shortcut. Each sentence should get selected while it's being read, and the view should scroll to keep it in sight.

        Things to try:
        • select a different sentence while it's reading, it should continue from there
        • pause in the middle of a long sentence and resume, it should pick up from the word it paused at
        • skip forward and backward, and skip backward on the first sentence (it should just re-read it)
        • change the voice or rate in settings while reading, it should restart from the current word
        • switch the selection unit to paragraph, and check it reads whole paragraphs

        Some tricky stuff for sentence splitting: Dr. Smith paid $3.50 for coffee at 9 a.m. on Jan. 5th. "Is this one sentence?" she asked. Yes… mostly! Emoji 👋🏽 and accents (café, naïve) shouldn't throw off the selection either. Neither should a URL like https://example.com/some/page.html or a version number like 1.2.3.
        \(String(repeating: "\n", count: 24))
        This paragraph is way down here to test auto scrolling. With smooth scrolling on, it should glide here instead of jumping.
        \(String(repeating: "\n", count: 24))
        This is the last paragraph. Reading should stop after this sentence.
        """

    var body: some View {
        TextEditor(text: $text)
            .font(.largeTitle)
            .padding()
    }
}
