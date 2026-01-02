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
                .task(id: windowState.isMiniPlayerMode) {
                    handleMiniPlayerModeChange(enabled: windowState.isMiniPlayerMode)
                }
        }
    }

    @MainActor
    private func handleMiniPlayerModeChange(enabled: Bool) {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }

        if enabled {
            // Entering mini player mode
            // Save current window frame before switching
            windowState.savedWindowFrame = window.frame

            // Remove resizable style
            window.styleMask.remove(.resizable)

            // Calculate new frame maintaining the same top-left position
            let currentFrame = window.frame
            let newHeight = WindowState.miniPlayerSize.height
            let newWidth = WindowState.miniPlayerSize.width
            let newOrigin = NSPoint(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + currentFrame.height - newHeight,
            )
            let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

            window.setFrame(newFrame, display: true, animate: true)
        } else {
            // Exiting mini player mode
            // Restore resizable style
            window.styleMask.insert(.resizable)

            // Restore previous frame or use default
            if let savedFrame = windowState.savedWindowFrame {
                // Maintain top-left position when restoring
                let currentFrame = window.frame
                let newOrigin = NSPoint(
                    x: currentFrame.origin.x,
                    y: currentFrame.origin.y + currentFrame.height - savedFrame.height,
                )
                let newFrame = NSRect(origin: newOrigin, size: savedFrame.size)
                window.setFrame(newFrame, display: true, animate: true)
            } else {
                window.setContentSize(WindowState.defaultSize)
            }
        }
    }
}
