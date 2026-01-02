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
    @StateObject private var windowState = WindowState()

    init() {
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(windowState)
        }
        .windowResizability(windowState.isMiniPlayerMode ? .contentSize : .automatic)
    }
}
