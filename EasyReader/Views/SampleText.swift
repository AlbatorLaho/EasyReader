import SwiftUI

extension ReaderWindow {
    static let sampleText = """
        Welcome to EasyReader

        This is sample text to try your settings on. Press Start, and EasyReader reads it out loud, one sentence at a time, selecting each sentence as it goes. Change a setting while it reads and you'll hear the difference right away.

        EasyReader works in other apps too. It reads text views like this one, web pages in Safari, Chromium browsers and Firefox, PDFs in Preview, and books in Apple Books. Start reading with the menu bar icon or your start/stop shortcut, and it reads whatever app is in front.

        It starts from your selection, or from the top of what you can see if nothing is selected. Then it keeps going, sentence by sentence, until the text runs out. If you select something else while it reads, it moves on from there once it finishes the current sentence.

        Pause whenever you like. When you play again, it picks up from the word it stopped on, or from the start of that sentence, depending on your settings. Try pausing in the middle of this long sentence, which goes on for a while, wanders through a few clauses, and only stops once it has given you plenty of time to find the pause key.

        Short one. Another. And a third.

        Skipping moves a whole sentence forward or back. If you'd rather read a paragraph at a time, switch to paragraphs in the Reading settings, and the skip keys will jump by paragraph instead.

        Some words come out wrong. A voice might spell out GUI as G, U, I, or read "qty 2" exactly as written. Add a pronunciation to fix it, for every app or just one, then come back here to hear it.

        Numbers are fine on their own: 3 apples, 12.5 percent, 1,024 bytes, the year 1999, and 7:30 in the morning.

        As reading moves down the page, the text scrolls along with it, so the sentence being read stays in view. Scrolling can be smooth or instant, and you can choose how much space to leave above the sentence.

        That's the end of the sample. Press Start to hear it again.
        """
}

struct SampleTextButton: View {
    var body: some View {
        Button("Open Sample Text") { ReaderWindow.openSample() }
            .help("Open text to try your settings on in a Reader window.")
    }
}
