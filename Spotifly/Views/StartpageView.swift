//
//  StartpageView.swift
//  Spotifly
//
//  Startpage with playback controls and track lookup
//

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

struct StartpageView: View {
    let authResult: SpotifyAuthResult
    @Bindable var trackViewModel: TrackLookupViewModel
    @Bindable var playbackViewModel: PlaybackViewModel
    @Bindable var recentlyPlayedViewModel: RecentlyPlayedViewModel
    @Binding var selectedRecentAlbum: SearchAlbum?
    @Binding var selectedRecentArtist: SearchArtist?
    @Binding var selectedRecentPlaylist: SearchPlaylist?
    @Binding var showingAllRecentTracks: Bool

    @State private var versionTapCount = 0
    @State private var showTokenInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Compact Spotify URI Input
                VStack(alignment: .leading, spacing: 8) {
                    Text("playback.play_content")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("playback.uri_placeholder", text: $trackViewModel.spotifyURI)
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

                        Button("action.play") {
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
                        ProgressView("loading.recently_played")
                        Spacer()
                    }
                    .padding()
                } else if let error = recentlyPlayedViewModel.errorMessage {
                    Text(String(format: String(localized: "error.load_recently_played"), error))
                        .foregroundStyle(.red)
                        .padding()
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        // Recently Played Tracks (top 5 with "show more" button)
                        if !recentlyPlayedViewModel.recentTracks.isEmpty {
                            RecentTracksSection(
                                tracks: Array(recentlyPlayedViewModel.recentTracks.prefix(5)),
                                showingAllTracks: $showingAllRecentTracks,
                                selectedRecentAlbum: $selectedRecentAlbum,
                                selectedRecentArtist: $selectedRecentArtist,
                                selectedRecentPlaylist: $selectedRecentPlaylist,
                                authResult: authResult,
                                playbackViewModel: playbackViewModel,
                            )
                        }

                        // Recently Played Content (mixed albums, artists, playlists)
                        if !recentlyPlayedViewModel.recentItems.isEmpty {
                            RecentContentSection(
                                items: recentlyPlayedViewModel.recentItems,
                                selectedAlbum: $selectedRecentAlbum,
                                selectedArtist: $selectedRecentArtist,
                                selectedPlaylist: $selectedRecentPlaylist,
                                showingAllTracks: $showingAllRecentTracks,
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
                        Text(String(format: String(localized: "version.label"), appVersion.split(separator: " ").first.map(String.init) ?? "", appVersion.split(separator: " ").last?.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "") ?? ""))
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
                                .help("action.copy_token")
                            }

                            Text(String(format: String(localized: "version.tap_count"), versionTapCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding()
                        #if os(macOS)
                        .background(Color(NSColor.controlBackgroundColor))
                        #else
                        .background(Color(UIColor.secondarySystemBackground))
                        #endif
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
        .startpageShortcuts(
            recentlyPlayedViewModel: recentlyPlayedViewModel,
            authResult: authResult,
        )
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }

    private func copyTokenToClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(authResult.accessToken, forType: .string)
        #else
        UIPasteboard.general.string = authResult.accessToken
        #endif
    }
}

// MARK: - Recently Played Sections

struct RecentTracksSection: View {
    let tracks: [SearchTrack]
    @Binding var showingAllTracks: Bool
    @Binding var selectedRecentAlbum: SearchAlbum?
    @Binding var selectedRecentArtist: SearchArtist?
    @Binding var selectedRecentPlaylist: SearchPlaylist?
    let authResult: SpotifyAuthResult
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played.tracks")
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

                // Show more button
                Button {
                    showingAllTracks = true
                    selectedRecentAlbum = nil
                    selectedRecentArtist = nil
                    selectedRecentPlaylist = nil
                } label: {
                    HStack {
                        Text("recently_played.show_more")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
            #else
            .background(Color(UIColor.secondarySystemBackground))
            #endif
            .cornerRadius(8)
            .padding(.horizontal)
        }
    }
}

struct RecentContentSection: View {
    let items: [RecentItem]
    @Binding var selectedAlbum: SearchAlbum?
    @Binding var selectedArtist: SearchArtist?
    @Binding var selectedPlaylist: SearchPlaylist?
    @Binding var showingAllTracks: Bool

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
                                selectedArtist = nil
                                selectedPlaylist = nil
                                showingAllTracks = false
                            }

                        case let .artist(artist):
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
                                selectedAlbum = nil
                                selectedPlaylist = nil
                                showingAllTracks = false
                            }

                        case let .playlist(playlist):
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
                                selectedAlbum = nil
                                selectedArtist = nil
                                showingAllTracks = false
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
