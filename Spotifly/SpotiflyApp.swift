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

struct FocusedHomeService: FocusedValueKey {
    typealias Value = HomeService
}

extension FocusedValues {
    var navigationSelection: Binding<NavigationItem?>? {
        get { self[FocusedNavigationSelection.self] }
        set { self[FocusedNavigationSelection.self] = newValue }
    }

    var homeService: HomeService? {
        get { self[FocusedHomeService.self] }
        set { self[FocusedHomeService.self] = newValue }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var allowedTermination = false

    /// Holds the quit until the player has shut down: it tells Spotify where playback
    /// stopped, and its disconnect takes this Mac off the other Connect devices. Sent
    /// from `applicationWillTerminate`, the report never got out before the process
    /// ended, so the next launch mirrored the track from wherever Spotify last heard of
    /// it, often its start.
    /// Two seconds at most, since a PutState on a dead network waits fifteen.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await SpotifyPlayer.shutdown()
            allowTermination()
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            allowTermination()
        }
        return .terminateLater
    }

    private func allowTermination() {
        guard !allowedTermination else { return }
        allowedTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

// MARK: - App

@main
struct SpotiflyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var windowState = WindowState()
    @AppStorage(AppearanceMode.storageKey) private var appearanceMode: AppearanceMode = .system

    init() {
        // Set activation policy to regular to support media keys
        NSApplication.shared.setActivationPolicy(.regular)

        // Nothing reads the dashboard grant any more; this is where the last copy of it on an
        // upgraded machine gets thrown away.
        KeychainManager.purgeDashboardGrant()
    }

    /// Hosting the unit tests (`TEST_HOST`), the app finds the developer's grant, stored login
    /// and Connect device id, so its content would sign in and register as the Debug app the
    /// developer has open. The tests need the app's code, not its window.
    private static let hostsUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if Self.hostsUnitTests {
                EmptyView()
            } else {
                mainWindow
            }
        }
        .windowResizability(windowState.isMiniPlayerMode ? .contentSize : .automatic)
        .commands {
            SpotiflyCommands()
        }

        Settings {
            PreferencesView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }

    private var mainWindow: some View {
        ContentView()
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
                windowState.exitMiniPlayerMode(window: notification.object as? NSWindow)
            }
            .environment(windowState)
            .environment(PlayerModel.shared)
            // Here rather than in `LoggedInView`, which reads it itself and so cannot be the one
            // to inject it. It lives as long as the process, like the player model.
            .environment(PlaybackViewModel.shared)
            .preferredColorScheme(appearanceMode.colorScheme)
            .onChange(of: appearanceMode, initial: true) { _, mode in
                mode.apply()
            }
            // The window that is open takes any `de.rvdh.spotifly://` URL, such as the
            // sign-in page's link back to the app. Unclaimed, each one opened a second
            // main window with its own services.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }
}

// MARK: - Menu Commands

struct SpotiflyCommands: Commands {
    @FocusedValue(\.navigationSelection) var navigationSelection
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
            .disabled(navigationSelection == nil)

            Button("menu.playlists") {
                navigationSelection?.wrappedValue = .playlists
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(navigationSelection == nil)

            Button("menu.albums") {
                navigationSelection?.wrappedValue = .albums
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(navigationSelection == nil)

            Button("menu.artists") {
                navigationSelection?.wrappedValue = .artists
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(navigationSelection == nil)

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
            // Greyed where there is nothing to act on, as at the login screen or with Settings
            // key, rather than enabled and doing nothing.
            .disabled(homeService == nil)
        }

        #if DEBUG
            // Developer tools, in English only: titles passed as `String` are not looked up as
            // localization keys.
            CommandMenu("Debug" as String) {
                Button("Dump Store to Clipboard" as String) {
                    AppStore.current?.debugDumpJSON()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                // The grant's own token, which is what every request now carries. Paste it
                // into a curl and you are the app.
                Button("Copy Access Token" as String) {
                    Task {
                        guard let token = try? await KeymasterSession.shared.accessToken() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }
            }
        #endif
    }
}

// MARK: - Search Field Focus

/// Focuses the toolbar's always-visible `.searchable` field. SwiftUI offers no API
/// to focus an always-visible search field, so we make the underlying NSSearchField
/// the window's first responder. No-op if the field can't be found.
@MainActor
private func focusToolbarSearchField() {
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
