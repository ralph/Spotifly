//
//  KeyboardShortcuts.swift
//  Spotifly
//
//  Keyboard shortcut handlers for playback control
//

import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

extension View {
    /// Adds playback control keyboard shortcuts
    func playbackShortcuts(playbackViewModel: PlaybackViewModel) -> some View {
        background(
            PlaybackShortcutsView(playbackViewModel: playbackViewModel),
        )
    }

    /// Adds library navigation keyboard shortcuts
    func libraryNavigationShortcuts(selection: Binding<NavigationItem?>) -> some View {
        background(
            LibraryNavigationShortcutsView(selection: selection),
        )
    }

    /// Adds startpage-specific keyboard shortcuts (refresh)
    func startpageShortcuts(
        recentlyPlayedService: RecentlyPlayedService,
    ) -> some View {
        background(
            StartpageShortcutsView(
                recentlyPlayedService: recentlyPlayedService,
            ),
        )
    }

    /// Adds search keyboard shortcuts (focus)
    func searchShortcuts() -> some View {
        background(SearchShortcutsView())
    }
}

private struct PlaybackShortcutsView: View {
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            // Space - Play/Pause
            Button("") {
                if playbackViewModel.isPlaying {
                    playbackViewModel.pause()
                } else {
                    playbackViewModel.resume()
                }
            }
            .keyboardShortcut(" ", modifiers: [])

            // Cmd+Right - Next
            Button("") {
                playbackViewModel.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            // Cmd+Left - Previous
            Button("") {
                playbackViewModel.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            // Cmd+L - Like/Unlike current track
            Button("") {
                Task {
                    await playbackViewModel.toggleCurrentTrackFavorite()
                }
            }
            .keyboardShortcut("l", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

private struct LibraryNavigationShortcutsView: View {
    @Binding var selection: NavigationItem?

    var body: some View {
        Group {
            // Cmd+1 - Favorites
            Button("") {
                selection = .favorites
            }
            .keyboardShortcut("1", modifiers: .command)

            // Cmd+2 - Playlists
            Button("") {
                selection = .playlists
            }
            .keyboardShortcut("2", modifiers: .command)

            // Cmd+3 - Albums
            Button("") {
                selection = .albums
            }
            .keyboardShortcut("3", modifiers: .command)

            // Cmd+4 - Artists
            Button("") {
                selection = .artists
            }
            .keyboardShortcut("4", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

private struct StartpageShortcutsView: View {
    @Bindable var recentlyPlayedService: RecentlyPlayedService
    @Environment(SpotifySession.self) private var session

    var body: some View {
        Button("") {
            Task {
                let token = await session.validAccessToken()
                await recentlyPlayedService.refresh(accessToken: token)
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

private struct SearchShortcutsView: View {
    var body: some View {
        Button("") {
            focusToolbarSearchField()
        }
        .keyboardShortcut("f", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}

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
