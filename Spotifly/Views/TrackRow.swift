//
//  TrackRow.swift
//  Spotifly
//
//  Reusable track row component for displaying tracks across different views
//

import SwiftUI

/// Reusable track row view
struct TrackRow: View {
    /// Whether this row is the one playing.
    ///
    /// **Position wins over uri where the list knows both.** A list can legitimately hold the
    /// same recording twice — an album with a reprise, a playlist a track was added to twice,
    /// or two catalogue entries that relink to one market id (see AGENTS.md, "Relinking is
    /// many-to-one") — and matching on uri lights up every one of them. That drew two rows of
    /// an eleven-track queue green while only one of them advanced.
    ///
    /// Only the queue passes `currentIndex`, because only the queue has a current *position*.
    /// An album page or a search result has nothing better than the uri to go on.
    static func isCurrent(
        index: Int?,
        currentIndex: Int?,
        uri: String,
        playingUri: String?,
    ) -> Bool {
        if let index, let currentIndex {
            return index == currentIndex
        }
        return playingUri == uri
    }

    let track: Track
    let showTrackNumber: Bool // Show track number instead of index
    let index: Int? // Optional index for queue
    let isCurrentTrack: Bool
    let isPlayedTrack: Bool // For queue - tracks that have already played
    let provider: TrackProvider? // Optional provider (queue, context, autoplay, unavailable)
    let currentSection: NavigationItem // Current sidebar section (for "Go to" navigation)
    let selectionId: String? // Current selection ID (e.g., playlist ID) for back navigation
    /// Which *occurrence* this row is, where the list knows — only a playlist does.
    ///
    /// `selectionId` names the list and `track` names the song, and between them they still do
    /// not name a row: a playlist can hold the same song twice, and the two rows are equal on
    /// both. The uid is the only thing that tells them apart, which is why removing from the
    /// context menu needs it.
    let itemUid: String?
    let onDoubleTap: (@MainActor () async -> Void)? // Playback action on double-tap

    /// Made once, not in every row's body, so a row hands its artwork the same shape each time
    /// the list redraws.
    private static let artworkShape = AnyShape(.rect(cornerRadius: 4))

    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(AppStore.self) private var store
    @Environment(TrackService.self) private var trackService

    @State private var isTogglingFavorite = false
    @State private var showNewPlaylistDialog = false
    @State private var showPlaylistAddedSuccess = false

    /// Favorite status from the store (single source of truth)
    private var isFavorited: Bool {
        store.isFavorite(track.id)
    }

    /// Provider symbol for display (Q=queue, C=context, A=autoplay, nil for unavailable)
    private var providerSymbol: String? {
        switch provider {
        case .queue: "Q"
        case .context: "C"
        case .autoplay: "A"
        case .unavailable, .none: nil
        }
    }

    /// Whether the row is greyed out: a queue entry the player could not name, or a track
    /// Spotify said it will not play here, as its own clients grey those.
    private var isUnavailable: Bool {
        provider == .unavailable || !track.isPlayable
    }

    init(
        track: Track,
        showTrackNumber: Bool = false,
        index: Int? = nil,
        currentlyPlayingURI: String?,
        currentIndex: Int? = nil,
        provider: TrackProvider? = nil,
        currentSection: NavigationItem = .startpage,
        selectionId: String? = nil,
        itemUid: String? = nil,
        onDoubleTap: (@MainActor () async -> Void)? = nil,
    ) {
        self.track = track
        self.showTrackNumber = showTrackNumber
        self.index = index
        isCurrentTrack = Self.isCurrent(
            index: index,
            currentIndex: currentIndex,
            uri: track.uri,
            playingUri: currentlyPlayingURI,
        )
        isPlayedTrack = if let index, let currentIndex {
            index < currentIndex
        } else {
            false
        }
        self.provider = provider
        self.currentSection = currentSection
        self.selectionId = selectionId
        self.itemUid = itemUid
        self.onDoubleTap = onDoubleTap
    }

    var body: some View {
        HStack(spacing: 12) {
            // Track number, index, or now playing indicator
            ZStack {
                if isCurrentTrack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                } else if showTrackNumber, let trackNumber = track.trackNumber {
                    Text("\(trackNumber)")
                        .foregroundStyle(.secondary)
                } else if let index {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                }
                // Otherwise no number is shown.
            }
            .font(.caption)
            .frame(width: 30, alignment: showTrackNumber ? .trailing : .center)

            // Album art. A track with none leaves the column out rather than show a placeholder.
            if !track.images.isEmpty {
                Artwork(
                    images: track.images,
                    size: 40,
                    shape: Self.artworkShape,
                    symbol: "music.note",
                    symbolFont: .caption,
                )
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(isCurrentTrack ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(isCurrentTrack ? .green : .primary)
                    .lineLimit(1)

                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Provider indicator (Q=queue, C=context, A=autoplay)
            if let symbol = providerSymbol {
                Text(symbol)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            // Duration
            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Heart button (favorite status from store)
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorited ? "heart.fill" : "heart")
                    .font(.caption)
                    .foregroundStyle(isFavorited ? .red : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTogglingFavorite)
            .opacity(isTogglingFavorite ? 0.5 : 1.0)

            // Context menu (3-dot button)
            Menu {
                TrackContextMenu(
                    track: track,
                    currentSection: currentSection,
                    selectionId: selectionId,
                    itemUid: itemUid,
                    showNewPlaylistDialog: $showNewPlaylistDialog,
                    onPlaylistAdded: showSuccessFeedback,
                )
            } label: {
                Image(systemName: showPlaylistAddedSuccess ? "checkmark.circle.fill" : "ellipsis")
                    .font(.caption)
                    .foregroundStyle(showPlaylistAddedSuccess ? .green : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .animation(.easeInOut(duration: 0.2), value: showPlaylistAddedSuccess)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(showPlaylistAddedSuccess)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isCurrentTrack ? Color.green.opacity(0.1) : Color.clear)
        .opacity(isPlayedTrack || isUnavailable ? 0.5 : 1.0)
        .help(track.unplayableMessage ?? "")
        .contentShape(Rectangle())
        .contextMenu {
            TrackContextMenu(
                track: track,
                currentSection: currentSection,
                selectionId: selectionId,
                itemUid: itemUid,
                showNewPlaylistDialog: $showNewPlaylistDialog,
                onPlaylistAdded: showSuccessFeedback,
            )
        }
        .onTapGesture(count: 2) {
            // A track Spotify will not play starts nothing: played, it would only fail with the
            // same message, and search's double-click starts radio, which is refused too.
            if let message = track.unplayableMessage {
                playbackViewModel.errorMessage = message
                return
            }
            guard let onDoubleTap else { return }
            Task { await onDoubleTap() }
        }
        .task(id: track.id) {
            await resolveFavoriteStatusIfNeeded()
        }
        .newPlaylistPrompt(
            isPresented: $showNewPlaylistDialog,
            trackId: track.id,
            onAdded: showSuccessFeedback,
        )
    }

    /// Toggle favorite using TrackService (optimistic update)
    private func toggleFavorite() {
        Task {
            isTogglingFavorite = true

            do {
                try await trackService.toggleFavorite(trackId: track.id)
            } catch {
                playbackViewModel.errorMessage = String(localized: "error.update_favorite \(error.localizedDescription)")
            }

            isTogglingFavorite = false
        }
    }

    private func resolveFavoriteStatusIfNeeded() async {
        await trackService.ensureFavoriteStatuses(trackIds: [track.id])
    }

    private func showSuccessFeedback() {
        showPlaylistAddedSuccess = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            showPlaylistAddedSuccess = false
        }
    }
}

// MARK: - New Playlist Prompt

/// The "New Playlist…" dialog, and the create-then-add behind it.
///
/// Two places offer it — a track row's menu and the now-playing bar's — with the same dialog,
/// the same two calls in the same order and the same failure sink. The name being typed lives
/// here rather than in either host, since neither has any other use for it.
///
/// The checkmark that follows a successful add does *not* live here: it is drawn on the host's
/// own button, and a track row shows it for its right-click menu too. So the host keeps that
/// flag and hands the prompt a way to raise it.
struct NewPlaylistPrompt: ViewModifier {
    @Binding var isPresented: Bool
    /// The track to put in the new playlist — optional because the now-playing bar carries the
    /// prompt whether or not something is playing.
    let trackId: String?
    let onAdded: () -> Void

    @Environment(PlaylistService.self) private var playlistService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var newPlaylistName = ""

    func body(content: Content) -> some View {
        content
            .alert("playlist.new.title", isPresented: $isPresented) {
                TextField("playlist.new.placeholder", text: $newPlaylistName)
                Button("action.cancel", role: .cancel) {
                    newPlaylistName = ""
                }
                Button("action.create") {
                    createAndAddToPlaylist(name: newPlaylistName)
                    newPlaylistName = ""
                }
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("playlist.new.message")
            }
    }

    private func createAndAddToPlaylist(name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, let trackId else { return }

        Task {
            do {
                let newPlaylist = try await playlistService.createPlaylist(name: trimmedName)
                try await playlistService.addTracksToPlaylist(
                    playlistId: newPlaylist.id,
                    trackIds: [trackId],
                )
                onAdded()
            } catch {
                playbackViewModel.errorMessage = String(localized: "error.create_playlist \(error.localizedDescription)")
            }
        }
    }
}

extension View {
    func newPlaylistPrompt(
        isPresented: Binding<Bool>,
        trackId: String?,
        onAdded: @escaping () -> Void,
    ) -> some View {
        modifier(NewPlaylistPrompt(
            isPresented: isPresented,
            trackId: trackId,
            onAdded: onAdded,
        ))
    }
}
