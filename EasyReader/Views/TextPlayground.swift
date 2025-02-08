//
//  TextPlayground.swift
//  EasyReader
//
//  Created by Ewalk on 2025-02-05.
//

import SwiftUI

struct TextPlayground<Label: View>: View {
//    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate

    private let label: () -> Label
    private let defaultText: () -> String
//    FIXME: state does not stay when switching settings tabs
    @State private var text = ""

    init(defaultText: @escaping () -> String, @ViewBuilder label: @escaping () -> Label = { Text("Playground") }) {
        self.label = label
        self.defaultText = defaultText
    }

    init(_ title: String, defaultText: @escaping () -> String) where Label == Text {
        self.init(defaultText: defaultText, label: { Text(title) })
    }

    var body: some View {
        GroupBox {
//            TODO: don't take control of the focus... once focused, I can't get it to focus on other elements
            TextEditor(text: $text)
                .font(.system(size: 24))
                .clipShape(.rect(cornerRadius: 5))
                .onAppear() {
                    if text.isEmpty {
                        text = defaultText()
                    }
                }
        } label: {
            HStack {
                label()
                Spacer()
//                Button() {
//                    print("gobackward")
//                    _ = appDelegate.easyReader.skip(.backward)
//                } label: {
//                    Image(systemName: "gobackward")
//                }
//                if appDelegate.easyReader.state == .stopped {
////                    Button("Start \(KeyboardShortcuts.Shortcut(name: .toggleStartStop)!.description)", systemImage: "play.fill") {
//                    Button("Start", systemImage: "play.fill") {
//                        print("start")
//                        _ = appDelegate.easyReader.start()
//                    }
//                } else {
//                    Button("Stop", systemImage: "stop.fill") {
//                        print("stop")
//                        _ = appDelegate.easyReader.stop()
//                    }
//                }
//                Button() {
//                    print("goforward")
//                    _ = appDelegate.easyReader.skip(.forward)
//                } label: {
//                    Image(systemName: "goforward")
//                }
//                Spacer()
                Button("Reset Text", systemImage: "arrow.clockwise") {
                    text = defaultText()
                }
            }
        }
    }
}
