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

struct FocusedSession: FocusedValueKey {
    typealias Value = SpotifySession
}

struct FocusedHomeService: FocusedValueKey {
    typealias Value = HomeService
}

extension FocusedValues {
    var navigationSelection: Binding<NavigationItem?>? {
        get { self[FocusedNavigationSelection.self] }
        set { self[FocusedNavigationSelection.self] = newValue }
    }

    var session: SpotifySession? {
        get { self[FocusedSession.self] }
        set { self[FocusedSession.self] = newValue }
    }

    var homeService: HomeService? {
        get { self[FocusedHomeService.self] }
        set { self[FocusedHomeService.self] = newValue }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_: Notification) {
        // Shut down Spirc to send goodbye to other Spotify Connect devices.
        //
        // Detached on purpose: an inheriting task would queue behind this delegate callback
        // on the main actor and could not start until it returns, by which point AppKit is
        // already tearing the process down. Detached at least lets it begin immediately.
        // Nothing here can guarantee it finishes — AppKit does not wait for a synchronous
        // `applicationWillTerminate` to spawn work, and only `applicationShouldTerminate`
        // with `.terminateLater` could.
        Task.detached(priority: .userInitiated) { await SpotifyPlayer.shutdown() }
    }
}

// MARK: - App

@main
struct SpotiflyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var windowState = WindowState()

    init() {
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
                    windowState.exitMiniPlayerMode(window: notification.object as? NSWindow)
                }
                .environment(windowState)
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
    @FocusedValue(\.session) var session
    @FocusedValue(\.homeService) var homeService

    private var playbackViewModel: PlaybackViewModel {
        PlaybackViewModel.shared
    }

    var body: some Commands {
        // Replace default New Window command
        CommandGroup(replacing: .newItem) {}

        // Playback menu
        CommandMenu("menu.playback") {
            Button("menu.play_pause") {
                if playbackViewModel.isPlaying {
                    playbackViewModel.pause()
                } else {
                    playbackViewModel.resume()
                }
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
                Task {
                    await playbackViewModel.toggleCurrentTrackFavorite()
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
                focusToolbarSearchField()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("menu.refresh") {
                guard let homeService else { return }
                Task {
                    await homeService.refresh()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
        }

        #if DEBUG
            CommandMenu("Debug") {
                Button("Dump Store to Clipboard") {
                    AppStore.current?.debugDumpJSON()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Copy OAuth Token") {
                    if let token = SpotifySession.current?.accessToken {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
            }
        #endif
    }
}
