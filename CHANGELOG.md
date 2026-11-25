# Changelog

## 1.0.2 - 2026-11-25

- Don't reopen Settings closed right after opening it
- Keep the Open and Open URL dialogs findable without a Dock icon
- Use a hidden window group for the standard menus on macOS 11–12
- Open the README from Help instead of the missing Help Book
- Don't let a recorder keep focus it got without a click or Tab
- Recognize the Settings window on macOS 12
- Activate the app when opening Settings on macOS 14+
- Move window presentation out of SettingsOpener into WindowPresenter
- Replace the Dark Mode document setting with Always show documents in Light Mode
- Fix General settings layout on macOS 11–12

## 1.0.1 - 2026-11-21

- Ignore untracked files when preparing a release
- Return to the Speed setting with the normal speed shortcut
- Explain opening the app and skipping text with pronunciations

## 1.0.0 - 2026-11-20

- New Reader window: open text, RTF, Word, OpenDocument, HTML and PDF files or web pages (Open… ⌘O, Open URL… ⌘L), paste or drop text and files, drop on the menu bar icon, or use the Read with EasyReader service
- New Open Selection shortcut reads the selected text of any app in a Reader window; optionally, apps EasyReader doesn't support open their selection there too
- PDFs: running headers and footers are skipped only when they recur on nearby pages, footnotes only when the body has a matching mark; headings are read as their own units; selecting inside a footnote reads it; Try cleaning up PDF text can be turned off
- Web pages start reading at their main content and finish at its end; list numbers are read with their item; long pages are much faster
- Chromium browsers: the highlight follows scrolling, and sentences stay inside list items and table rows
- Pause/stop can act immediately, after the word, or after the sentence or paragraph
- Holding a skip shortcut or media key keeps skipping
- Now Playing shows reading progress; the play key can reread the finished text or start on new text when reading has finished
- System Voice reads with the Spoken Content voice
- Show EasyReader in the menu bar, the Dock or both; the menu bar icon shows whether it's reading, paused or stopped
- Launch at login
- A setup guide on first launch and while Accessibility access is missing
- Reorganized settings with a reset button on each tab (⌥ resets all)
- Apps that turn on their accessibility support only on request (like Pages) can be read
- Many fixes for pausing, stopping and skipping at the edges of the text

## 0.4.0 - 2026-11-14

- Reads PDFs in Preview: skips page headers, footers and footnotes, leaves out footnote marks, and runs sentences on across lines, columns, pages and hyphenated words; tagged PDFs too
- Reads Apple Books, turning pages and following chapters as it reads
- Optional (General settings): reads the selected text in apps EasyReader doesn't support
- Settings open in front when chosen from the menu bar
- New About EasyReader window with third-party licenses; README and settings text describe the current features

## 0.3.0 - 2026-11-10

- Reads web pages in Safari and other WebKit apps, Chromium browsers and Firefox-based browsers (Zen)
- Safari/WebKit pages are selected as they're read and smooth-scrolled like text areas
- Chromium ignores selection changes on web pages, so the text being read is highlighted with an overlay; with `chrome://flags/#enable-accessibility-text-operation` enabled it's selected for real
- Sentences and paragraphs stay inside the page's blocks (Chromium runs headings and paragraphs together)
- Chromium and Electron apps get their accessibility support turned on when reading starts (and back off afterwards)
- Starting from a link or another element inside a page reads the page
- AXSwift replaced with EasyReader's own accessibility layer (no crashes on unexpected values)
- New Pronunciations settings tab: replace words before they're spoken, optionally for one app only, with whole-word, ignore-case, regular expression (`$1` templates) and phonetic (IPA) options
- Live preview with a Speak button; reorder rules by dragging, sort by clicking a column header
- Import pronunciations from VoiceOver
- Resuming from a word works with replaced text
- Info buttons (ⓘ) open a popover with the full explanation
- The Chromium flag note moved to General settings; click the flag to copy it
- WebKit browsers like Orion are no longer mistaken for Chromium

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

