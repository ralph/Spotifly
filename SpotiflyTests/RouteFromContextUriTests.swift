//
//  RouteFromContextUriTests.swift
//  SpotiflyTests
//
//  The page a context uri opens.
//

import Foundation
@testable import Spotifly
import Testing

@MainActor
struct RouteFromContextUriTests {
    @Test func `an album, an artist and a playlist open their pages`() {
        #expect(Route(contextUri: "spotify:album:a1") == Route(section: .albums, selection: .album(id: "a1")))
        #expect(Route(contextUri: "spotify:artist:r1") == Route(section: .artists, selection: .artist(id: "r1")))
        #expect(Route(contextUri: "spotify:playlist:p1") == Route(section: .playlists, selection: .playlist(id: "p1")))
    }

    @Test func `Liked Songs opens Favorites, not a playlist page`() {
        #expect(Route(contextUri: LikedSongs.uri) == Route(section: .favorites))
    }

    @Test func `a uri with no page opens nothing`() {
        #expect(Route(contextUri: "spotify:station:track:t1") == nil)
        #expect(Route(contextUri: "spotify:user:u:folder:f1") == nil)
        #expect(Route(contextUri: "spotify:album:") == nil)
    }
}
