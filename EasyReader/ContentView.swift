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
//rename to play/pause instead of resume/pause?
struct ContentView: View {
    private let appDelegate: AppDelegate
    
    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundColor(.accentColor)
            Text("Hello, world!")
            HStack {
                Button("Play", action: appDelegate.startAction)
                Button("Stop", action: appDelegate.stopAction)
                Button("Pause/Resume", action: appDelegate.toggleAction)
                Button("<<<", action: appDelegate.backwardAction)
                Button(">>>", action: appDelegate.forwardAction)
            }
            Button("Test", action: {
                appDelegate.easyReader.readable = TestingReadable()
                _ = appDelegate.easyReader.start()
            })
        }
        .padding()
    }
}

//struct ContentView_Previews: PreviewProvider {
//    static var previews: some View {
//        ContentView()
//    }
//}
