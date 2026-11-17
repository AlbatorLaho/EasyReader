import SwiftUI
import Defaults

struct SettingsReadingView: View {
    @Default(.selectionUnit) private var selectionUnit
    @Default(.resumeUnit) private var resumeUnit
    @Default(.scrollSelectionIntoView) private var scrollSelectionIntoView
    @Default(.scrollPadding) private var scrollPadding
    @Default(.scrollSmooth) private var scrollSmooth
    @Default(.scrollDuration) private var scrollDuration
    @Default(.scrollUpdateRate) private var scrollUpdateRate
    @Default(.readSelectedTextFallback) private var readSelectedTextFallback
    @Default(.readerOpensNewWindows) private var readerOpensNewWindows
    @Default(.readerDarkBackground) private var readerDarkBackground

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            GroupBox {
                Form {
                    Picker("Selection Unit:", selection: $selectionUnit) {
                        Text("Sentence").tag(Selection.Unit.sentence)
                        Text("Paragraph").tag(Selection.Unit.paragraph)
                    }

                    Picker("Resume From:", selection: $resumeUnit) {
                        Text("Word").tag(EasyReader.ResumeUnit.word)
                        Text("Selection").tag(EasyReader.ResumeUnit.selection)
                    }

                    HStack(spacing: 4) {
                        Toggle("Read selected text in unsupported apps", isOn: $readSelectedTextFallback)
                        InfoButton(
                            "In unsupported apps, read just the selected text.",
                            title: "Unsupported Apps",
                            "EasyReader reads text views, web pages, PDFs and Apple Books, selecting each sentence as it reads and going on through the whole text.",
                            "Apps are usually unsupported because they have little or no accessibility support.",
                            "In unsupported apps, this reads only the text you selected: nothing is highlighted or scrolled, and reading stops at the end of the selection.",
                            "If the app doesn't report its selection to accessibility, EasyReader copies it (⌘C), then puts your clipboard back. Clipboard history apps may still record the copy."
                        )
                    }
                }
            } label: {
                Label("Reading", systemImage: "doc.plaintext")
            }

            GroupBox {
                Form {
                    SliderControls(value: $scrollPadding, in: 0...64, step: 8) {
                        Text("Padding:")
                    } minimumValueLabel: {
                        Text("0px")
                    } maximumValueLabel: {
                        Text("64px")
                    }

                    GroupBox {
                        Form {
                            SliderControls(value: $scrollDuration, in: 0.1...1, step: 0.1) {
                                Text("Duration:")
                            } minimumValueLabel: {
                                Text("0.1s")
                            } maximumValueLabel: {
                                Text("1s")
                            }

                            SliderControls(value: $scrollUpdateRate, in: 30...60, step: 5, min: 1, format: .none) {
                                Text("Update Rate:")
                            } minimumValueLabel: {
                                Text("30/s")
                            } maximumValueLabel: {
                                Text("60/s")
                            }
                        }
                        .disabled(!scrollSmooth)
                    } label: {
                        Toggle("Smooth Scrolling", systemImage: "point.fill.topleft.down.curvedto.point.fill.bottomright.up", isOn: $scrollSmooth)
                    }
                    .padding(.top)
                }
                .disabled(!scrollSelectionIntoView)
            } label: {
                Toggle("Auto Scrolling", systemImage: "arrow.up.arrow.down", isOn: $scrollSelectionIntoView)
            }

            GroupBox {
                Form {
                    HStack(spacing: 4) {
                        Toggle("Open files in new windows", isOn: $readerOpensNewWindows)
                        InfoButton(
                            "Each file or web page opens in a window of its own.",
                            title: "Reader Windows",
                            "The Reader window (menu bar icon → Reader Window) shows files, web pages and text you send it, and reads them like any other app.",
                            "Off: there's one Reader window, and opening something replaces its text.",
                            "On: each file or page opens in a new window (or the front one, if it's empty)."
                        )
                    }

                    HStack(spacing: 4) {
                        Toggle("Dark background in Dark Mode", isOn: $readerDarkBackground)
                        InfoButton(
                            "In Dark Mode, show documents light on dark.",
                            title: "Dark Background",
                            "On: in Dark Mode the Reader window is dark, and the document's colors are adjusted to stay readable (black text turns light), like TextEdit's \"Use Dark Background for Windows\".",
                            "Off: documents always show as they would print, dark on light."
                        )
                    }
                }
            } label: {
                Label("Reader Window", systemImage: "doc.richtext")
            }

            Spacer()

            HStack {
                Spacer()
                ResetDefaultsButton(
                    for: "reading",
                    keys: [
                        .selectionUnit,
                        .resumeUnit,
                        .scrollSelectionIntoView,
                        .scrollPadding,
                        .scrollSmooth,
                        .scrollDuration,
                        .scrollUpdateRate,
                        .readSelectedTextFallback,
                        .readerOpensNewWindows,
                        .readerDarkBackground,
                    ])
            }
        }

        TextPlayground("Reading Playground") {
            """
            Text for testing reading

            Reading:
            • Selection Unit - whether to read a sentence or a paragraph at a time
            • Resume From - when resuming, start from the word it was paused at, or from the start of the selection
            • Read selected text in unsupported apps - for apps EasyReader doesn't support, just read the selected text (nothing gets selected or scrolled, and reading stops at the end of the selection)

            Auto Scrolling:
            • Padding - how many pixels to pad the scrolling from the top and bottom of the view
            • Smooth Scrolling - scroll smoothly, instead of immediately
            \t• Duration - how long (in seconds) smooth scrolling takes to finish
            \t• Update Rate - how many times per second smooth scrolling is updated

            Caveats/Bugs:
            • Chromium browsers and Firefox don't scroll smoothly
            """
        }
    }
}
