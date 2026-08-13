//
//  PathfinderHomeTests.swift
//  SpotiflyTests
//
//  What the start page is made of, and the two ways it arrives incomplete.
//

import Foundation
@testable import Spotifly
import Testing

/// Trimmed from a real `home` response taken with the probe on 2026-08-13, keeping the fields
/// the decoders read and one image source per entity. Every value below was returned by
/// Spotify; nothing here is a shape that has not been observed.
///
/// Three sections, chosen because each answers a question:
///
/// - **shorts** — a section with `title: null`, which is a real case rather than a decode
///   failure. Its album is *also* the first entry of Recents, so it doubles as the cross-shelf
///   duplicate.
/// - **generic** — one shelf holding a Playlist, an Album and an Artist together, which is why
///   the item type is decided per entry rather than per section.
/// - **recents** — the `List`, whose entries are traits rather than entities. The third of them
///   is Liked Songs, declared `ENTITY_TYPE_PLAYLIST` under the uri `spotify:collection:tracks`.
private let homeJSON = Data("""
{"data":{"home":{
  "__typename":"HomeResponsePayload",
  "greeting":{"transformedLabel":"Hello there"},
  "sectionContainer":{"sections":{"items":[

    {"uri":"spotify:section:0JQ5DAIiKWzVFULQfUm85Y",
     "data":{"__typename":"HomeShortsSectionData","title":null},
     "sectionItems":{"items":[
       {"content":{"__typename":"AlbumResponseWrapper","data":{
         "__typename":"Album","uri":"spotify:album:0FxrkMU5OkPqOWqwreYyZi","name":"Alive","type":"ALBUM",
         "artists":{"items":[{"uri":"spotify:artist:5PrHzxc3kFm4hIrGNmelpX","profile":{"name":"Rodríguez"}}]},
         "coverArt":{"sources":[{"url":"https://i.scdn.co/image/ab67616d00001e0288840","width":300,"height":300}]}}}}
     ]}},

    {"uri":"spotify:section:0JQ5DAnM3wGh0gz1MXnu4S",
     "data":{"__typename":"HomeGenericSectionData","title":{"transformedLabel":"More like Brian Fallon"}},
     "sectionItems":{"items":[
       {"content":{"__typename":"PlaylistResponseWrapper","data":{
         "__typename":"Playlist","uri":"spotify:playlist:37i9dQZF1E4tSriiPIvBzn","name":"Brian Fallon Radio",
         "description":"With The Horrible Crowes, The Gaslight Anthem, Northcote and more",
         "images":{"items":[{"sources":[{"url":"https://pickasso.spotifycdn.com/image/radio","width":null,"height":null}]}]},
         "ownerV2":{"data":{"name":"Spotify","username":null}}}}},
       {"content":{"__typename":"AlbumResponseWrapper","data":{
         "__typename":"Album","uri":"spotify:album:672R806xxpbATLi7TQauyP","name":"Señor and the Queen - EP","type":"EP",
         "artists":{"items":[{"uri":"spotify:artist:7If8DXZN7mlGdQkLE2FaMo","profile":{"name":"The Gaslight Anthem"}}]},
         "coverArt":{"sources":[{"url":"https://i.scdn.co/image/ab67616d00001e02a1e92","width":300,"height":300}]}}}},
       {"content":{"__typename":"ArtistResponseWrapper","data":{
         "__typename":"Artist","uri":"spotify:artist:7AFLDtQad7jUjgvYfWRyUp","profile":{"name":"The Horrible Crowes"},
         "visuals":{"avatarImage":{"sources":[{"url":"https://i.scdn.co/image/ab6761610000e5eb5a776","width":640,"height":640}]}}}}}
     ]}},

    {"uri":"spotify:section:0JQ5DAroEmF9ANbLaiJ7XR",
     "data":{"__typename":"HomeRecentlyPlayedSectionData","title":{"transformedLabel":"Recents"}},
     "sectionItems":{"items":[
       {"content":{"__typename":"ListResponseWrapper","data":{"__typename":"List","items":{"items":[
         {"entity":{"data":{
           "uri":"spotify:album:0FxrkMU5OkPqOWqwreYyZi",
           "entityTypeTrait":{"type":"ENTITY_TYPE_ALBUM"},
           "identityTrait":{"name":"Alive","contributors":{"items":[
             {"name":"Rodríguez","uri":"spotify:artist:5PrHzxc3kFm4hIrGNmelpX"}]}},
           "visualIdentityTrait":{"squareCoverImage":{"image":{"data":{"sources":[
             {"url":"https://image-cdn-fa.spotifycdn.com/image/ab67616d","maxWidth":300,"maxHeight":300}]}}}}}}},
         {"entity":{"data":{
           "uri":"spotify:playlist:2Cngv8qX0kwH5vwkOY6wdJ",
           "entityTypeTrait":{"type":"ENTITY_TYPE_PLAYLIST"},
           "identityTrait":{"name":"relink-test","contributors":{"items":[
             {"name":"llralphj","uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y"}]}},
           "visualIdentityTrait":{"squareCoverImage":{"image":{"data":{"sources":[
             {"url":"https://image-cdn-ak.spotifycdn.com/image/ab67616d","maxWidth":300,"maxHeight":300}]}}}}}}},
         {"entity":{"data":{
           "uri":"spotify:collection:tracks",
           "entityTypeTrait":{"type":"ENTITY_TYPE_PLAYLIST"},
           "identityTrait":{"name":"Liked Songs","contributors":{"items":[
             {"name":"llralphj","uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y"}]}},
           "visualIdentityTrait":{"squareCoverImage":{"image":{"data":{"sources":[
             {"url":"https://misc.scdn.co/liked-songs/liked-songs-300.png","maxWidth":0,"maxHeight":0}]}}}}}}}
       ]}}}}
     ]}}

  ]}}
}}}
""".utf8)

/// A second real response, from a request four minutes after the one above, carrying both ways
/// an entry arrives unusable — and they are not the same way.
///
/// The first section holds a **tombstone**: Spotify listed a playlist by uri and then answered
/// `data: {"__typename":"NotFound"}` under the playlist wrapper. The second is the Recents
/// shelf, whose `List` resolved to `GenericError` this time and to twenty entities in the
/// response above — so the recents shelf is genuinely intermittent, not conditional on anything
/// the client sends.
private let degradedHomeJSON = Data("""
{"data":{"home":{
  "__typename":"HomeResponsePayload",
  "greeting":{"transformedLabel":"Hello there"},
  "sectionContainer":{"sections":{"items":[
    {"uri":"spotify:section:0JQ5IMCbQBLjJJ1jrATbDm",
     "data":{"__typename":"HomeGenericSectionData","title":{"transformedLabel":"Folk"}},
     "sectionItems":{"items":[
       {"content":{"__typename":"PlaylistResponseWrapper","data":{"__typename":"NotFound"}},
        "data":null,"uri":"spotify:playlist:37i9dQZF1DX9x9vqRxMigR"}
     ]}},
    {"uri":"spotify:section:0JQ5DAroEmF9ANbLaiJ7XR",
     "data":{"__typename":"HomeRecentlyPlayedSectionData","title":{"transformedLabel":"Recents"}},
     "sectionItems":{"items":[
       {"content":{"__typename":"ListResponseWrapper","data":{"__typename":"GenericError"}},
        "data":null,"uri":"spotify:list:recents:main"}
     ]}}
  ]}}
}}}
""".utf8)

/// The whole answer when `sp_t` is left out: HTTP 200, no `errors`, and a page that is an error.
private let genericErrorJSON = Data(#"{"data":{"home":{"__typename":"GenericError"}}}"#.utf8)

private func decodeHome(_ data: Data) throws -> PathfinderHome {
    let response = try JSONDecoder().decode(PathfinderHomeResponse.self, from: data)
    return try #require(response.home)
}

@MainActor
struct PathfinderHomeTests {
    @Test func `the page decodes into shelves of ids`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))

        #expect(page.greeting == "Hello there")
        #expect(page.sections.map(\.title) == [nil, "More like Brian Fallon", "Recents"])
        // The section uri, not its index: Spotify reorders the page between requests, and the
        // uri is what lets SwiftUI recognise a shelf it has already drawn.
        #expect(page.sections.first?.id == "spotify:section:0JQ5DAIiKWzVFULQfUm85Y")
    }

    /// One shelf, three kinds. Deciding the kind per *section* would have collapsed this one.
    @Test func `a shelf can mix albums, playlists and artists`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))
        let mixed = try #require(page.sections.first { $0.title == "More like Brian Fallon" })

        #expect(mixed.items == [
            .playlist("37i9dQZF1E4tSriiPIvBzn"),
            .album("672R806xxpbATLi7TQauyP"),
            .artist("7AFLDtQad7jUjgvYfWRyUp"),
        ])
    }

    @Test func `the entities come with the shelves that index them`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))

        #expect(page.albums.contains { $0.id == "672R806xxpbATLi7TQauyP" && $0.name == "Señor and the Queen - EP" })
        #expect(page.artists.contains { $0.id == "7AFLDtQad7jUjgvYfWRyUp" && $0.name == "The Horrible Crowes" })

        let radio = try #require(page.playlists.first { $0.id == "37i9dQZF1E4tSriiPIvBzn" })
        #expect(radio.ownerName == "Spotify")
        // Spotify sends playlist cover sources with null dimensions, so the variant lands at
        // size 0 — present and usable, which is what the card needs.
        #expect(!radio.images.variants.isEmpty)
    }

    /// The Recents shelf is one entry holding a list, and it has to flatten into the same rows
    /// as every other shelf or it cannot be drawn by the same code.
    @Test func `recents flattens into ordinary shelf items`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))
        let recents = try #require(page.sections.first { $0.title == "Recents" })

        #expect(recents.items == [
            .album("0FxrkMU5OkPqOWqwreYyZi"),
            .playlist("2Cngv8qX0kwH5vwkOY6wdJ"),
        ])

        // The trait shape carries the artist under `contributors`, not under `artists`.
        let album = try #require(page.albums.first { $0.id == "0FxrkMU5OkPqOWqwreYyZi" })
        #expect(album.artistName == "Rodríguez")
        #expect(album.artistId == "5PrHzxc3kFm4hIrGNmelpX")
        // A stub: no release date came with it, so opening it still fetches the real metadata.
        #expect(!album.detailsLoaded)
    }

    /// **The uri decides the kind, not `entityTypeTrait`.** Liked Songs says
    /// `ENTITY_TYPE_PLAYLIST` and is `spotify:collection:tracks`; believing the declaration
    /// would put a row on the start page that opens an empty playlist screen.
    @Test func `liked songs is not a playlist row`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))

        #expect(!page.sections.flatMap(\.items).contains(.playlist("tracks")))
        #expect(!page.playlists.contains { $0.name == "Liked Songs" })
    }

    /// Deduplication is per shelf, not per page: the same album genuinely appears in the shorts
    /// row and in Recents, and dropping the second would blank a row Spotify meant to show.
    @Test func `an entity may appear on two shelves`() throws {
        let page = try HomePage(pathfinder: decodeHome(homeJSON))
        let shelvesWithAlive = page.sections.filter { $0.items.contains(.album("0FxrkMU5OkPqOWqwreYyZi")) }

        #expect(shelvesWithAlive.count == 2)
    }

    /// Both unusable forms, and the same consequence: a heading with nothing under it reads as
    /// a bug, so the shelf goes with its last entry.
    @Test func `a shelf whose entries all fail to resolve is dropped`() throws {
        let page = try HomePage(pathfinder: decodeHome(degradedHomeJSON))

        #expect(page.sections.isEmpty)
        #expect(page.playlists.isEmpty)
    }

    /// The failure this API reports with HTTP 200, no `errors` array, and a body that decodes
    /// perfectly well into a page with no sections.
    @Test func `GenericError is a failure, not an empty page`() throws {
        let home = try decodeHome(genericErrorJSON)

        #expect(home.isError)
        #expect(home.sections.isEmpty)
    }

    @Test func `a real page is not an error`() throws {
        #expect(try !decodeHome(homeJSON).isError)
    }
}

/// What goes out for the start page.
struct PathfinderHomeRequestTests {
    /// **`sp_t` is optional to GraphQL and required in practice.** Sending only the two declared
    /// variables is answered `GenericError`, so the wire body is asserted here rather than the
    /// struct: a field renamed or dropped in encoding would produce an app whose start page is
    /// simply always empty, with nothing in the log to say why.
    @Test func `the variables carry sp_t under its own name`() throws {
        let encoded = try PartnerAPI.encodeBody(
            .home,
            variables: PathfinderHomeVariables(timeZone: "Europe/Berlin", deviceId: "abc123"),
        )
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])

        #expect(variables["timeZone"] as? String == "Europe/Berlin")
        #expect(variables["sp_t"] as? String == "abc123")
        // The only member the enum accepts; a string it does not know is a validation error.
        #expect(variables["homeEndUserIntegration"] as? String == "INTEGRATION_WEB_PLAYER")
        // Not sent: it drops whole shelves rather than trimming them — 3 returned 22 sections
        // where the default returned 31.
        #expect(variables["sectionItemsLimit"] == nil)
    }

    @Test func `profileAttributes sends no variables at all`() throws {
        let encoded = try PartnerAPI.encodeBody(.profileAttributes, variables: EmptyVariables())
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(try #require(json["variables"] as? [String: Any]).isEmpty)
        #expect(json["operationName"] as? String == "profileAttributes")
    }
}

/// What a second refresh does to the first.
///
/// ⌘R on this page usually changes nothing visible — Spotify returns an identical first eleven
/// shelves a second apart — so it invites being pressed again, and again. Six presses in four
/// seconds is a measured number, not a hypothetical.
@MainActor
struct HomeRefreshTests {
    private func api(answering body: Data) -> PartnerAPI {
        PartnerAPI(
            accessToken: { "at" },
            clientToken: { "ct" },
            transport: { _ in
                (body, HTTPURLResponse(
                    url: PartnerAPI.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil,
                )!)
            },
        )
    }

    @Test func `a loaded page is not fetched again unless refreshed`() async {
        let store = AppStore()
        let service = HomeService(store: store, partnerAPI: api(answering: homeJSON))

        await service.loadHome()
        let loaded = store.homeSections

        await service.loadHome()

        #expect(store.hasLoadedHome)
        #expect(store.homeSections == loaded)
        #expect(!store.homeIsLoading)
    }

    // **The supersession guard in `HomeService` is reasoned, not covered here.** The bug it
    // fixes — a cancelled load's teardown clearing the state of the load that replaced it — is
    // only observable while the loser finishes *and* the winner is still in flight, so a test
    // for it has to hold the two apart deliberately. An attempt that raced two `Task`s through
    // an actor gate was withdrawn because it depended on `Task.yield()` landing the scheduler
    // where it was wanted, which is not something to assert on.
    //
    // It was withdrawn under suspicion of hanging the suite, and that suspicion was wrong: the
    // run stalls identically with this file's concurrency removed and with the whole suite
    // excluded, so whatever stalls it is not here. Recorded because the wrong conclusion is the
    // expensive one to inherit.
    //
    // If the guard is ever changed, reach for a deterministic interleaving — the transport
    // itself driving the second load — rather than for `Task.yield()` and hope.

    /// A failure has to reach the screen, since the page has nothing else to say for itself.
    @Test func `a rejected page is reported rather than left blank and silent`() async {
        let store = AppStore()
        let service = HomeService(store: store, partnerAPI: api(answering: genericErrorJSON))

        await service.loadHome()

        #expect(store.homeErrorMessage != nil)
        #expect(!store.hasLoadedHome)
        #expect(!store.homeIsLoading)
    }
}

/// Who the listener is, now that `/me` is gone.
@MainActor
struct PathfinderProfileTests {
    /// Trimmed from a real `profileAttributes` response, 2026-08-13.
    private let profileJSON = Data("""
    {"data":{"me":{"profile":{
      "accountId":"pOTWfwsjEH",
      "avatar":{"sources":[{"height":64,"url":"https://i.scdn.co/image/ab67757000003b8202b7","width":64},
                           {"height":300,"url":"https://i.scdn.co/image/ab6775700000ee8502b7","width":300}]},
      "name":"llralphj","socialHandle":null,
      "uri":"spotify:user:qixixbr0ox6sik6jc6bkv6y6y","username":"qixixbr0ox6sik6jc6bkv6y6y"}}}}
    """.utf8)

    @Test func `the profile carries what the Web API used to`() throws {
        let response = try JSONDecoder().decode(PathfinderProfileResponse.self, from: profileJSON)
        let decoded = try #require(response.profile)
        let profile = try #require(UserProfile(pathfinder: decoded))

        // `username`, not `accountId`: it is the string `/me` returned as `id`, so nothing that
        // stored the old one has to be migrated.
        #expect(profile.id == "qixixbr0ox6sik6jc6bkv6y6y")
        #expect(profile.displayName == "llralphj")
        #expect(profile.uri == "spotify:user:qixixbr0ox6sik6jc6bkv6y6y")
        #expect(profile.imageURL?.absoluteString == "https://i.scdn.co/image/ab6775700000ee8502b7")
        // Constructed, because this response has no `external_urls`.
        #expect(profile.externalUrl == "https://open.spotify.com/user/qixixbr0ox6sik6jc6bkv6y6y")
    }

    @Test func `a profile with no username is no profile`() throws {
        let data = Data(#"{"data":{"me":{"profile":{"name":"Someone"}}}}"#.utf8)
        let response = try JSONDecoder().decode(PathfinderProfileResponse.self, from: data)
        let decoded = try #require(response.profile)

        #expect(UserProfile(pathfinder: decoded) == nil)
    }
}
