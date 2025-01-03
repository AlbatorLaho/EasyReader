//
//  SettingsView.swift
//  EasyReader
//
//  Created by Ewalk on 25/1/2.
//

import SwiftUI
import AVKit
import AXSwift
import Defaults

struct SettingsView: View {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @Default(.speechVoice) var speechVoice
    @Default(.speechVolume) var speechVolume
    @Default(.speechRate) var speechRate
    @Default(.speechPitch) var speechPitch
    @Default(.speechStopBoundary) var speechStopBoundary
    @Default(.speechDelayBefore) var speechDelayBefore
    @Default(.speechDelayAfter) var speechDelayAfter
//    @State var speechVoices = AVSpeechSynthesisVoice.speechVoices()
    @State var speechVoices: [AVSpeechSynthesisVoice] = []
    @State var showResetDefaultsAlert = false
    @State var sampleText: String = ""

    func resetSampleText() {
        sampleText = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.\n\n", count: 3)
    }
    
    var body: some View {
        TabView {
            SettingsTab("General", systemImage: "gear") {
//                Image(systemName: "gear")
            }
            SettingsTab("Speech", systemImage: "waveform") {
                //                Image(systemName: "waveform")
                //                Image(systemName: "mic.fill")
                //                Image(systemName: "ear.fill")
                
                VStack {
//                    Form {
//                        Picker("Select Voice:", selection: $speechVoice) {
//                            Text("System Voice (TEST)")
//                                .tag(nil as AVSpeechSynthesisVoice?)
//                            Divider()
//                            ForEach(speechVoices, id: \.identifier) { voice in
//                                Text("\(voice.name) (\(voice.language))")
//                                    .tag(voice as AVSpeechSynthesisVoice?)
//                            }
//                        }
//                        .onAppear() {
//                            speechVoices = AVSpeechSynthesisVoice.speechVoices()
//                        }
                        
                        GroupBox {
                            Form {
                                Slider(value: $speechVolume, in: 0...1, step: 0.1) {
                                    Text("Volume:")
                                } minimumValueLabel: { Text("0%") } maximumValueLabel: { Text("100%") }
                                Slider(value: $speechRate, in: 0.25...0.75, step: 0.05) {
                                    Text("Rate:")
                                } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }
                                Slider(value: $speechPitch, in: 0.5...1.5, step: 0.1) {
                                    Text("Pitch:")
                                } minimumValueLabel: { Text("½") } maximumValueLabel: { Text("2×") }
                            }
                        } label: {
//                            Label("Voice", systemImage: "mic.fill")
                            Picker(selection: $speechVoice) {
                                Text("System Voice (TEST)").tag(nil as AVSpeechSynthesisVoice?)
                                Divider()
//                                TODO: sort voices
                                ForEach(speechVoices, id: \.identifier) { voice in
                                    Text("\(voice.name) (\(voice.language))").tag(voice as AVSpeechSynthesisVoice?)
                                }
                            } label: {
                                Label("Voice:", systemImage: "mic.fill")
                            }
                            .onAppear() {
                                speechVoices = AVSpeechSynthesisVoice.speechVoices()
                            }
                        }
                        
                        GroupBox {
                            Form {
                                Picker("Stop Boundary:", selection: $speechStopBoundary) {
                                    Text("Immediate").tag(AVSpeechBoundary.immediate)
                                    Text("Word").tag(AVSpeechBoundary.word)
                                }
                                Picker("Pause/Stop:", selection: $speechStopBoundary) {
                                    Text("Immediately").tag(AVSpeechBoundary.immediate)
                                    Text("After Word").tag(AVSpeechBoundary.word)
                                }
                                .pickerStyle(.inline)
                                Slider(value: $speechDelayBefore, in: 0...1, step: 0.1) {
                                    Text("Delay Before:")
//                                    Text("Pre-Delay:")
                                } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("1s") }
                                Slider(value: $speechDelayAfter, in: 0...1, step: 0.1) {
                                    Text("Delay After:")
//                                    Text("Post-Delay:")
                                } minimumValueLabel: { Text("0s") } maximumValueLabel: { Text("1s") }
                            }
                        } label: {
//                            Label("Behavior", systemImage: "doc.text")
//                            Label("Behavior", systemImage: "doc.plaintext")
                            Label("Behavior", systemImage: "text.alignleft")
                        }
//                    }

                    Spacer()
                    
                    HStack {
                        Button("Request Accessibility Permission") {
                            _ = UIElement.isProcessTrusted(withPrompt: true)
                        }
                        Spacer()
                        Button("Reset To Defaults") {
                            showResetDefaultsAlert.toggle()
                        }
                        .alert(isPresented: $showResetDefaultsAlert) {
                            Alert(
                                title: Text("Reset To Defaults?"),
                                message: Text("Are you sure you want to reset your settings to the defaults?"),
                                primaryButton: .cancel(),
                                secondaryButton: .destructive(Text("Reset")) {
                                    print("reset settings")
                                    Defaults.reset([
                                        .speechVoice,
                                        .speechVolume,
                                        .speechRate,
                                        .speechPitch,
                                        .speechStopBoundary,
                                        .speechDelayBefore,
                                        .speechDelayAfter,
                                    ])
                                }
                            )
                        }
                    }
                }

                GroupBox {
//                    HStack {
//                        Button("Play") {
//                            _ = appDelegate.easyReader.startReadingFrontmostApplication()
//                        }
//                        Button("Stop") {
//                            _ = appDelegate.easyReader.stop()
//                        }
////                        Button("<") {
////                            _ = appDelegate.easyReader.skip(.backward)
////                        }
////                        Button(">") {
////                            _ = appDelegate.easyReader.skip(.forward)
////                        }
//                    }
//                    TODO: don't take control of the focus... once focused, I can't get it to focus on other elements
                    TextEditor(text: $sampleText)
                        .font(.system(size: 24))
                        .cornerRadius(4)
                        .onAppear(perform: resetSampleText)
                } label: {
                    HStack {
                        Text("Speech Playground")
                        Spacer()
                        Button("Reset Text", action: resetSampleText)
                    }
                }
            }
            SettingsTab("Reading", systemImage: "book.fill") {
//                Image(systemName: "book.fill")
//                Image(systemName: "note.text")
//                Image(systemName: "text.alignleft")
//                Image(systemName: "text.and.command.macwindow")
//                Image(systemName: "doc.text.fill")
//                Image(systemName: "doc.plaintext.fill")
//                Image(systemName: "doc.richtext.fill")
//                Image(systemName: "chart.bar.doc.horizontal.fill")
//                Image(systemName: "doc.text.magnifyingglass")
            }
            SettingsTab("Pronuciations", systemImage: "character.bubble.fill") {
//                Image(systemName: "quote.bubble.fill")
//                Image(systemName: "character.bubble.fill")
//                Image(systemName: "text.bubble.fill")
//                Image(systemName: "captions.bubble.fill")
//                Image(systemName: "ellipsis.bubble.fill")
//                Image(systemName: "bubble.left.and.bubble.right.fill")
            }
        }
        .frame(width: 800, height: 500)
        .padding()
        
//        Form {
////            Toggle("Use System Voice", isOn: $useSystemVoice)
////            Defaults.Toggle("Use System Voice", key: .useSystemVoice)
//
//            Picker("Select Voice", selection: $speechVoice) {
//                Text("System Voice (TEST)")
//                    .tag(nil as AVSpeechSynthesisVoice?)
//                Divider()
//                ForEach(speechVoices, id: \.identifier) { voice in
//                    Text("\(voice.name) (\(voice.language))")
//                        .tag(voice as AVSpeechSynthesisVoice?)
//                }
//            }
//            .onAppear() {
//                speechVoices = AVSpeechSynthesisVoice.speechVoices()
//            }
//
//            Button("Play Sample") {
//                appDelegate.easyReader.readable = TestingReadable()
//                _ = appDelegate.easyReader.start()
//            }
//
//            GroupBox(content: {
//                Form {
////                    TODO: add text fields for manual input
//                    Slider(value: $speechVolume, in: 0...2, step: 0.1) { Text("Voice Volume") }
//                    Slider(value: $speechRate, in: 0.25...1, step: 0.05) { Text("Voice Rate") }
////                    Slider(value: $speechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate, step: 0.05) { Text("Voice Rate") }
//                    Slider(value: $speechPitch, in: 0...2, step: 0.1) { Text("Voice Pitch") }
//
////                    TextField("Delay Before", value: $speechDelayBefore, formatter: NumberFormatter())
////                    TextField("Delay After", value: $speechDelayAfter, formatter: NumberFormatter())
////    //                LabeledContent("Delay Before", value: $speechDelayBefore, format: .interval)
////    //                LabeledContent("Delay After", value: $speechDelayAfter, format: .interval)
////                    Stepper("Delay Before", value: $speechDelayBefore, in: 0...10, step: 0.05)
////                        .labelsHidden()
////                    Stepper("Delay After", value: $speechDelayAfter, in: 0...10, step: 0.05)
////                        .labelsHidden()
////
////                    HStack {
////                        TextField("Delay After", value: $speechDelayAfter, formatter: NumberFormatter())
////                            .textFieldStyle(.roundedBorder)
////    //                        .multilineTextAlignment(.center)
////    //                        .focused()
////                        Stepper("Delay After", value: $speechDelayAfter, in: 0...10, step: 0.05)
////                            .labelsHidden()
////                    }
//
//                    Picker("Stop Boundary", selection: $speechStopBoundary) {
//                        Text("Immediate")
//                            .tag(AVSpeechBoundary.immediate)
//                        Text("Word")
//                            .tag(AVSpeechBoundary.word)
//                    }
//                }
//            }, label: {
//                Text("Voice")
//            })
//
//            HStack {
//                Button("Request Accessibility Permission") {
//                    _ = UIElement.isProcessTrusted(withPrompt: true)
//                }
//                Spacer()
//                Button("Reset To Defaults") {
//                    showResetDefaultsAlert.toggle()
//                }
//                .alert(isPresented: $showResetDefaultsAlert) {
//                    Alert(
//                        title: Text("Reset To Defaults?"),
//                        message: Text("Are you sure you want to reset your settings to the defaults?"),
//                        primaryButton: .cancel(),
//                        secondaryButton: .destructive(Text("Reset")) {
//                            print("reset settings")
////                            Defaults.removeAll()
//                        }
//                    )
//                }
//            }
//
////            if let selectedVoice = selectedVoice {
////                Text("Selected: \(selectedVoice.name) (\(selectedVoice.language))")
////            }
//
////            List {
////                ForEach($pronunciations, id: \.search) { pronunciation in
////                    HStack {
////                        TextField("Search", text: pronunciation.search)
////                        TextField("Replace", text: pronunciation.replace)
////                        Picker("App", selection: pronunciation.domain) {}
////                        Toggle("Enable", isOn: pronunciation.enabled)
////                    }
////                }
////            }
//        }
//        .padding()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
