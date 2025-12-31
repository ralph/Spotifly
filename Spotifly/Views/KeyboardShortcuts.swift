//
//  KeyboardShortcuts.swift
//  Spotifly
//
//  Keyboard shortcut handlers for playback control
//

import SwiftUI

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
}

private struct PlaybackShortcutsView: View {
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Group {
            // Space - Play/Pause
            Button("") {
                if playbackViewModel.isPlaying {
                    SpotifyPlayer.pause()
                    playbackViewModel.isPlaying = false
                } else {
                    SpotifyPlayer.resume()
                    playbackViewModel.isPlaying = true
                }
                playbackViewModel.updateNowPlayingInfo()
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
