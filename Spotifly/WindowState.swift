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
    var savedWindowFrame: NSRect?

    static let miniPlayerSize = NSSize(width: 600, height: 120)
    static let defaultSize = NSSize(width: 800, height: 600)

    func toggleMiniPlayerMode() {
        isMiniPlayerMode.toggle()
    }
}
