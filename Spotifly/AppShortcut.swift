//
//  AppShortcut.swift
//  Spotifly
//
//  The app's keyboard shortcuts, in one place
//

import SwiftUI

/// The app's keyboard shortcuts: the menus bind them, and the settings window lists them, so the
/// two cannot disagree. ⌃⌘S and ⌘, are the system's (`SidebarCommands`, the Settings scene) and
/// are here to be listed only.
enum AppShortcut: CaseIterable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case likeTrack
    case search
    case sidebar
    case inspector
    case miniPlayer
    case back
    case forward
    case favorites
    case playlists
    case albums
    case artists
    case refresh
    case settings

    /// What its menu item is called.
    var title: LocalizedStringKey {
        switch self {
        case .playPause: "menu.play_pause"
        case .nextTrack: "menu.next_track"
        case .previousTrack: "menu.previous_track"
        case .volumeUp: "menu.volume_up"
        case .volumeDown: "menu.volume_down"
        case .likeTrack: "menu.like_track"
        case .search: "menu.search"
        case .sidebar: "preferences.shortcut.sidebar"
        case .inspector: "inspector.title"
        case .miniPlayer: "mini_player.menu"
        case .back: "nav.back"
        case .forward: "nav.forward"
        case .favorites: "menu.favorites"
        case .playlists: "menu.playlists"
        case .albums: "menu.albums"
        case .artists: "menu.artists"
        case .refresh: "menu.refresh"
        case .settings: "nav.settings"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .playPause: KeyboardShortcut(.space, modifiers: [])
        case .nextTrack: KeyboardShortcut(.rightArrow, modifiers: .command)
        case .previousTrack: KeyboardShortcut(.leftArrow, modifiers: .command)
        case .volumeUp: KeyboardShortcut(.upArrow, modifiers: .command)
        case .volumeDown: KeyboardShortcut(.downArrow, modifiers: .command)
        case .likeTrack: KeyboardShortcut("l", modifiers: .command)
        case .search: KeyboardShortcut("f", modifiers: .command)
        case .sidebar: KeyboardShortcut("s", modifiers: [.control, .command])
        case .inspector: KeyboardShortcut("i", modifiers: [.option, .command])
        case .miniPlayer: KeyboardShortcut("m", modifiers: [.option, .command])
        case .back: KeyboardShortcut("[", modifiers: .command)
        case .forward: KeyboardShortcut("]", modifiers: .command)
        case .favorites: KeyboardShortcut("1", modifiers: .command)
        case .playlists: KeyboardShortcut("2", modifiers: .command)
        case .albums: KeyboardShortcut("3", modifiers: .command)
        case .artists: KeyboardShortcut("4", modifiers: .command)
        case .refresh: KeyboardShortcut("r", modifiers: .command)
        case .settings: KeyboardShortcut(",", modifiers: .command)
        }
    }

    /// The shortcut as a menu shows it, "⌥⌘I", the space bar by name.
    var glyphs: String {
        let modifiers = shortcut.modifiers
        let prefix = [(EventModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        let key = shortcut.key
        let name = switch key {
        case .space: String(localized: "preferences.shortcut.space")
        case .rightArrow: "→"
        case .leftArrow: "←"
        case .upArrow: "↑"
        case .downArrow: "↓"
        default: String(key.character).uppercased()
        }
        return prefix + name
    }
}

extension View {
    /// Binds one of the app's shortcuts.
    func keyboardShortcut(_ shortcut: AppShortcut) -> some View {
        keyboardShortcut(shortcut.shortcut)
    }
}
