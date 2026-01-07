//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

// MARK: - Focused Values for Menu Commands

struct FocusedNavigationSelection: FocusedValueKey {
    typealias Value = Binding<NavigationItem?>
}

struct FocusedSearchFieldFocused: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct FocusedSession: FocusedValueKey {
    typealias Value = SpotifySession
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

    var session: SpotifySession? {
        get { self[FocusedSession.self] }
        set { self[FocusedSession.self] = newValue }
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
        #if os(macOS)
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }

    var body: some Scene {
        #if os(macOS)
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
        #else
        WindowGroup {
            ContentView()
                .environmentObject(windowState)
        }
        #endif
    }
}

// MARK: - Menu Commands

#if os(macOS)
struct SpotiflyCommands: Commands {
    @FocusedValue(\.navigationSelection) var navigationSelection
    @FocusedValue(\.searchFieldFocused) var searchFieldFocused
    @FocusedValue(\.session) var session
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
                guard let session else { return }
                Task {
                    let token = await session.validAccessToken()
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
                guard let session, let service = recentlyPlayedService else { return }
                Task {
                    let token = await session.validAccessToken()
                    await service.refresh(accessToken: token)
                }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
#endif
