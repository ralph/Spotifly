//
//  StartpageView.swift
//  Spotifly
//
//  Startpage with personalized content sections
//

import AppKit
import SwiftUI

struct StartpageView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(RecentlyPlayedService.self) private var recentlyPlayedService
    @Environment(TopItemsService.self) private var topItemsService
    // Startpage section preferences
    @AppStorage("showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("showRecentlyPlayed") private var showRecentlyPlayed: Bool = true
    @AppStorage("showTopAlbums") private var showTopAlbums: Bool = true
    @AppStorage("topItemsTimeRange") private var topItemsTimeRange: String = TopItemsTimeRange.mediumTerm.rawValue

    /// Parsed time range from AppStorage
    private var timeRange: TopItemsTimeRange {
        TopItemsTimeRange(rawValue: topItemsTimeRange) ?? .mediumTerm
    }

    /// Whether any section is enabled
    private var hasAnySectionEnabled: Bool {
        showTopArtists || showRecentlyPlayed || showTopAlbums
    }

    /// Check if a section is enabled
    private func isSectionEnabled(_ section: StartpageSection) -> Bool {
        switch section {
        case .topArtists: showTopArtists
        case .recentlyPlayed: showRecentlyPlayed
        case .topAlbums: showTopAlbums
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if hasAnySectionEnabled {
                    ForEach(StartpageSection.allCases) { section in
                        if isSectionEnabled(section) {
                            sectionView(for: section)
                        }
                    }
                } else {
                    emptyStateView
                }
            }
            .padding(.vertical)
        }
        .contentMargins(.bottom, 100)
        .refreshable {
            let token = await session.validAccessToken()
            if showTopArtists {
                await topItemsService.refreshTopArtists(accessToken: token, timeRange: timeRange)
            }
            if showRecentlyPlayed {
                await recentlyPlayedService.refresh(accessToken: token)
            }
            if showTopAlbums {
                await topItemsService.refreshTopTracks(accessToken: token, timeRange: timeRange)
            }
        }
    }

    @ViewBuilder
    private func sectionView(for section: StartpageSection) -> some View {
        switch section {
        case .topArtists:
            topArtistsSection
        case .recentlyPlayed:
            recentlyPlayedSection
        case .topAlbums:
            topAlbumsSection
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("startpage.empty")
                .font(.headline)
            Text("startpage.empty.description")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Top Artists Section

    private var topArtistsSection: some View {
        HorizontalCardSection(
            titleKey: "startpage.top_artists",
            items: store.topArtists,
            isLoading: store.topArtistsPagination.isLoading,
            errorMessage: store.topArtistsErrorMessage,
            emptyKey: "startpage.top_artists.empty",
            hasMore: store.topArtistsPagination.hasMore,
            loadMore: {
                let token = await session.validAccessToken()
                await topItemsService.loadMoreTopArtists(accessToken: token, timeRange: timeRange)
            },
        ) { artist in
            ArtistCard(artist: artist)
        }
    }

    // MARK: - Top Albums Section

    private var topAlbumsSection: some View {
        HorizontalCardSection(
            titleKey: "startpage.top_albums",
            items: store.topTrackAlbums,
            isLoading: store.topTrackAlbumsPagination.isLoading,
            errorMessage: store.topTrackAlbumsErrorMessage,
            emptyKey: "startpage.top_albums.empty",
            hasMore: store.topTrackAlbumsPagination.hasMore,
            loadMore: {
                let token = await session.validAccessToken()
                await topItemsService.loadMoreTopTracks(accessToken: token, timeRange: timeRange)
            },
        ) { album in
            AlbumCard(album: album)
        }
    }

    // MARK: - Recently Played Section

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if store.recentlyPlayedIsLoading {
            HStack {
                Spacer()
                ProgressView("loading.recently_played")
                Spacer()
            }
            .padding()
        } else if let error = store.recentlyPlayedErrorMessage {
            Text(String(format: String(localized: "error.load_recently_played"), error))
                .foregroundStyle(.red)
                .padding()
        } else if !store.recentAlbumsAndPlaylists.isEmpty {
            RecentContentSection(items: store.recentAlbumsAndPlaylists)
        }
    }
}

// MARK: - Horizontal Card Section

/// Reusable horizontal scrolling section with loading, error, and empty states.
/// Supports optional pagination via `hasMore` and `loadMore`.
struct HorizontalCardSection<Item: Identifiable, CardContent: View>: View {
    let titleKey: LocalizedStringKey
    let items: [Item]
    let isLoading: Bool
    let errorMessage: String?
    let emptyKey: LocalizedStringKey
    var hasMore: Bool = false
    var loadMore: (() async -> Void)?
    @ViewBuilder let card: (Item) -> CardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titleKey)
                .font(.headline)
                .padding(.horizontal)

            if isLoading, items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 160)
            } else if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            } else if items.isEmpty {
                Text(emptyKey)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(items) { item in
                            card(item)
                        }
                        if hasMore {
                            ProgressView()
                                .frame(width: 120, height: 120)
                                .onAppear {
                                    Task {
                                        await loadMore?()
                                    }
                                }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// MARK: - Recently Played Section

struct RecentContentSection: View {
    let items: [(id: String, album: Album?, playlist: Playlist?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played.content")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items, id: \.id) { item in
                        if let album = item.album {
                            AlbumCard(album: album)
                        } else if let playlist = item.playlist {
                            PlaylistCard(playlist: playlist)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
