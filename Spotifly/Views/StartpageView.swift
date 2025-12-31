//
//  StartpageView.swift
//  Spotifly
//
//  Startpage with playback controls and track lookup
//

import AppKit
import SwiftUI

struct StartpageView: View {
    let authResult: SpotifyAuthResult
    @Bindable var trackViewModel: TrackLookupViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Bindable var recentlyPlayedViewModel: RecentlyPlayedViewModel
    @Binding var selectedRecentAlbum: SearchAlbum?
    @Binding var selectedRecentArtist: SearchArtist?
    @Binding var selectedRecentPlaylist: SearchPlaylist?

    @State private var versionTapCount = 0
    @State private var showTokenInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Compact Spotify URI Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("Play Spotify Content")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("Spotify URI or URL", text: $trackViewModel.spotifyURI)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                if !trackViewModel.spotifyURI.isEmpty {
                                    Task {
                                        await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: authResult.accessToken)
                                    }
                                }
                            }

                        if !trackViewModel.spotifyURI.isEmpty {
                            Button {
                                trackViewModel.clearInput()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Button("Play") {
                            Task {
                                await playbackViewModel.play(uriOrUrl: trackViewModel.spotifyURI, accessToken: authResult.accessToken)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(trackViewModel.spotifyURI.isEmpty || playbackViewModel.isLoading)
                    }

                    if let error = playbackViewModel.errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                Divider()

                // Recently Played Section
                if recentlyPlayedViewModel.isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading recently played...")
                        Spacer()
                    }
                    .padding()
                } else if let error = recentlyPlayedViewModel.errorMessage {
                    Text("Failed to load recently played: \(error)")
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        // Recently Played Tracks
                        if !recentlyPlayedViewModel.recentTracks.isEmpty {
                            RecentTracksSection(
                                tracks: recentlyPlayedViewModel.recentTracks,
                                authResult: authResult,
                                playbackViewModel: playbackViewModel,
                            )
                        }

                        // Recently Played Albums
                        if !recentlyPlayedViewModel.recentAlbums.isEmpty {
                            RecentAlbumsSection(
                                albums: recentlyPlayedViewModel.recentAlbums,
                                selectedAlbum: $selectedRecentAlbum,
                            )
                        }

                        // Recently Played Artists
                        if !recentlyPlayedViewModel.recentArtists.isEmpty {
                            RecentArtistsSection(
                                artists: recentlyPlayedViewModel.recentArtists,
                                selectedArtist: $selectedRecentArtist,
                            )
                        }

                        // Recently Played Playlists
                        if !recentlyPlayedViewModel.recentPlaylists.isEmpty {
                            RecentPlaylistsSection(
                                playlists: recentlyPlayedViewModel.recentPlaylists,
                                selectedPlaylist: $selectedRecentPlaylist,
                            )
                        }
                    }
                }

                // Version Section
                VStack(spacing: 12) {
                    Divider()

                    Button {
                        versionTapCount += 1
                        if versionTapCount >= 7 {
                            showTokenInfo = true
                            // Auto-hide after 10 seconds
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
                            Text("OAuth Access Token")
                                .font(.caption)
                                .fontWeight(.semibold)

                            HStack(spacing: 8) {
                                Text(authResult.accessToken)
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
                                .help("Copy token to clipboard")
                            }

                            Text("Tap count: \(versionTapCount)")
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
        }
        .task {
            await recentlyPlayedViewModel.loadRecentlyPlayed(accessToken: authResult.accessToken)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private func copyTokenToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(authResult.accessToken, forType: .string)
    }
}

// MARK: - Recently Played Sections

struct RecentTracksSection: View {
    let tracks: [SearchTrack]
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played Tracks")
                .font(.headline)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(tracks) { track in
                    TrackRow(
                        track: track.toTrackRowData(),
                        currentlyPlayingURI: playbackViewModel.currentlyPlayingURI,
                        playbackViewModel: playbackViewModel,
                    ) {
                        Task {
                            await playbackViewModel.play(
                                uriOrUrl: track.uri,
                                accessToken: authResult.accessToken,
                            )
                        }
                    }

                    if track.id != tracks.last?.id {
                        Divider()
                            .padding(.leading, 94)
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
}

struct RecentAlbumsSection: View {
    let albums: [SearchAlbum]
    @Binding var selectedAlbum: SearchAlbum?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played Albums")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(albums) { album in
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
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 120, height: 120)
                                            .overlay(
                                                Image(systemName: "music.note")
                                                    .font(.system(size: 40))
                                                    .foregroundStyle(.secondary),
                                            )
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 120, height: 120)
                                    .overlay(
                                        Image(systemName: "music.note")
                                            .font(.system(size: 40))
                                            .foregroundStyle(.secondary),
                                    )
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
                        .onTapGesture {
                            selectedAlbum = album
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct RecentArtistsSection: View {
    let artists: [SearchArtist]
    @Binding var selectedArtist: SearchArtist?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played Artists")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(artists) { artist in
                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 120, height: 120)
                                .overlay(
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 60))
                                        .foregroundStyle(.secondary),
                                )

                            Text(artist.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(2)
                                .frame(width: 120, alignment: .center)
                        }
                        .onTapGesture {
                            selectedArtist = artist
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct RecentPlaylistsSection: View {
    let playlists: [SearchPlaylist]
    @Binding var selectedPlaylist: SearchPlaylist?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played Playlists")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(playlists) { playlist in
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
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.gray.opacity(0.2))
                                            .frame(width: 120, height: 120)
                                            .overlay(
                                                Image(systemName: "music.note.list")
                                                    .font(.system(size: 40))
                                                    .foregroundStyle(.secondary),
                                            )
                                    @unknown default:
                                        EmptyView()
                                    }
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 120, height: 120)
                                    .overlay(
                                        Image(systemName: "music.note.list")
                                            .font(.system(size: 40))
                                            .foregroundStyle(.secondary),
                                    )
                            }

                            Text(playlist.name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .lineLimit(2)
                                .frame(width: 120, alignment: .leading)
                        }
                        .onTapGesture {
                            selectedPlaylist = playlist
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
