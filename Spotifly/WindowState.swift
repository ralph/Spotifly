//
//  WindowState.swift
//  Spotifly
//
//  Manages playback focus mode state
//  - macOS: Mini player mode with resizable window
//  - iOS/iPadOS: Full screen player view
//

#if os(macOS)
import AppKit
#endif
import Combine
import SwiftUI

@MainActor
class WindowState: ObservableObject {
    /// On macOS: mini player mode (compact window)
    /// On iOS/iPadOS: full screen player view (maxi player)
    @Published var isMiniPlayerMode: Bool = false

    #if os(macOS)
    // Store the previous window frame to restore when exiting mini player
    private var savedWindowFrame: NSRect?

    static let miniPlayerSize = NSSize(width: 600, height: 120)
    static let defaultSize = NSSize(width: 800, height: 600)
    #endif

    func toggleMiniPlayerMode() {
        #if os(macOS)
        if isMiniPlayerMode {
            exitMiniPlayerMode()
        } else {
            enterMiniPlayerMode()
        }
        #else
        // On iOS/iPadOS, just toggle the state
        // The UI will handle showing/hiding the full screen player
        isMiniPlayerMode.toggle()
        #endif
    }

    #if os(macOS)
    private func enterMiniPlayerMode() {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }

        // Save current window frame before switching
        savedWindowFrame = window.frame

        // Set mini player mode FIRST so SwiftUI removes the navigation views
        // before we resize the window
        isMiniPlayerMode = true

        // Give SwiftUI a chance to update the view hierarchy
        DispatchQueue.main.async {
            // Remove resizable style
            window.styleMask.remove(.resizable)

            // Calculate new frame maintaining the same top-left position
            let currentFrame = window.frame
            let newHeight = Self.miniPlayerSize.height
            let newWidth = Self.miniPlayerSize.width
            let newOrigin = NSPoint(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + currentFrame.height - newHeight
            )
            let newFrame = NSRect(origin: newOrigin, size: NSSize(width: newWidth, height: newHeight))

            window.setFrame(newFrame, display: true, animate: true)
        }
    }

    private func exitMiniPlayerMode() {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }

        // Restore resizable style
        window.styleMask.insert(.resizable)

        // Restore previous frame or use default
        if let savedFrame = savedWindowFrame {
            // Maintain top-left position when restoring
            let currentFrame = window.frame
            let newOrigin = NSPoint(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + currentFrame.height - savedFrame.height
            )
            let newFrame = NSRect(origin: newOrigin, size: savedFrame.size)
            window.setFrame(newFrame, display: true, animate: true)
        } else {
            window.setContentSize(Self.defaultSize)
        }

        // Set mini player mode AFTER resizing so SwiftUI adds the navigation views
        // after the window is big enough to contain them
        isMiniPlayerMode = false
    }
    #endif
}
