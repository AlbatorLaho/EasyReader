import SwiftUI
import Defaults

struct SettingsReadingView: View {
    @Default(.speechVoice) private var speechVoice
    @Default(.speechVolume) private var speechVolume
    @Default(.speechRate) private var speechRate
    @Default(.speechPitch) private var speechPitch
    @Default(.selectionUnit) private var selectionUnit
    @Default(.speechStopBoundary) private var speechStopBoundary
    @Default(.resumeUnit) private var resumeUnit
    @Default(.pauseBetweenUnits) private var pauseBetweenUnits
    @Default(.repeatingSkipInterval) private var repeatingSkipInterval
    @Default(.scrollSelectionIntoView) private var scrollSelectionIntoView
    @Default(.scrollPadding) private var scrollPadding
    @Default(.scrollDuration) private var scrollDuration
    @Default(.cleanUpPDFText) private var cleanUpPDFText

    private var unit: String { selectionUnit == .paragraph ? "paragraph" : "sentence" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox {
                Form {
                    HStack(spacing: 4) {
                        VoicePicker(selection: $speechVoice)
                            .fixedSize()
                        InfoButton(
                            "The voice EasyReader reads with.",
                            title: "Voice",
                            "System Voice should be the one set in System Settings → Accessibility → Spoken Content. macOS doesn't offer a supported way to ask, so it may not always match.",
                            "Changing the voice while reading restarts from the current word.",
                            "For more voices (like the Enhanced and Premium ones), use the System Voice menu in Spoken Content: Manage Voices… (Customize… on older macOS)."
                        )
                    }
                    .formLabel(Text("Voice:"))

                    SliderControls(value: $speechVolume, in: 0...1, step: 0.1, max: 1, format: .percent) {
                        Text("Volume:")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.fill")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3.fill")
                    }

                    HStack(spacing: 4) {
                        SliderControls(
                            value: Binding(
                                get: { SpeechRate.multiplier(forRate: speechRate) },
                                set: { newValue in
                                    speechRate = SpeechRate.clamped(SpeechRate.rate(forMultiplier: newValue))
                                }
                            ), in: SpeechRate.minimumMultiplier...SpeechRate.maximumMultiplier, step: SpeechRate.step, max: 4, fractionDigits: 1...2
                        ) {
                            Text("Speed:")
                        } minimumValueLabel: {
                            Text("0.5×")
                        } maximumValueLabel: {
                            Text("4×")
                        }
                        InfoButton(
                            "How fast the voice talks; 1.0 is the voice's normal speed.",
                            title: "Speed",
                            "1.0 is the voice's normal speed, 2.0 about twice as fast. Some voices run a little faster or slower than others.",
                            "Changing it while reading restarts from the current word. The faster/slower shortcuts (General) change it too."
                        )
                    }

                    HStack(spacing: 4) {
                        SliderControls(value: $speechPitch, in: 0.5...2, step: 0.1, min: 0.5, max: 2, fractionDigits: 1...1) {
                            Text("Pitch:")
                        } minimumValueLabel: {
                            Text("0.5×")
                        } maximumValueLabel: {
                            Text("2×")
                        }
                        InfoButton(
                            "How high or low the voice sounds.",
                            title: "Pitch",
                            "1.0 is the voice's own pitch. Some voices change only a little, or not at all."
                        )
                    }
                }
            } label: {
                Label("Speech", systemImage: "waveform")
            }

            GroupBox {
                Form {
                    HStack(spacing: 4) {
                        Picker("Read by:", selection: $selectionUnit) {
                            Text("Sentence").tag(Selection.Unit.sentence)
                            Text("Paragraph").tag(Selection.Unit.paragraph)
                        }
                        .fixedSize()
                        InfoButton(
                            "How much EasyReader selects and reads at once.",
                            title: "Read By",
                            "EasyReader selects a sentence (or paragraph), reads it, then moves on to the next one.",
                            "Skipping forward or back also moves by this much."
                        )
                    }

                    HStack(spacing: 4) {
                        Picker("Pause/stop:", selection: $speechStopBoundary) {
                            Text("Immediately").tag(EasyReader.StopBoundary.immediate)
                            Text("After the word").tag(EasyReader.StopBoundary.word)
                            Text("After the \(unit)").tag(EasyReader.StopBoundary.selection)
                        }
                        .fixedSize()
                        InfoButton(
                            "When speech stops after you pause or stop.",
                            title: "Pause/Stop",
                            "Immediately: mid-word, the moment you press it.",
                            "After the word: finishes the word it's on.",
                            "After the \(unit): finishes the \(unit), then selects the next one, so playing again starts there. Press pause again to stop sooner."
                        )
                    }

                    HStack(spacing: 4) {
                        Picker("Resume from:", selection: $resumeUnit) {
                            Text("Where it stopped").tag(EasyReader.ResumeUnit.word)
                            Text("Start of the \(unit)").tag(EasyReader.ResumeUnit.selection)
                        }
                        .fixedSize()
                        InfoButton(
                            "Where reading picks up when you play after a pause.",
                            title: "Resume From",
                            "Where it stopped: carries on from the word it stopped on.",
                            "Start of the \(unit): reads the whole \(unit) again.",
                            "If you selected something else while paused, reading starts from that instead."
                        )
                    }

                    HStack(spacing: 4) {
                        SliderControls(value: $pauseBetweenUnits, in: 0...1, step: 0.1, max: 10) {
                            Text("Delay between \(unit)s:")
                        } minimumValueLabel: {
                            Text("0s")
                        } maximumValueLabel: {
                            Text("1s")
                        }
                        InfoButton(
                            "Extra silence before each next \(unit).",
                            title: "Delay Between \(unit.capitalized)s",
                            "Once a \(unit) is read, the next one is selected, then EasyReader waits this long before reading it.",
                            "Starting, resuming and skipping aren't delayed."
                        )
                    }

                    HStack(spacing: 4) {
                        SliderControls(
                            value: $repeatingSkipInterval, in: EasyReader.repeatingSkipIntervals, step: 0.05, min: 0.05, max: 1,
                            fractionDigits: 2...2
                        ) {
                            Text("Skip repeat interval:")
                        } minimumValueLabel: {
                            Text("0.05s")
                        } maximumValueLabel: {
                            Text("1s")
                        }
                        InfoButton(
                            "How often a held skip key skips again.",
                            title: "Skip Repeat Interval",
                            "Holding a skip key (the media keys or your skip forward/back shortcuts) skips once, then, after a moment, again every this many seconds until you let go.",
                            "Chromium browsers can take up to half a second per skip, so short intervals skip as fast as they can there."
                        )
                    }

                    HStack(spacing: 4) {
                        Toggle("Try cleaning up PDF text", isOn: $cleanUpPDFText)
                        InfoButton(
                            "In PDFs, skip page numbers, running headers and footnotes.",
                            title: "Try Cleaning Up PDF Text",
                            "On: in PDFs (like in Preview), EasyReader tries to skip running headers and footers (page numbers, titles repeated on each page), footnotes at the bottom of a page, and the small footnote marks in the text.",
                            "These are guesses and can now and then skip real text. If something seems missing, turn this off. Selecting text inside a footnote reads it either way.",
                            "Some cleanup always happens: lines are joined into sentences across line, column and page breaks, words split by a hyphen at a line end are read whole, and headings are read on their own.",
                            "A change applies the next time you start reading."
                        )
                    }
                }
            } label: {
                Label("Playback", systemImage: "text.alignleft")
            }

            GroupBox {
                Form {
                    HStack(spacing: 4) {
                        SliderControls(value: $scrollPadding, in: 0...64, step: 8, max: 1024) {
                            Text("Space above:")
                        } minimumValueLabel: {
                            Text("0pt")
                        } maximumValueLabel: {
                            Text("64pt")
                        }
                        InfoButton(
                            "How far below the top the \(unit) being read is scrolled to.",
                            title: "Space Above",
                            "When the \(unit) being read gets this close to the top or bottom edge, or goes past it, the text scrolls to put it this far below the top."
                        )
                    }

                    SliderControls(value: $scrollDuration, in: 0...1, step: 0.1, max: 10) {
                        Text("Scroll duration:")
                    } minimumValueLabel: {
                        Text("Instant")
                    } maximumValueLabel: {
                        Text("1s")
                    }
                }
                .disabled(!scrollSelectionIntoView)
            } label: {
                HStack(spacing: 4) {
                    Toggle("Scroll to follow along", isOn: $scrollSelectionIntoView)
                    InfoButton(
                        "Keep the \(unit) being read in view.",
                        title: "Scroll to Follow Along",
                        "Scrolls the text as reading moves on, so the \(unit) being read stays in view.",
                        "Chromium and Firefox browsers always scroll instantly, just far enough to show the \(unit), without the space above."
                    )
                }
            }

            SettingsFooter {
                ResetDefaultsButton(
                    for: "reading",
                    keys: [
                        .speechVoice,
                        .speechVolume,
                        .speechRate,
                        .speechPitch,
                        .selectionUnit,
                        .speechStopBoundary,
                        .resumeUnit,
                        .pauseBetweenUnits,
                        .repeatingSkipInterval,
                        .scrollSelectionIntoView,
                        .scrollPadding,
                        .scrollDuration,
                        .cleanUpPDFText,
                    ])
            }
        }
    }
}
