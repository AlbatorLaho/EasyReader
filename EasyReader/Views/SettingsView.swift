//
//  SettingsView.swift
//  EasyReader
//
//  Created by Ewalk on 25/1/2.
//

import SwiftUI

//TODO: look at system settings for how they do pronunciations and voice settings
//TODO: have Hide Dock Icon and Hide Status Bar Icon?
struct SettingsView: View {
//    @Default(.pronunciations) var pronunciations
//    @State var selectedPronunciation: Pronunciation?
//    @State var pronunciationSampleText: String = ""

//    func resetPronunciationSampleText() {
//        pronunciationSampleText = "pronunciations"
//    }

    var body: some View {
        TabView {
            SettingsTab("General", systemImage: "gear") {
//                Image(systemName: "gear")
                SettingsGeneralView()
            }
            SettingsTab("Speech", systemImage: "waveform") {
//                Image(systemName: "waveform")
//                Image(systemName: "mic.fill")
//                Image(systemName: "ear.fill")
                SettingsSpeechView()
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
                SettingsReadingView()
            }
//            SettingsTab("Pronuciations", systemImage: "character.bubble.fill") {
////                Image(systemName: "quote.bubble.fill")
////                Image(systemName: "character.bubble.fill")
////                Image(systemName: "text.bubble.fill")
////                Image(systemName: "captions.bubble.fill")
////                Image(systemName: "ellipsis.bubble.fill")
////                Image(systemName: "bubble.left.and.bubble.right.fill")
//
//                VStack(alignment: .leading) {
//                    GroupBox {
//                        Form {
//                            PronunciationTable($pronunciations, selection: $selectedPronunciation)
////                            if #available(macOS 12.0, *) {
////                                Table($pronunciations) {
////                                    TableColumn("Search") { $pronunciation in
////                                        TextField("", text: $pronunciation.search)
////                                    }
////                                    TableColumn("Replace") { $pronunciation in
//////                                        TextEditor(text: $pronunciation.replace)
////                                        TextField("", text: $pronunciation.replace)
////                                    }
////                                    TableColumn("Domain") { $pronunciation in
////                                        Picker("", selection: $pronunciation.domain) {
////                                            Text("All Apps").tag(nil as String?)
////                                            Text("Finder").tag("com.apple.finder" as String?)
////                                        }
////                                    }
////                                    TableColumn("Ignore Case") { $pronunciation in
////                                        Toggle("Ignore Case", isOn: $pronunciation.ignoreCase)
////                                    }
////                                    TableColumn("Enabled") { $pronunciation in
////                                        Toggle("Enabled", isOn: $pronunciation.enabled)
////                                    }
////                                }
//////                                .contextMenu()
//////                                .tableStyle(.bordered)
////                                .textFieldStyle(.squareBorder)
////                            } else {
////                                // Fallback on earlier versions
////                            }
//
////                            Button("Pick App") {
////                                showAppPickerDialog = true
////                            }
//
//                            HStack {
//                                Button {
//                                    print("add")
//                                } label: {
//                                    Image(systemName: "plus")
//                                }
//                                Button {
//                                    print("remove")
//                                    if let selectedPronunciation, let index = pronunciations.firstIndex(of: selectedPronunciation) {
//                                        pronunciations.remove(at: index)
//                                    }
//                                } label: {
//                                    Image(systemName: "minus")
//                                }
//                            }
//
////                            Divider()
////                            HStack(spacing: 0) {
////                                Button {
////                                    print("add")
////                                } label: {
////                                    Image(systemName: "plus")
////                                        .frame(width: 24, height: 24)
////                                }
////                                Divider()
////                                Button {
////                                    print("remove")
////                                } label: {
////                                    Image(systemName: "minus")
////                                        .frame(width: 24, height: 24)
////                                }
////                                Divider()
////                                Spacer()
////                            }
////                            .buttonStyle(.borderless)
////                            .frame(height: 20)
//                        }
////                        .border(.black, width: 1)
////                        .fileImporter(isPresented: $showAppPickerDialog, allowedContentTypes: [.application, .applicationBundle]) { result in
////                            switch result {
////                                case .success(let url):
////                                    print(url)
////                                    let bundle = Bundle(url: url)
////                                    print(bundle?.bundleIdentifier)
////                                case .failure(let error):
////                                    print(error)
////                            }
////                        }
//                    } label: {
//                        Label("Pronunciations", systemImage: "bubble.left.and.bubble.right.fill")
//                    }
//                }
//                
//                GroupBox {
////                    TODO: don't take control of the focus... once focused, I can't get it to focus on other elements
//                    TextEditor(text: $pronunciationSampleText)
//                        .font(.system(size: 24))
//                        .cornerRadius(4)
//                        .onAppear(perform: resetPronunciationSampleText)
//                } label: {
//                    HStack {
//                        Text("Pronunciations Playground")
//                        Spacer()
//                        Button("Reset Text", action: resetPronunciationSampleText)
//                    }
//                }
//            }
        }
        .frame(width: 800, height: 500)
        .padding()
    }
}
