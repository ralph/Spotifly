//
//  PlaylistOutlineTests.swift
//  SpotiflyTests
//
//  The playlists in their folders: loading the tree, and showing it beside the flat list.
//

import Foundation
@testable import Spotifly
import Testing

/// A `libraryV3` page of the unflattened list, each entry a playlist or a folder at a depth,
/// shaped as measured on 2026-09-29.
private func outlinePage(_ entries: [(uri: String, depth: Int)]) -> Data {
    let items = entries.map { entry -> String in
        let folder = entry.uri.contains(":folder:")
        let data = folder
            ? #"{"__typename":"Folder","uri":"\#(entry.uri)","name":"Folder","folderCount":0,"playlistCount":1}"#
            : #"{"__typename":"Playlist","uri":"\#(entry.uri)","name":"\#(entry.uri.suffix(2))"}"#
        return #"{"depth":\#(entry.depth),"item":{"__typename":"\#(folder ? "LibraryFolderResponseWrapper" : "LibraryPlaylistResponseWrapper")","data":\#(data)}}"#
    }
    return Data(#"{"data":{"me":{"libraryV3":{"__typename":"LibraryPage","totalCount":\#(entries.count),"items":[\#(items.joined(separator: ","))]}}}}"#.utf8)
}

private let folder = "spotify:user:someone:folder:48e4423c174bd89d"

/// Answers each outline request by the folders it names, and records them.
private final class OutlineServer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var expandedPerRequest: [[String]] = []
    let answer: ([String]) -> [(uri: String, depth: Int)]

    init(answer: @escaping ([String]) -> [(uri: String, depth: Int)]) {
        self.answer = answer
    }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let variables = try #require(body["variables"] as? [String: Any])
        let expanded = variables["expandedFolders"] as? [String] ?? []
        lock.withLock { expandedPerRequest.append(expanded) }
        #expect(variables["flatten"] as? Bool == false)
        return (outlinePage(answer(expanded)), httpResponse(200))
    }
}

@MainActor
struct PlaylistOutlineLoadingTests {
    /// The top level names the folder, closed; the second pass opens it.
    @Test func `the folders found on one pass are opened on the next`() async throws {
        let server = OutlineServer { expanded in
            expanded.contains(folder)
                ? [("spotify:playlist:p1", 0), (folder, 0), ("spotify:playlist:p3", 1), ("spotify:playlist:p2", 0)]
                : [("spotify:playlist:p1", 0), (folder, 0), ("spotify:playlist:p2", 0)]
        }
        let store = AppStore()
        let service = PlaylistService(store: store, partnerAPI: partnerAPI { try server.respond($0) })

        try await service.loadPlaylistOutline()

        #expect(server.expandedPerRequest == [[], [folder]])
        #expect(store.playlistOutline == [
            PlaylistOutlineRow(item: .playlist(id: "p1"), depth: 0),
            PlaylistOutlineRow(item: .folder(uri: folder, name: "Folder"), depth: 0),
            PlaylistOutlineRow(item: .playlist(id: "p3"), depth: 1),
            PlaylistOutlineRow(item: .playlist(id: "p2"), depth: 0),
        ])
        #expect(store.playlists["p3"] != nil)
    }

    /// An account with no folders costs the one request, and its section stays the flat list.
    @Test func `without folders there is no outline`() async throws {
        let server = OutlineServer { _ in [("spotify:playlist:p1", 0), ("spotify:playlist:p2", 0)] }
        let store = AppStore()
        let service = PlaylistService(store: store, partnerAPI: partnerAPI { try server.respond($0) })

        try await service.loadPlaylistOutline()

        #expect(server.expandedPerRequest == [[]])
        #expect(store.playlistOutline.isEmpty)
    }
}

/// The outline is loaded whole, where the flat list pages as it is scrolled, so it is the
/// section's list, and the library changes made here edit it too.
@MainActor
struct PlaylistOutlineLibraryTests {
    private func store(with rows: [PlaylistOutlineRow]) -> AppStore {
        let store = AppStore()
        store.upsertPlaylists(["p1", "p3"].map { playlist(id: $0) })
        store.setPlaylistOutline(rows)
        return store
    }

    private let rows = [
        PlaylistOutlineRow(item: .playlist(id: "p1"), depth: 0),
        PlaylistOutlineRow(item: .folder(uri: folder, name: "Folder"), depth: 0),
        PlaylistOutlineRow(item: .playlist(id: "p3"), depth: 1),
    ]

    @Test func `a playlist added to the library goes at the top of the outline`() {
        let store = store(with: rows)

        store.addPlaylistToUserLibrary(playlist(id: "new"))
        store.addPlaylistToUserLibraryById("followed")

        #expect(store.playlistOutline.map(\.item.playlistId) == ["followed", "new", "p1", nil, "p3"])
    }

    @Test func `a playlist removed from the library leaves the outline`() {
        let store = store(with: rows)

        store.removePlaylistFromUserLibrary("p3")

        #expect(store.playlistOutline.map(\.item.playlistId) == ["p1", nil])
    }

    /// Without folders there is no outline to keep, and the section is the flat list.
    @Test func `without an outline, a new playlist makes none`() {
        let store = AppStore()

        store.addPlaylistToUserLibrary(playlist(id: "new"))

        #expect(store.playlistOutline.isEmpty)
    }

    @Test func `the section shows the outline's rows, at their depths`() throws {
        let store = store(with: rows)

        let outline = try #require(PlaylistsListView.outline(store.playlistOutline, playlists: store.playlists))

        #expect(outline.map(\.id) == ["p1", folder, "p3"])
        #expect(outline.map(\.depth) == [0, 0, 1])
        #expect(PlaylistsListView.outline([], playlists: store.playlists) == nil)
    }
}
