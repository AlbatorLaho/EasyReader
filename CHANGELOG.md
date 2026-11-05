# Changelog

## 0.2.0 - 2026-11-04

- New app icon
- Speech settings changed while not reading keep applying (only the first change used to take effect)
- The Auto Scrolling setting is respected
- The Now Playing rate control sets the right speech rate; rate shortcuts and Now Playing keep the rate in range
- Skipping backward on the first sentence re-reads it instead of stopping
- Resuming after a pause on the last word moves on to the next sentence instead of re-reading it
- Only text in the frontmost window is read (another window's text area could be found and focused)
- Reading stops when the text view or its window closes
- The Start/Stop shortcut stops while paused, like the menu item
- Resume From resets with the other reading settings
- Scrolling near the start or end of the text no longer overshoots
- Fixed crashes when the text got shorter while reading or contained emoji, and a possible hang splitting text into sentences
- Speech rate is shown as real speaking speed (½×–4×) in Settings and Now Playing; the slider covers the full range in ¼× steps and the rate shortcuts step by 0.1×
- Start/Stop while paused resumes the same text, or starts reading the frontmost text if it's different; the menu shows Start while paused
- A pause mid-sentence resumes from the last word spoken (it used to skip to the next sentence)
- Pause, stop and skip work right after moving on to the next sentence
- Skip Forward on the last sentence does nothing (menu item disabled) instead of stopping
- The Accessibility permission indicator updates live; once granted, its button opens the Accessibility settings
- Now Playing: turning it off clears the panel, turning it on while reading shows it right away
- Text in the Settings playgrounds scrolls into view while reading
- Under the hood: Swift 6 language mode, tests on Swift Testing

## 0.1.0 - 2025-02-17

- First release: a menu bar app that reads the selected text in other apps aloud with the system voices, selecting each sentence or paragraph as it's read and moving on to the next
- Select other text while reading to choose what's read next
- Scrolls the text being read into view (smooth or instant, with padding)
- Global keyboard shortcuts: start/stop, play/pause, skip forward/backward, faster/slower/default rate
- Now Playing and media key integration
- Settings for voice, rate, pitch, volume, pauses before/after, reading unit (sentence or paragraph) and where to resume after a pause

