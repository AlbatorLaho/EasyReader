# EasyReader [![Build](https://github.com/AlbatorLaho/EasyReader/actions/workflows/build.yml/badge.svg)](https://github.com/AlbatorLaho/EasyReader/actions/workflows/build.yml)
A utility to assist the built-in MacOS screen reader.

## Description

EasyReader provides additional functionality to the built-in text to speech engine on MacOS.

### Key Features

* Selects text as it's reading
* Modify selected text to change what will be read next
* Can integrate with the "Now Playing Center" and media keys
* Can auto scroll the selection into view while reading
* Reads text views, web pages (Safari, Chromium browsers, Firefox) and PDFs in Preview

## Getting Started

### Requirements

* MacOS 11+
* Xcode 16+ (for building)

### Installing

1. Download `.dmg` from [latest release](https://github.com/AlbatorLaho/EasyReader/releases/latest)
2. Open `EasyReader-v*.dmg` file
3. Move `EasyReader.app` to your Applications folder

### Usage

1. Run `EasyReader.app` (runs as a status item in the menu bar)
2. Open settings from the menu bar
3. Customize to your liking

⚠️ Accessibility permission will have to be granted in order for EasyReader to work.
(if you're updating EasyReader, you'll probably have to remove it from the Accessibility permissions, and then add it back again)

### Chrome, Brave, Edge and other Chromium browsers

Chromium browsers only let EasyReader select text in web pages with an experimental flag. Without it, EasyReader still reads web pages, but marks what it reads with a highlight drawn over the page instead of selecting it.

1. Paste `chrome://flags/#enable-accessibility-text-operation` into the browser's address bar (click the flag at the bottom of EasyReader's General settings to copy it)
2. Set **Enable text editing through accessibility APIs** to **Enabled**
3. Relaunch the browser

⚠️ I also have not setup signing/notarization, since I don't have an Apple developer account.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Many thanks to these projects for quickening the development of this app!
* [AXSwift](https://github.com/tmandry/AXSwift) (Swift wrapper for [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h))
* [Defaults](https://github.com/sindresorhus/Defaults) (easier/customizable UserDefaults)
* [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (global keyboard shortcuts)
* [Blender](https://www.blender.org/) (creating icon)
* [Image2icon](https://img2icnsapp.com/) (converting icon to [Apple's app icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons))
