//
//  Pasteboard.swift
//  Spotifly
//
//  Putting text on the pasteboard
//

import AppKit

extension NSPasteboard {
    /// Replaces what the general pasteboard holds with `string`.
    static func copy(_ string: String) {
        general.clearContents()
        general.setString(string, forType: .string)
    }
}
