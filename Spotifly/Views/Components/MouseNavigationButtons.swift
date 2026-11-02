//
//  MouseNavigationButtons.swift
//  Spotifly
//
//  The mouse's back and forward buttons
//

import AppKit
import SwiftUI

/// The mouse's back and forward buttons, its fourth and fifth, for the window this view is in:
/// they step through its history as the toolbar's arrows and ⌘[ and ⌘] do, and as Safari's do.
///
/// AppKit hands the buttons to whatever view is under the pointer, which ignores them, and SwiftUI
/// has no gesture for them, so a monitor reads them before any view does. Each window has its
/// own, which acts on presses in that window alone, key or not.
struct MouseNavigationButtons: NSViewRepresentable {
    let coordinator: NavigationCoordinator

    func makeNSView(context _: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.coordinator = coordinator
    }

    final class MonitorView: NSView {
        var coordinator: NavigationCoordinator?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                guard let self, event.window === window else { return event }
                switch event.buttonNumber {
                case 3: coordinator?.navigateBackward()
                case 4: coordinator?.navigateForward()
                default: return event
                }
                return nil
            }
        }

        /// Clicks go to the window's content, never to this view behind it.
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }
}
