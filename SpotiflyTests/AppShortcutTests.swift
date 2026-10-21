//
//  AppShortcutTests.swift
//  SpotiflyTests
//
//  The shortcuts as the settings window spells them
//

@testable import Spotifly
import Testing

/// The settings window lists the shortcuts the menus bind, spelled as a menu spells them:
/// modifiers in the system's order (⌃⌥⇧⌘), arrows as arrows.
@MainActor
struct AppShortcutTests {
    @Test func `a shortcut is spelled as its menu item shows it`() {
        #expect(AppShortcut.inspector.glyphs == "⌥⌘I")
        #expect(AppShortcut.sidebar.glyphs == "⌃⌘S")
        #expect(AppShortcut.nextTrack.glyphs == "⌘→")
        #expect(AppShortcut.back.glyphs == "⌘[")
    }
}
