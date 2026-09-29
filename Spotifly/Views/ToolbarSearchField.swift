//
//  ToolbarSearchField.swift
//  Spotifly
//
//  Focus for the toolbar's search field, which the Navigate menu's ⌘F uses
//

import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

#if canImport(AppKit)
    /// Focuses the toolbar's always-visible `.searchable` field. SwiftUI offers no API
    /// to focus an always-visible search field, so we make the underlying NSSearchField
    /// the window's first responder. No-op if the field can't be found.
    @MainActor
    func focusToolbarSearchField() {
        let windows = NSApp.windows.sorted { $0.isKeyWindow && !$1.isKeyWindow }
        for window in windows where window.isVisible {
            // The toolbar lives in the window frame view, above contentView.
            if let field = firstSearchField(in: window.contentView?.superview ?? window.contentView) {
                window.makeFirstResponder(field)
                return
            }
        }
    }

    private func firstSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField {
            return field
        }
        for subview in view.subviews {
            if let field = firstSearchField(in: subview) {
                return field
            }
        }
        return nil
    }
#endif
