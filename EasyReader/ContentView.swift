//
//  ContentView.swift
//  EasyReader
//
//  Created by Ewalk on 24/11/2.
//

import SwiftUI

//TODO:
//support more element roles (check Finder (QuickLook/Info), browsers, text editors, Preview (PDF), Terminal, Mail, Contacts, Notes, Dictionary, NetNewsWire, Numbers, Pages)
//with using the services menu, we could send things like text files to this to read or something... is that worth doing?
//add a reader view that can be a speech playground sorta thing... (could be used the same as cmd-shift-x for TextEdit)
//localization
//don't have any nested types? (since protocols can't be nested, like EasyReaderDelegate) e.g. EasyReader.State > EasyReaderState
//make sure any buttons/menus that open a dialog, end with "..."
//make sure scrolling selection into view happens when starting/resuming reading?
struct ContentView: View {
    @State private var text = "This is some testing text... and it's gotta be pretty long, in order to test things well. So I guess we'll see how well it works\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nWe need lots of stuff to make it scrollable\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nDoes it work?\n\n\n\n\n\nI hope so"

    var body: some View {
        TextEditor(text: $text)
            .font(.largeTitle)
            .padding()
    }
}
