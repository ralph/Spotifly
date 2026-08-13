//
//  PartnerAPITests.swift
//  SpotiflyTests
//
//  The pathfinder client: what it sends, and what it makes of what comes back.
//

import Foundation
@testable import Spotifly
import Testing

private func makeAPI(
    accessToken: String = "at",
    clientToken: String = "ct",
    transport: @escaping PartnerAPI.Transport,
) -> PartnerAPI {
    PartnerAPI(
        accessToken: { accessToken },
        clientToken: { clientToken },
        transport: transport,
    )
}

private func httpResponse(_ status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: PartnerAPI.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// What goes out on the wire.
struct PathfinderRequestTests {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

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
        let api = makeAPI(accessToken: "the-bearer", clientToken: "the-client-token") { _ in
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

        let api = makeAPI { _ in (searchPayload(kind: "tracksV2", items: track), httpResponse(200)) }
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
        let album = """
        {"item":{"data":{"__typename":"AlbumV2","uri":"spotify:album:al1","name":"Discovery",
        "date":{"year":2001},"artists":{"items":[{"uri":"spotify:artist:a1","profile":{"name":"Daft Punk"}}]},
        "coverArt":{"sources":[{"url":"https://i/big","width":640,"height":640}]}}}}
        """

        let api = makeAPI { _ in (searchPayload(kind: "albumsV2", items: album), httpResponse(200)) }
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
        {"item":{"data":{"__typename":"Artist","uri":"spotify:artist:a1","profile":{"name":"Daft Punk"},
        "visuals":{"avatarImage":{"sources":[{"url":"https://i/a","width":320,"height":320}]}}}}}
        """

        let api = makeAPI { _ in (searchPayload(kind: "artists", items: artist), httpResponse(200)) }
        let results = try await api.searchArtists("daft")

        let first = try #require(results.first)
        #expect(first.id == "a1")
        #expect(first.name == "Daft Punk")
        #expect(first.imageURL == "https://i/a")
    }

    @Test func `playlists read their owner and image`() async throws {
        let playlist = """
        {"item":{"data":{"__typename":"Playlist","uri":"spotify:playlist:p1","name":"Mix",
        "description":"nice","ownerV2":{"data":{"name":"Ralph","username":"ralph"}},
        "images":{"items":[{"sources":[{"url":"https://i/p","width":300,"height":300}]}]}}}}
        """

        let api = makeAPI { _ in (searchPayload(kind: "playlists", items: playlist), httpResponse(200)) }
        let results = try await api.searchPlaylists("mix")

        let first = try #require(results.first)
        #expect(first.id == "p1")
        #expect(first.name == "Mix")
        #expect(first.ownerName == "Ralph")
        #expect(first.imageURL == "https://i/p")
    }

    @Test func `an unreadable item is dropped rather than losing the page`() async throws {
        let items = """
        {"item":{"data":{"uri":"spotify:track:t1","name":"Good"}}},{"item":null},{"nothing":true}
        """

        let api = makeAPI { _ in (searchPayload(kind: "tracksV2", items: items), httpResponse(200)) }
        let results = try await api.searchTracks("x")

        #expect(results.count == 1)
        #expect(results.first?.name == "Good")
    }

    @Test func `an empty result set is empty, not an error`() async throws {
        let api = makeAPI { _ in
            (Data(#"{"data":{"searchV2":{"tracksV2":{"totalCount":0,"items":[]}}}}"#.utf8), httpResponse(200))
        }

        #expect(try await api.searchTracks("nothing at all").isEmpty)
    }

    @Test func `a retired persisted query is reported as such`() async throws {
        // The failure this design invites: Spotify ships a new web client and the vendored
        // hash stops resolving. Naming it saves the next person the hunt.
        let api = makeAPI { _ in
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
        let api = makeAPI { _ in
            (Data(#"{"errors":[{"message":"Something broke"}]}"#.utf8), httpResponse(200))
        }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
    }

    @Test func `a non-200 is an error before the body is trusted`() async throws {
        let api = makeAPI { _ in (Data(), httpResponse(401)) }

        await #expect(throws: PartnerAPIError.self) {
            _ = try await api.searchTracks("x")
        }
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
