//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import SwiftUI

@main
struct SpotiflyApp: App {
    init() {
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
