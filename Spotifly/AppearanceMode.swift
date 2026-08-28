//
//  AppearanceMode.swift
//  Spotifly
//
//  The app-wide appearance override chosen in Settings.
//

import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appearanceMode"

    var id: Self {
        self
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .system: "preferences.appearance.system"
        case .light: "preferences.appearance.light"
        case .dark: "preferences.appearance.dark"
        }
    }

    /// For `.preferredColorScheme(_:)`, which is what actually restyles SwiftUI windows —
    /// setting `NSApp.appearance` alone does not reach them.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// Covers what `.preferredColorScheme(_:)` cannot: menus, alerts and other AppKit
    /// windows created outside the SwiftUI scenes.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
