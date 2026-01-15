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
    @Environment(NewReleasesService.self) private var newReleasesService

    // Startpage section preferences
    @AppStorage("showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("showRecentlyPlayed") private var showRecentlyPlayed: Bool = true
    @AppStorage("showNewReleases") private var showNewReleases: Bool = true

    /// Whether any section is enabled
    private var hasAnySectionEnabled: Bool {
        showTopArtists || showRecentlyPlayed || showNewReleases
    }

    /// Check if a section is enabled
    private func isSectionEnabled(_ section: StartpageSection) -> Bool {
        switch section {
        case .topArtists: showTopArtists
        case .recentlyPlayed: showRecentlyPlayed
        case .newReleases: showNewReleases
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
                    // Empty state when no sections are enabled
                    emptyStateView
                }
            }
            .padding(.vertical)
        }
        .refreshable {
            let token = await session.validAccessToken()
            if showTopArtists {
                await topItemsService.refreshTopArtists(accessToken: token)
            }
            if showNewReleases {
                await newReleasesService.refresh(accessToken: token)
            }
            if showRecentlyPlayed {
                await recentlyPlayedService.refresh(accessToken: token)
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
        case .newReleases:
            newReleasesSection
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

    @ViewBuilder
    private var topArtistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("startpage.top_artists")
                .font(.headline)
                .padding(.horizontal)

            if store.topArtistsIsLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 160)
            } else if let error = store.topArtistsErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            } else if store.topArtists.isEmpty {
                Text("startpage.top_artists.empty")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.topArtists) { artist in
                            ArtistCard(artist: artist)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - New Releases Section

    @ViewBuilder
    private var newReleasesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("startpage.new_releases")
                .font(.headline)
                .padding(.horizontal)

            if store.newReleasesIsLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 160)
            } else if let error = store.newReleasesErrorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            } else if store.newReleaseAlbums.isEmpty {
                Text("startpage.new_releases.empty")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.newReleaseAlbums) { album in
                            AlbumCard(album: album)
                        }
                    }
                    .padding(.horizontal)
                }
            }
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
