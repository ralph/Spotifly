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

    @State private var versionTapCount = 0
    @State private var showTokenInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Top Artists Section
                topArtistsSection

                // Recently Played (albums and playlists only)
                recentlyPlayedSection

                // New Releases Section
                newReleasesSection

                // Version Section
                versionSection
            }
            .padding(.vertical)
        }
        .task {
            let token = await session.validAccessToken()
            async let a: () = topItemsService.loadTopArtists(accessToken: token)
            async let b: () = newReleasesService.loadNewReleases(accessToken: token)
            async let c: () = recentlyPlayedService.loadRecentlyPlayed(accessToken: token)
            _ = await (a, b, c)
        }
        .refreshable {
            let token = await session.validAccessToken()
            await topItemsService.refreshTopArtists(accessToken: token)
            await newReleasesService.refresh(accessToken: token)
            await recentlyPlayedService.refresh(accessToken: token)
        }
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
                            TopArtistCard(artist: artist)
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
                            NewReleaseCard(album: album)
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
        store.recentItems.filter { item in
            switch item {
            case .album, .playlist:
                true
            case .artist:
                false
            }
        }
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

// MARK: - Top Artist Card

private struct TopArtistCard: View {
    let artist: Artist
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            Task {
                let token = await session.validAccessToken()
                navigationCoordinator.navigateToArtist(
                    artistId: artist.id,
                    accessToken: token,
                )
            }
        } label: {
            VStack(spacing: 8) {
                if let imageURL = artist.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        case .failure:
                            artistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    artistPlaceholder
                }

                Text(artist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 120)
            }
        }
        .buttonStyle(.plain)
    }

    private var artistPlaceholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary),
            )
    }
}

// MARK: - New Release Card

private struct NewReleaseCard: View {
    let album: Album
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Button {
            Task {
                let token = await session.validAccessToken()
                navigationCoordinator.navigateToAlbum(
                    albumId: album.id,
                    accessToken: token,
                )
            }
        } label: {
            VStack(spacing: 8) {
                if let imageURL = album.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            albumPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    albumPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var albumPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}

// MARK: - Recently Played Section

struct RecentContentSection: View {
    let items: [RecentItem]
    @Environment(SpotifySession.self) private var session
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

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
                            RecentAlbumCard(album: album) {
                                Task {
                                    let token = await session.validAccessToken()
                                    navigationCoordinator.navigateToAlbum(
                                        albumId: album.id,
                                        accessToken: token,
                                    )
                                }
                            }

                        case let .playlist(playlist):
                            RecentPlaylistCard(playlist: playlist) {
                                navigationCoordinator.navigateToPlaylist(SearchPlaylist(from: playlist))
                            }

                        case .artist:
                            // Artists filtered out at parent level
                            EmptyView()
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Recent Item Cards

private struct RecentAlbumCard: View {
    let album: Album
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let imageURL = album.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            albumPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    albumPlaceholder
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var albumPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}

private struct RecentPlaylistCard: View {
    let playlist: Playlist
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                if let imageURL = playlist.imageURL {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(width: 120, height: 120)
                        case let .success(image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 120)
                                .cornerRadius(4)
                                .shadow(radius: 2)
                        case .failure:
                            playlistPlaceholder
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    playlistPlaceholder
                }

                Text(playlist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var playlistPlaceholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 120, height: 120)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary),
            )
    }
}
