//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import SwiftUI

// Window state manager to handle mini player mode
class WindowStateManager {
    static let shared = WindowStateManager()

    var mainWindow: NSWindow?

    func setMiniPlayerMode(_ enabled: Bool) {
        guard let window = mainWindow ?? NSApp.mainWindow else { return }

        if enabled {
            // Mini mode: fixed size
            let miniSize = NSSize(width: 600, height: 120)
            window.minSize = miniSize
            window.maxSize = miniSize
            window.setContentSize(miniSize)

            // Remove resizable
            window.styleMask.remove(.resizable)
        } else {
            // Normal mode: resizable
            window.minSize = NSSize(width: 500, height: 400)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.setContentSize(NSSize(width: 800, height: 600))

            // Add resizable back
            window.styleMask.insert(.resizable)
        }
    }
}

@main
struct SpotiflyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Store reference to main window
        if let window = NSApp.mainWindow ?? NSApp.windows.first {
            WindowStateManager.shared.mainWindow = window
        }
    }
}
