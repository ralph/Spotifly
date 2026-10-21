//
//  SearchResultsView.swift
//  Spotifly
//
//  A search's results, all kinds a few each or one kind in full.
//

import SwiftUI

/// The results of one search, under the scope picker: "Alle" shows a few of each kind, a single
/// scope all that have loaded and "Mehr laden" for the next page. A scope is a step in the
/// history (`Route.searchScope`).
struct SearchResultsView: View {
    let query: String
    let searchResults: SearchResults
    /// The one kind shown, or nil for all of them a few each.
    let scope: SearchKind?

    @Environment(AppStore.self) private var store
    @Environment(NavigationCoordinator.self) private var navigationCoordinator
    @Environment(TrackService.self) private var trackService
    @Environment(SearchService.self) private var searchService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// How many of each kind "Alle" shows.
    private static let overviewLimit = 5

    /// The ids of a kind the page shows: none outside the scope, a few under "Alle", all of them
    /// under its own scope. Cut before the store lookup, so the rest are not looked up at all.
    private func shown(_ kind: SearchKind) -> ArraySlice<String> {
        let ids = searchResults.ids(for: kind)
        switch scope {
        case nil: return ids.prefix(Self.overviewLimit)
        case kind: return ids[...]
        default: return []
        }
    }

    var body: some View {
        // Each looked up once per redraw. An id the tables no longer hold, such as a playlist
        // deleted since the search, is left out.
        let tracks = shown(.tracks).compactMap { store.tracks[$0] }
        let artists = shown(.artists).compactMap { store.artists[$0] }
        let albums = shown(.albums).compactMap { store.albums[$0] }
        let playlists = shown(.playlists).compactMap { store.playlists[$0] }

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Picker("search.scope", selection: Binding(
                    get: { scope },
                    set: { navigationCoordinator.showSearchScope($0) },
                )) {
                    Text("search.scope.all").tag(SearchKind?.none)
                    ForEach(SearchKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(SearchKind?.some(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 28)
                .padding(.top, 4)

                if tracks.isEmpty, artists.isEmpty, albums.isEmpty, playlists.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "search.no_results \(query)"), systemImage: "magnifyingglass")
                    } description: {
                        Text("search.no_results_description")
                    }
                    .padding(.top, 40)
                }

                if !tracks.isEmpty {
                    SectionHeader(Text(SearchKind.tracks.title))
                    ForEach(tracks.enumerated(), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            index: index,
                            currentlyPlayingURI: playbackViewModel.currentTrackUri,
                            currentSection: .searchResults,
                            onDoubleTap: {
                                await playbackViewModel.playRadio(trackUri: track.uri)
                            },
                        )
                        .padding(.horizontal, 12)
                    }
                }

                if !artists.isEmpty {
                    SectionHeader(Text(SearchKind.artists.title))
                    cards(artists) { ArtistCard(artist: $0, size: 120) }
                }

                if !albums.isEmpty {
                    SectionHeader(Text(SearchKind.albums.title))
                    cards(albums) { AlbumCard(album: $0, size: 140) }
                }

                if !playlists.isEmpty {
                    SectionHeader(Text(SearchKind.playlists.title))
                    cards(playlists) {
                        PlaylistCard(playlist: $0, subtitle: localizedTextString("metadata.by_owner", $0.ownerName), size: 140)
                    }
                }

                if let scope, !searchResults.exhausted.contains(scope) {
                    Button("search.load_more") {
                        Task { await searchService.loadMore(query: query, kind: scope) }
                    }
                    .disabled(searchService.loadingMore.contains(scope))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                }
            }
            .padding(.bottom, 24)
        }
        // On the count: the ids are hashed on every redraw otherwise, and a further page only
        // ever adds to them.
        .task(id: searchResults.trackIds.count) {
            await trackService.ensureFavoriteStatuses(trackIds: searchResults.trackIds)
        }
    }

    /// A row of cards under "Alle", a wrapping grid under the kind's own scope, where there can
    /// be dozens.
    @ViewBuilder
    private func cards<Entity: Identifiable>(_ entities: [Entity], card: @escaping (Entity) -> some View) -> some View {
        if scope == nil {
            CardRow {
                ForEach(entities) { card($0) }
            }
        } else {
            CardGrid {
                ForEach(entities) { card($0) }
            }
        }
    }
}

extension SearchKind {
    /// What the scope picker and its heading call it.
    var title: String {
        switch self {
        case .tracks: String(localized: "search.scope.tracks")
        case .artists: String(localized: "search.scope.artists")
        case .albums: String(localized: "search.scope.albums")
        case .playlists: String(localized: "search.scope.playlists")
        }
    }
}
