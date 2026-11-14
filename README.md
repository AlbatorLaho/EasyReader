# EasyReader [![Build](https://github.com/AlbatorLaho/EasyReader/actions/workflows/build.yml/badge.svg)](https://github.com/AlbatorLaho/EasyReader/actions/workflows/build.yml)

A text-to-speech menu bar app that selects each sentence as it reads.

## Description

EasyReader reads your selection, then selects the next sentence (or paragraph) in the app and keeps going until the end of the text. You can pause/resume, skip forward/backward, or select something else to continue reading from there.

### Key Features

- Selects text as it's reading
- Modify the selection while reading to change what will be read next
- Resumes from the word it was paused at
- Can auto scroll the selection into view while reading
- Reads text views, web pages, PDFs and Apple Books (see [Supported apps](#supported-apps))
- Can read just the selected text in unsupported apps (optional)
- Custom pronunciations (per app, regex or IPA), and can import them from VoiceOver
- Global keyboard shortcuts
- Can integrate with the "Now Playing Center" and media keys

## Supported apps

|                                                     | Selects as it reads                  | Auto scroll    | Notes                                                                                  |
| --------------------------------------------------- | ------------------------------------ | -------------- | -------------------------------------------------------------------------------------- |
| Text views (TextEdit and other native text editors) | 🟢                                   | 🟢 smooth      |                                                                                        |
| Safari (WebKit) browsers                            | 🟢                                   | 🟢 smooth      | also apps with embeded (WebKit) web views                                              |
| Chromium browsers                                   | 🟡 with a [flag](#chromium-browsers) | 🟡 jumps       |                                                                                        |
| Firefox browsers                                    | 🟢                                   | 🟡 jumps       | not fully tested                                                                       |
| PDFs in Preview                                     | 🟢                                   | 🟢 smooth      | may be buggy; (purposefully) tries to skip page headers, footers and footnotes         |
| Apple Books                                         | 🟢                                   | 🟢 turns pages | may be buggy                                                                           |
| Electron apps                                       | ⚪                                   | ⚪             | untested, might work like Chromium                                                     |
| Unsupported apps                                    | 🔴                                   | 🔴             | only reads the selected text, if "Read selected text in unsupported apps" is turned on |

🟢 supported · 🟡 partly supported · 🔴 not supported · ⚪ unknown

### Chromium browsers

Chromium browsers only let EasyReader select text in web pages with an experimental flag. Without it, EasyReader still reads web pages, but marks what it reads with a highlight drawn over the page instead of selecting it.

1. Paste `chrome://flags/#enable-accessibility-text-operation` into the browser's address bar (click the flag at the bottom of EasyReader's General settings to copy it)
2. Set **Enable text editing through accessibility APIs** to **Enabled**
3. Relaunch the browser

### Apple Books

EasyReader starts reading at the text you selected on the page you're on (Books doesn't tell other apps what's selected, so EasyReader copies it, then puts your clipboard back), or else at the top of the page. It turns pages and moves on to the next chapter by itself.

### Unsupported apps

An app is unsupported if it has little or no accessibility support (some apps draw their own UI, so there's nothing EasyReader can read), or if its text is in a kind of view EasyReader can't read yet.

If "Read selected text in unsupported apps" is turned on (Reading settings), EasyReader will still read the selected text in them. It won't select or scroll anything there, and it stops at the end of the selection.

## Getting Started

### Requirements

- MacOS 11+
- Xcode 16+ (for building)

### Installing

1. Download `.dmg` from [latest release](https://github.com/AlbatorLaho/EasyReader/releases/latest)
2. Open `EasyReader-v*.dmg` file
3. Move `EasyReader.app` to your Applications folder

⚠️ I haven't setup notarization, since I don't have an Apple developer account. So the first time you open it, you'll have to right click it and choose "Open" (or allow it in System Settings > Privacy & Security).

### Usage

1. Run `EasyReader.app` (runs as a status item in the menu bar)
2. Open settings from the menu bar
3. Set up your shortcuts, and customize to your liking
4. Click into whatever you want read, then press the Start/Stop shortcut (or click "Start" in the menu bar)

It starts reading from your selection, or from the cursor/top of the page if there isn't one.

⚠️ Accessibility permission will have to be granted in order for EasyReader to work.
(releases are all signed with the same certificate, so updating shouldn't lose the permission, but if it does, remove EasyReader from the Accessibility permissions and add it back again)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
The libraries it uses are listed with their licenses in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (also shown in the app's About window).
