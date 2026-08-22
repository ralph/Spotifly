//
//  TestEntities.swift
//  SpotiflyTests
//
//  Store entities built to order, for the tests that need something *in* the store rather than
//  something decoded off the wire. Anything checking how a Spotify response becomes an entity
//  builds it from a recorded fixture instead.
//
//  `@MainActor` because the entities are: the app target defaults to main-actor isolation and
//  this one does not.
//

@testable import Spotifly

@MainActor
func track(id: String) -> Track {
    Track(
        id: id,
        name: "Track \(id)",
        uri: "spotify:track:\(id)",
        durationMs: 180_000,
        trackNumber: 1,
        externalUrl: nil,
        albumId: "album",
        artistId: "artist",
        artistName: "Artist",
        albumName: "Album",
        images: .empty,
    )
}

@MainActor
func album(
    id: String,
    name: String = "Album",
    releaseDate: String? = nil,
    albumType: String? = "album",
    externalUrl: String? = nil,
    artistId: String? = nil,
    artistName: String = "Artist",
    detailsLoaded: Bool = true,
) -> Album {
    Album(
        id: id,
        name: name,
        uri: "spotify:album:\(id)",
        images: .empty,
        releaseDate: releaseDate,
        albumType: albumType,
        externalUrl: externalUrl,
        artistId: artistId,
        artistName: artistName,
        detailsLoaded: detailsLoaded,
    )
}

@MainActor
func artist(id: String, name: String) -> Artist {
    Artist(
        id: id,
        name: name,
        uri: "spotify:artist:\(id)",
        images: .empty,
        externalUrl: nil,
    )
}

@MainActor
func playlist(id: String) -> Playlist {
    Playlist(
        id: id,
        name: "Playlist",
        description: nil,
        images: .empty,
        uri: "spotify:playlist:\(id)",
        isPublic: true,
        ownerId: "owner",
        ownerName: "Owner",
    )
}
