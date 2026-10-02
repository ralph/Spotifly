//
//  LoggedInSession.swift
//  Spotifly
//
//  The signed-in account's store and services, for as long as it is signed in.
//

import Foundation

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

/// The session of the account signed in, made the first time a window shows the signed-in app
/// and ended when the account signs out, so the next sign-in starts from an empty store.
///
/// Read from a view's body, so the session itself is not observed: making it there must not
/// count as changing state during an update.
@MainActor
@Observable
final class LoggedInSessions {
    /// The session, if a window has shown the signed-in app; for the menu commands, which have
    /// no window of their own.
    @ObservationIgnored private(set) var current: LoggedInSession?

    /// The current session, made if there is none.
    func session() -> LoggedInSession {
        if let current {
            return current
        }
        let session = LoggedInSession()
        current = session
        return session
    }

    func end() {
        current = nil
    }
}
