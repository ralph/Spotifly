//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

@main
struct SpotiflyApp: App {
    @StateObject private var windowState = WindowState()

    init() {
        #if os(macOS)
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(windowState)
        }
        #if os(macOS)
        .windowResizability(windowState.isMiniPlayerMode ? .contentSize : .automatic)
        #endif
    }
}
