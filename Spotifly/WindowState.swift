//
//  WindowState.swift
//  Spotifly
//
//  Manages window state for mini player mode
//

import AppKit
import Combine
import SwiftUI

@MainActor
class WindowState: ObservableObject {
    @Published var isMiniPlayerMode: Bool = false

    // Store the previous window frame to restore when exiting mini player
    private var savedWindowFrame: NSRect?

    static let miniPlayerSize = NSSize(width: 600, height: 120)
    static let defaultSize = NSSize(width: 800, height: 600)

    func toggleMiniPlayerMode() {
        if isMiniPlayerMode {
            exitMiniPlayerMode()
        } else {
            enterMiniPlayerMode()
        }
    }

    private func enterMiniPlayerMode() {
        guard let window = NSApp.mainWindow ?? NSApp.windows.first else { return }

        // Save current window frame before switching
        savedWindowFrame = window.frame

        // Set mini player mode FIRST so SwiftUI removes the navigation views
        // before we resize the window
        isMiniPlayerMode = true

        // Give SwiftUI a chance to update the view hierarchy
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Remove resizable style
            window.styleMask.remove(.resizable)

            // Calculate new frame maintaining the same top-left position
            let currentFrame = window.frame
            let newHeight = Self.miniPlayerSize.height
            let newWidth = Self.miniPlayerSize.width
            let newOrigin = NSPoint(
                x: currentFrame.origin.x,
                y: currentFrame.origin.y + currentFrame.height - newHeight,
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
                y: currentFrame.origin.y + currentFrame.height - savedFrame.height,
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
}
