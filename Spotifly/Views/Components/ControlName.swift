//
//  ControlName.swift
//  Spotifly
//
//  Names an icon-only control by what it does
//

import SwiftUI

extension View {
    /// Names an icon-only control by what it does, as its tooltip and to accessibility.
    ///
    /// Without a name, accessibility takes the symbol's, which says what the icon shows rather
    /// than what pressing it does: "Lauter" (louder) for the volume button, "Vollbildmodus Aus"
    /// for the mini player, and nothing at all for an image that is not a symbol. A tooltip alone
    /// does not name it either: `.help` fills `AXHelp` only.
    func named(_ name: LocalizedStringKey) -> some View {
        help(name).accessibilityLabel(name)
    }
}
