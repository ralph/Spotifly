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

    @State private var versionTapCount = 0
    @State private var showTokenInfo = false

    /// Whether any section is enabled
    private var hasAnySectionEnabled: Bool {
        showTopArtists || showRecentlyPlayed || showNewReleases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if hasAnySectionEnabled {
                    // Top Artists Section
                    if showTopArtists {
                        topArtistsSection
                    }

                    // Recently Played (albums and playlists only)
                    if showRecentlyPlayed {
                        recentlyPlayedSection
                    }

                    // New Releases Section
                    if showNewReleases {
                        newReleasesSection
                    }
                } else {
                    // Empty state when no sections are enabled
                    emptyStateView
                }

                // Version Section
                versionSection
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

    /// Filter recent items to only albums and playlists
    private var recentAlbumsAndPlaylists: [RecentItem] {
        store.recentItems.filter { !$0.isArtist }
    }

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
        } else if !recentAlbumsAndPlaylists.isEmpty {
            RecentContentSection(items: recentAlbumsAndPlaylists)
        }
    }

    // MARK: - Version Section

    private var versionSection: some View {
        VStack(spacing: 12) {
            Divider()

            Button {
                versionTapCount += 1
                if versionTapCount >= 7 {
                    showTokenInfo = true
                    Task {
                        try? await Task.sleep(for: .seconds(10))
                        showTokenInfo = false
                        versionTapCount = 0
                    }
                }
            } label: {
                Text("Version \(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            if showTokenInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text("version.oauth_token")
                        .font(.caption)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        Text(session.accessToken)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)

                        Button {
                            copyTokenToClipboard()
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .help("action.copy_token")
                    }

                    Text(String(format: String(localized: "version.tap_count"), versionTapCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
            }
        }
        .padding(.bottom)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private func copyTokenToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.accessToken, forType: .string)
    }
}

// MARK: - Recently Played Section

struct RecentContentSection: View {
    let items: [RecentItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played.content")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        switch item {
                        case let .album(album):
                            AlbumCard(album: album)

                        case let .playlist(playlist):
                            PlaylistCard(playlist: playlist)

                        case .artist:
                            // Artists are filtered out by recentAlbumsAndPlaylists
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
