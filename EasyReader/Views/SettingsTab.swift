//
//  SettingsTab.swift
//  EasyReader
//
//  Created by Ewalk on 25/1/2.
//

import SwiftUI

struct SettingsTab<Title: StringProtocol, Content: View>: View {
    private let title: Title
    private let systemImage: String
    private let content: () -> Content
    
    init(_ title: Title, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            content()
        }
        .tabItem() {
            Label(title, systemImage: systemImage)
        }
    }
}
