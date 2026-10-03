//
//  LoggedInSession.swift
//  Spotifly
//
//  The signed-in account's store and services, for as long as it is signed in.
//

import SwiftUI

/// The signed-in account's store and services.
///
/// The app owns it, not a window. They were the logged-in view's `@State`, so closing the
/// window freed them while playback and the menus went on: Control Center showed "Spotifly" in
/// place of the next track's title, since `PlaybackViewModel` reads the metadata from the store,
/// and ⌘L did nothing. A window now shows the session and makes nothing of its own but its
/// navigation. See `plans/done/menu-commands-lose-the-session-with-the-window.md`.
@MainActor
final class LoggedInSession {
    let store: AppStore
    let profileService: ProfileService
    let playlistService: PlaylistService
    let albumService: AlbumService
    let artistService: ArtistService
    let trackService: TrackService
    let queueService: QueueService
    let deviceService: DeviceService
    let homeService: HomeService
    let searchService: SearchService

    init() {
        let store = AppStore()
        self.store = store
        profileService = ProfileService(store: store)
        playlistService = PlaylistService(store: store, profileService: profileService)
        albumService = AlbumService(store: store)
        artistService = ArtistService(store: store)
        trackService = TrackService(store: store)
        queueService = QueueService(store: store, trackService: trackService)
        deviceService = DeviceService()
        homeService = HomeService(store: store)
        searchService = SearchService(store: store)
    }
}

/// The session of the account signed in, started when it signs in and ended when it signs out
/// (`AuthViewModel.isSignedIn`), so the next sign-in starts from an empty store.
///
/// Not observed: views follow `isSignedIn`, which is set after the session is started.
@MainActor
final class LoggedInSessions {
    /// The session, while the account is signed in; for the windows, and for the menu
    /// commands, which have no window of their own.
    private(set) var current: LoggedInSession?

    /// The current session, made and started if there is none: its queue service follows the
    /// player from here. A session is made inert (`ActivationRegistry`), so this is what starts
    /// it, and a current session is always a started one.
    @discardableResult
    func start() -> LoggedInSession {
        if let current {
            return current
        }
        let session = LoggedInSession()
        current = session
        session.queueService.activate()
        return session
    }

    func end() {
        current = nil
    }
}

extension View {
    /// The session's store and services, for the views that read them from the environment.
    func environment(session: LoggedInSession) -> some View {
        environment(session.store)
            .environment(session.profileService)
            .environment(session.playlistService)
            .environment(session.albumService)
            .environment(session.artistService)
            .environment(session.trackService)
            .environment(session.queueService)
            .environment(session.deviceService)
            .environment(session.homeService)
            .environment(session.searchService)
    }
}
