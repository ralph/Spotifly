//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import SwiftUI

// MARK: - Focused Values for Menu Commands

struct FocusedNavigationSelection: FocusedValueKey {
    typealias Value = Binding<NavigationItem?>
}

struct FocusedSearchFieldFocused: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FocusedAccessToken: FocusedValueKey {
    typealias Value = String
}

struct FocusedRecentlyPlayedService: FocusedValueKey {
    typealias Value = RecentlyPlayedService
}

extension FocusedValues {
    var navigationSelection: Binding<NavigationItem?>? {
        get { self[FocusedNavigationSelection.self] }
        set { self[FocusedNavigationSelection.self] = newValue }
    }

    var searchFieldFocused: Binding<Bool>? {
        get { self[FocusedSearchFieldFocused.self] }
        set { self[FocusedSearchFieldFocused.self] = newValue }
    }

    var accessToken: String? {
        get { self[FocusedAccessToken.self] }
        set { self[FocusedAccessToken.self] = newValue }
    }

    var recentlyPlayedService: RecentlyPlayedService? {
        get { self[FocusedRecentlyPlayedService.self] }
        set { self[FocusedRecentlyPlayedService.self] = newValue }
    }
}

// MARK: - App

@main
struct SpotiflyApp: App {
    @StateObject private var windowState = WindowState()

    init() {
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(windowState)
        }
        .windowResizability(windowState.isMiniPlayerMode ? .contentSize : .automatic)
        .commands {
            SpotiflyCommands()
        }

        Settings {
            PreferencesView()
        }
    }
}

// MARK: - Menu Commands

struct SpotiflyCommands: Commands {
    @FocusedValue(\.navigationSelection) var navigationSelection
    @FocusedValue(\.searchFieldFocused) var searchFieldFocused
    @FocusedValue(\.accessToken) var accessToken
    @FocusedValue(\.recentlyPlayedService) var recentlyPlayedService

    private var playbackViewModel: PlaybackViewModel { PlaybackViewModel.shared }

    var body: some Commands {
        // Replace default New Window command
        CommandGroup(replacing: .newItem) {}

        // Playback menu
        CommandMenu("menu.playback") {
            Button("menu.play_pause") {
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

            Button("menu.next_track") {
                playbackViewModel.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("menu.previous_track") {
                playbackViewModel.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Divider()

            Button("menu.like_track") {
                guard let token = accessToken else { return }
                Task {
                    await playbackViewModel.toggleCurrentTrackFavorite(accessToken: token)
                }
            }
            .keyboardShortcut("l", modifiers: .command)
        }

        // Navigation menu
        CommandMenu("menu.navigate") {
            Button("menu.favorites") {
                navigationSelection?.wrappedValue = .favorites
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("menu.playlists") {
                navigationSelection?.wrappedValue = .playlists
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("menu.albums") {
                navigationSelection?.wrappedValue = .albums
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("menu.artists") {
                navigationSelection?.wrappedValue = .artists
            }
            .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("menu.search") {
                searchFieldFocused?.wrappedValue = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("menu.refresh") {
                guard let token = accessToken, let service = recentlyPlayedService else { return }
                Task {
                    await service.refresh(accessToken: token)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
