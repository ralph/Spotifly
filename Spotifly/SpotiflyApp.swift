//
//  SpotiflyApp.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import AppKit
import SwiftUI

// MARK: - Focused Values for Menu Commands

struct FocusedNavigationCoordinator: FocusedValueKey {
    typealias Value = NavigationCoordinator
}

struct FocusedHomeService: FocusedValueKey {
    typealias Value = HomeService
}

extension FocusedValues {
    /// The key window's navigation, for the Navigate menu's sections and history.
    var navigationCoordinator: NavigationCoordinator? {
        get { self[FocusedNavigationCoordinator.self] }
        set { self[FocusedNavigationCoordinator.self] = newValue }
    }

    var homeService: HomeService? {
        get { self[FocusedHomeService.self] }
        set { self[FocusedHomeService.self] = newValue }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var allowedTermination = false

    func applicationDidFinishLaunching(_: Notification) {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            endSearchEditing(onClickOf: event)
            return event
        }
    }

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
    /// Sign-in, and with it the signed-in account's store and services, which a closed window
    /// does not take with it (`LoggedInSession`). None in the unit-test host, where its grant
    /// would sign the developer in, and a test's revocation could sign them out.
    @State private var auth: AuthViewModel? = SpotiflyApp.hostsUnitTests ? nil : AuthViewModel()
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
    /// developer has open. The tests need the app's code, not its window, nor the wake's rebuild
    /// in `PlaybackViewModel`, which a test that reaches the shared instance would set up.
    static let hostsUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var body: some Scene {
        WindowGroup {
            if let auth {
                mainWindow(auth: auth)
            }
        }
        .windowResizability(windowState.isMiniPlayerMode ? .contentSize : .automatic)
        .commands {
            SpotiflyCommands(sessions: auth?.sessions)
        }

        Settings {
            PreferencesView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }

    private func mainWindow(auth: AuthViewModel) -> some View {
        ContentView()
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
                windowState.exitMiniPlayerMode(window: notification.object as? NSWindow)
            }
            .environment(windowState)
            // Speakers and the play alert offer the grant again, and it is this view model that
            // runs it.
            .environment(auth)
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
    /// Nil in the unit-test host.
    let sessions: LoggedInSessions?
    @FocusedValue(\.navigationCoordinator) var navigationCoordinator
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
            NavigationHistoryMenuItems(coordinator: navigationCoordinator)

            Divider()

            Button("menu.favorites") {
                navigationCoordinator?.selectNavigationItem(.favorites)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(navigationCoordinator == nil)

            Button("menu.playlists") {
                navigationCoordinator?.selectNavigationItem(.playlists)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(navigationCoordinator == nil)

            Button("menu.albums") {
                navigationCoordinator?.selectNavigationItem(.albums)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(navigationCoordinator == nil)

            Button("menu.artists") {
                navigationCoordinator?.selectNavigationItem(.artists)
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(navigationCoordinator == nil)

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
                    sessions?.current?.store.debugDumpJSON()
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

/// The history the toolbar's arrows step through, under the shortcuts Safari, Finder and Music
/// use for it; ⌘← and ⌘→ are Previous and Next track.
///
/// A view of its own, so its body follows the coordinator as it moves: the menu's own body is
/// drawn again only when a focused value changes, and the coordinator stays the same object.
private struct NavigationHistoryMenuItems: View {
    let coordinator: NavigationCoordinator?

    var body: some View {
        Button("nav.back") {
            coordinator?.navigateBackward()
        }
        .keyboardShortcut("[", modifiers: .command)
        .disabled(coordinator?.canNavigateBackward != true)

        Button("nav.forward") {
            coordinator?.navigateForward()
        }
        .keyboardShortcut("]", modifiers: .command)
        .disabled(coordinator?.canNavigateForward != true)
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

/// Ends the search field's editing on a click anywhere else in its window.
///
/// SwiftUI's lists and grids take no focus when clicked, so once the toolbar's field had it, from
/// a click or ⌘F, it kept it: Space typed into the field and never reached the Playback menu's
/// Play/Pause. In an AppKit window, the list clicked on would have taken the focus.
func endSearchEditing(onClickOf event: NSEvent) {
    guard let window = event.window,
          let field = (window.firstResponder as? NSText)?.delegate as? NSSearchField,
          !field.bounds.contains(field.convert(event.locationInWindow, from: nil))
    else { return }
    window.makeFirstResponder(nil)
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
