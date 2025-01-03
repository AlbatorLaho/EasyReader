//
//  SettingsTab.swift
//  EasyReader
//
//  Created by Ewalk on 25/1/2.
//

import SwiftUI

struct SettingsTab<Title: StringProtocol, Content: View>: View {
    let title: Title
    let systemImage: String
    let content: () -> Content
    
    init(_ title: Title, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }
    
    var body: some View {
//        Form {
//            content()
//        }
        HStack(alignment: .top, content: content)
            .tabItem() {
                Label(title, systemImage: systemImage)
//                Image(systemName: systemImage)
//                Text(title)
            }
    }
}
