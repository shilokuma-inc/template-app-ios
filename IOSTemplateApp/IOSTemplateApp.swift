//
//  IOSTemplateApp.swift
//  IOSTemplateApp
//
//  Created by 村石 拓海 on 2024/05/12.
//

import SwiftUI

@main
struct IOSTemplateApp: App {
    @State private var store = ScanStore()
    @State private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .preferredColorScheme(settings.appearance.colorScheme)
                .environment(\.locale, settings.language.locale)
        }
    }
}
