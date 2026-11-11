//
//  SettingsView.swift
//  EasyReader
//
//  Created by Ewalk on 25/1/2.
//

import SwiftUI

//TODO: have Hide Dock Icon and Hide Status Bar Icon?
struct SettingsView: View {

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
            SettingsTab("Pronunciations", systemImage: "character.bubble.fill") {
                SettingsPronunciationsView()
            }
        }
        .frame(width: 800, height: 500)
        .padding()
    }
}
