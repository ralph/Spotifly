//
//  PartnerAPITests.swift
//  SpotiflyTests
//
//  The pathfinder client: what it sends, and what it makes of what comes back.
//

import Foundation
@testable import Spotifly
import Testing

/// What goes out on the wire.
struct PathfinderRequestTests {
    @Test func `the request names the operation and its stored query, and sends no query text`() throws {
        let encoded = try PartnerAPI.encodeBody(
            .searchTracks,
            variables: PathfinderSearchVariables(searchTerm: "daft punk"),
        )
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(json["operationName"] as? String == "searchTracks")
        // The field selection lives on Spotify's servers; sending a document would be a
        // different API entirely.
        #expect(json["query"] == nil)

        let extensions = try #require(json["extensions"] as? [String: Any])
        let persisted = try #require(extensions["persistedQuery"] as? [String: Any])
        #expect(persisted["version"] as? Int == 1)
        #expect(
            persisted["sha256Hash"] as? String
                == "59ee4a659c32e9ad894a71308207594a65ba67bb6b632b183abe97303a51fa55",
        )
    }

    @Test func `the search term and paging go in the variables`() throws {
        let encoded = try PartnerAPI.encodeBody(
            .searchAlbums,
            variables: PathfinderSearchVariables(searchTerm: "discovery", limit: 5),
        )
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])

        #expect(variables["searchTerm"] as? String == "discovery")
        #expect(variables["limit"] as? Int == 5)
        #expect(variables["offset"] as? Int == 0)
        // The stored query references these; omitting one is an error rather than a default.
        #expect(variables["includePreReleases"] as? Bool == true)
        #expect(variables["includeAudiobooks"] as? Bool == true)
    }

    @Test func `each search operation carries its own hash`() {
        let hashes = Set([
            PathfinderOperation.searchTracks.sha256Hash,
            PathfinderOperation.searchAlbums.sha256Hash,
            PathfinderOperation.searchArtists.sha256Hash,
            PathfinderOperation.searchPlaylists.sha256Hash,
        ])

        #expect(hashes.count == 4)
        #expect(hashes.allSatisfy { $0.count == 64 })
    }

    @Test func `the request carries both tokens and the client's own headers`() async throws {
        let api = partnerAPI(accessToken: "the-bearer", clientToken: "the-client-token") { _ in
            (Data(), httpResponse(200))
        }

        let request = try await api.makeRequest(
            .searchTracks,
            variables: PathfinderSearchVariables(searchTerm: "x"),
        )

        // The bearer alone is a 401 on this host.
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer the-bearer")
        #expect(request.value(forHTTPHeaderField: "Client-Token") == "the-client-token")
        #expect(request.value(forHTTPHeaderField: "App-Platform") == "OSX_ARM64")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://xpui.app.spotify.com")
        #expect(request.httpMethod == "POST")
    }
}

/// What comes back.
struct PathfinderResponseTests {
    private func searchPayload(kind: String, items: String) -> Data {
        Data("""
        {"data":{"searchV2":{"\(kind)":{"totalCount":2,"items":[\(items)]}}}}
        """.utf8)
    }

    @Test func `tracks are read out of the nested item wrappers`() async throws {
        let track = """
        {"item":{"data":{"__typename":"Track","id":"t1","uri":"spotify:track:t1","name":"One More Time",
        "duration":{"totalMilliseconds":320357},"playability":{"playable":true},
        "artists":{"items":[{"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"}}]},
        "albumOfTrack":{"id":"al1","uri":"spotify:album:al1","name":"Discovery",
        "coverArt":{"sources":[{"url":"https://i/small","width":64,"height":64},
        {"url":"https://i/big","width":640,"height":640}]}}}}}
        """

        let api = partnerAPI { _ in (searchPayload(kind: "tracksV2", items: track), httpResponse(200)) }
        let results = try await api.searchTracks("daft punk")

        #expect(results.count == 1)
        let first = try #require(results.first)
        #expect(first.id == "t1")
        #expect(first.name == "One More Time")
        #expect(first.durationMs == 320_357)
        #expect(first.artistNames == ["Daft Punk"])
        #expect(first.albumOfTrack?.name == "Discovery")
        // Largest source, not first.
        #expect(first.albumOfTrack?.coverArt?.largestURL == "https://i/big")
    }

    @Test func `albums derive an id from the uri, since search results carry none`() async throws {
        // items[].data, with no `item` wrapper — unlike tracks. Taken from a live response.
        let album = """
        {"data":{"__typename":"AlbumV2","uri":"spotify:album:al1","name":"Discovery",
        "date":{"year":2001},"artists":{"items":[{"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"}}]},
        "coverArt":{"sources":[{"url":"https://i/big","width":640,"height":640}]}}}
        """

        let api = partnerAPI { _ in (searchPayload(kind: "albumsV2", items: album), httpResponse(200)) }
        let results = try await api.searchAlbums("discovery")

        let first = try #require(results.first)
        // AppStore keys albums by id, so deriving this is not cosmetic.
        #expect(first.id == "al1")
        #expect(first.name == "Discovery")
        #expect(first.date?.year == 2001)
        #expect(first.artistNames == ["Daft Punk"])
    }

    @Test func `artists read their name out of the profile`() async throws {
        let artist = """
        {"data":{"__typename":"Artist","uri":"spotify:artist:a1","profile":{"name":"Daft Punk"},
        "visuals":{"avatarImage":{"sources":[{"url":"https://i/a","width":320,"height":320}]}}}}
        """

        let api = partnerAPI { _ in (searchPayload(kind: "artists", items: artist), httpResponse(200)) }
        let results = try await api.searchArtists("daft")

        let first = try #require(results.first)
        #expect(first.id == "a1")
        #expect(first.name == "Daft Punk")
        #expect(first.imageURL == "https://i/a")
    }

    @Test func `playlists read their owner and image`() async throws {
        let playlist = """
        {"data":{"__typename":"Playlist","uri":"spotify:playlist:p1","name":"Mix",
        "description":"nice","ownerV2":{"data":{"name":"Ralph","username":"ralph"}},
        "images":{"items":[{"sources":[{"url":"https://i/p","width":300,"height":300}]}]}}}
        """

        let api = partnerAPI { _ in (searchPayload(kind: "playlists", items: playlist), httpResponse(200)) }
        let results = try await api.searchPlaylists("mix")

        let first = try #require(results.first)
        #expect(first.id == "p1")
        #expect(first.name == "Mix")
        #expect(first.ownerName == "Ralph")
        #expect(first.imageURL == "https://i/p")
    }

    @Test func `both item shapes decode, because Spotify uses both`() async throws {
        // Measured against the live service: searchTracks nests the entity under an `item`
        // wrapper beside `matchedFields`, while the other three put it at `data` directly.
        // Requiring the wrapper everywhere is what emptied albums, artists and playlists while
        // tracks worked — and the fixtures agreed with the bug, because I wrote both.
        let wrapped = #"{"item":{"data":{"uri":"spotify:track:t1","name":"Wrapped"}},"matchedFields":[]}"#
        let direct = #"{"data":{"uri":"spotify:track:t2","name":"Direct"}}"#

        let api = partnerAPI { _ in
            (searchPayload(kind: "tracksV2", items: "\(wrapped),\(direct)"), httpResponse(200))
        }
        let results = try await api.searchTracks("x")

        #expect(results.map(\.name) == ["Wrapped", "Direct"])
    }

    @Test func `an unreadable item is dropped rather than losing the page`() async throws {
        let items = """
        {"item":{"data":{"uri":"spotify:track:t1","name":"Good"}}},{"item":null},{"nothing":true}
        """

        let api = partnerAPI { _ in (searchPayload(kind: "tracksV2", items: items), httpResponse(200)) }
        let results = try await api.searchTracks("x")

        #expect(results.count == 1)
        #expect(results.first?.name == "Good")
    }

    @Test func `an empty result set is empty, not an error`() async throws {
        let api = partnerAPI { _ in
            (Data(#"{"data":{"searchV2":{"tracksV2":{"totalCount":0,"items":[]}}}}"#.utf8), httpResponse(200))
        }

        #expect(try await api.searchTracks("nothing at all").isEmpty)
    }

    @Test func `a retired persisted query is reported as such`() async throws {
        // The failure this design invites: Spotify ships a new web client and the vendored
        // hash stops resolving. Naming it saves the next person the hunt.
        let api = partnerAPI { _ in
            (
                Data(#"{"errors":[{"message":"PersistedQueryNotFound"}]}"#.utf8),
                httpResponse(200),
            )
        }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
    }

    @Test func `a GraphQL error in a 200 body is still an error`() async throws {
        let api = partnerAPI { _ in
            (Data(#"{"errors":[{"message":"Something broke"}]}"#.utf8), httpResponse(200))
        }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
    }

    @Test func `a non-200 is an error before the body is trusted`() async throws {
        let api = partnerAPI { _ in (Data(), httpResponse(403)) }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
    }
}

/// The client token is cached for as long as Spotify says it is good for, so a token that dies
/// early has to be noticed by the request that it fails.
struct ClientTokenRecoveryTests {
    @Test func `a 401 drops the cached client token and retries once`() async throws {
        let attempts = Tally()
        let rejected = Recorder<String>()
        let payload = Data(#"""
        {"data":{"searchV2":{"tracksV2":{"totalCount":1,
          "items":[{"item":{"data":{"uri":"spotify:track:t1","name":"Good"}}}]}}}}
        """#.utf8)

        let api = partnerAPI(invalidateClientToken: { rejected.record($0) }) { _ in
            attempts.increment()
            return attempts.count == 1
                ? (Data(), httpResponse(401))
                : (payload, httpResponse(200))
        }

        let results = try await api.searchTracks("x")

        #expect(results.first?.name == "Good")
        #expect(attempts.count == 2)
        // Named, not "whatever is cached now": concurrent requests share a token, so a late
        // refusal must not discard the replacement an earlier one already fetched.
        #expect(rejected.values == ["ct"])
    }

    /// One retry, not a loop: a 401 that survives a fresh client token is about the bearer or
    /// the account, and asking again would only spend requests.
    @Test func `a second 401 is reported rather than retried again`() async throws {
        let attempts = Tally()

        let api = partnerAPI(invalidateClientToken: { _ in }) { _ in
            attempts.increment()
            return (Data(), httpResponse(401))
        }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
        #expect(attempts.count == 2)
    }

    @Test func `a status that is not 401 does not touch the client token`() async throws {
        let rejected = Recorder<String>()

        let api = partnerAPI(invalidateClientToken: { rejected.record($0) }) { _ in
            (Data(), httpResponse(500))
        }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
        #expect(rejected.values.isEmpty)
    }
}

/// Walking a playlist that is longer than one page.
struct PathfinderPlaylistPagingTests {
    /// The item shape is the one `PathfinderPlaylistTests` decodes, taken with the probe on
    /// 2026-08-13; only the uid varies, so a page can be assembled at any length.
    private func page(uids: [String], totalCount: Int) -> Data {
        let items = uids.map { uid in
            """
            {"uid":"\(uid)","addedAt":{"isoString":"2026-08-01T09:07:43.167Z"},
             "itemV2":{"__typename":"TrackResponseWrapper","data":{
               "uri":"spotify:track:3CCyVdprlcXui4ZwMw1hNS","name":"I Took A Pill In Ibiza",
               "trackNumber":1,"trackDuration":{"totalMilliseconds":280800},
               "artists":{"items":[{"uri":"spotify:artist:xyz789","profile":{"name":"Mike Posner"}}]}}}}
            """
        }.joined(separator: ",")

        return Data("""
        {"data":{"playlistV2":{"__typename":"Playlist",
          "uri":"spotify:playlist:p1","name":"long",
          "ownerV2":{"data":{"__typename":"User","username":"ralph","name":"Ralph",
                             "uri":"spotify:user:ralph"}},
          "content":{"totalCount":\(totalCount),"items":[\(items)]}}}}
        """.utf8)
    }

    private func offset(of request: URLRequest) throws -> Int {
        let data = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let variables = try #require(json["variables"] as? [String: Any])
        return try #require(variables["offset"] as? Int)
    }

    @Test func `a playlist longer than a page is fetched to the end`() async throws {
        let offsets = Recorder<Int>()
        let api = partnerAPI { request in
            let offset = try offset(of: request)
            offsets.record(offset)
            let uids = (offset ..< min(offset + 2, 5)).map { "uid\($0)" }
            return (page(uids: uids, totalCount: 5), httpResponse(200))
        }

        let playlist = try await api.playlist(id: "p1")

        // Every item, not just the first page — an item the app never saw cannot be removed or
        // reordered, because both name a uid.
        #expect(playlist.content?.items?.compactMap(\.uid) == ["uid0", "uid1", "uid2", "uid3", "uid4"])
        #expect(offsets.values == [0, 2, 4])
        // Read on the first page, and it counts the playlist rather than the page.
        #expect(playlist.content?.totalCount == 5)
    }

    @Test func `a playlist that fits in one page is one request`() async throws {
        let offsets = Recorder<Int>()
        let api = partnerAPI { request in
            try offsets.record(offset(of: request))
            return (page(uids: ["a", "b"], totalCount: 2), httpResponse(200))
        }

        let playlist = try await api.playlist(id: "p1")

        #expect(playlist.content?.items?.count == 2)
        #expect(offsets.values == [0])
    }

    /// A playlist can lose items between requests, and `totalCount` then names a length no
    /// offset reaches. The walk has to end on the empty page rather than asking forever.
    @Test func `a page that adds nothing ends the walk`() async throws {
        let offsets = Recorder<Int>()
        let api = partnerAPI { request in
            let offset = try offset(of: request)
            offsets.record(offset)
            return (page(uids: offset == 0 ? ["a", "b"] : [], totalCount: 500), httpResponse(200))
        }

        let playlist = try await api.playlist(id: "p1")

        #expect(playlist.content?.items?.count == 2)
        #expect(offsets.values == [0, 2])
    }
}

struct SpotifyURITests {
    @Test func `an id is taken from the last component`() {
        #expect(SpotifyURI.id(from: "spotify:track:6rqhFgbbKwnb9MLmUQDhG6") == "6rqhFgbbKwnb9MLmUQDhG6")
        #expect(SpotifyURI.id(from: "spotify:album:al1") == "al1")
    }

    @Test func `something that is not a spotify uri yields nothing`() {
        #expect(SpotifyURI.id(from: "https://open.spotify.com/track/x") == nil)
        #expect(SpotifyURI.id(from: "spotify:track:") == nil)
        #expect(SpotifyURI.id(from: "") == nil)
    }
}
