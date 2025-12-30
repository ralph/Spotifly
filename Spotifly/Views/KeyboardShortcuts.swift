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
