//
//  LibraryListView.swift
//  Spotifly
//
//  The shared body of the Albums, Artists and Playlists sections
//

import SwiftUI

/// What a library section needs of an entity in order to list it.
protocol LibraryEntity: Identifiable, Equatable where ID == String {
    var name: String { get }
    var uri: String { get }
    var images: ImageSet { get }
}

// Isolated conformances, because the entities themselves are main-actor isolated
// under the target's default isolation.
extension Album: @MainActor LibraryEntity {}
extension Artist: @MainActor LibraryEntity {}
extension Playlist: @MainActor LibraryEntity {}

/// Everything the three sections show and say differently — the whole of it.
struct LibrarySectionStyle {
    let loadingText: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let emptyTitle: LocalizedStringKey
    let emptyMessage: LocalizedStringKey
    let emptyGlyph: String
    let placeholderGlyph: String
    let artworkShape: AnyShape
}

/// Albums, artists and playlists are listed identically: a loading, error or empty
/// state until there is something to show, then the ephemeral entity the user
/// navigated to, then their library, then the pagination trigger.
///
/// What actually differs is `LibrarySectionStyle` plus the store collection,
/// coordinator route and service calls the section reaches for — so the section
/// passes those in and keeps nothing else of its own.
struct LibraryListView<Entity: LibraryEntity>: View {
    let items: [Entity]
    let ephemeral: Entity?
    let pagination: PaginationState
    let selectedId: String?
    /// Selects an entry. `recordsHistory` is false only for the automatic first selection.
    let select: @MainActor (String, _ recordsHistory: Bool) -> Void
    let load: @MainActor (_ forceRefresh: Bool) async throws -> Void
    let loadMore: @MainActor () async throws -> Void
    let style: LibrarySectionStyle
    let playbackViewModel: PlaybackViewModel

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var errorMessage: String?

    /// Whether we have content to show (either the ephemeral entity or the library)
    private var hasContent: Bool {
        ephemeral != nil || !items.isEmpty
    }

    var body: some View {
        Group {
            if pagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(style.loadingText)
                        .foregroundStyle(.secondary)
                }
            } else if let error = errorMessage, !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(style.errorTitle)
                        .font(.headline)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadItems(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: style.emptyGlyph)
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(style.emptyTitle)
                        .font(.headline)
                    Text(style.emptyMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Back button when navigated from another section
                        if ephemeral != nil, let backTitle = navigationCoordinator.backNavigationTitle {
                            Button {
                                navigationCoordinator.navigateBackward()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.caption.weight(.semibold))
                                    Text("nav.back_to \(backTitle)")
                                        .font(.subheadline)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 8)
                        }

                        // Ephemeral "Currently Viewing" section
                        if let ephemeral {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("nav.currently_viewing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                row(for: ephemeral)
                            }

                            if !items.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)

                                Text("nav.your_library")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                            }
                        }

                        ForEach(items.enumerated(), id: \.element.id) { index, item in
                            VStack(spacing: 0) {
                                row(for: item)

                                if index < items.count - 1 {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }

                        // Load more indicator
                        if pagination.hasMore {
                            ProgressView()
                                .padding()
                                .onAppear {
                                    Task {
                                        await loadMoreItems()
                                    }
                                }
                        }
                    }
                    .padding()
                }
                .refreshable {
                    await loadItems(forceRefresh: true)
                }
            }
        }
        .task {
            if items.isEmpty, !pagination.isLoading {
                await loadItems()
            }
            selectFirstIfNeeded()
        }
        .onChange(of: items) { _, _ in
            selectFirstIfNeeded()
        }
    }

    private func row(for entity: Entity) -> some View {
        LibraryRow(
            entity: entity,
            style: style,
            playbackViewModel: playbackViewModel,
            isSelected: selectedId == entity.id,
            onSelect: {
                select(entity.id, true)
            },
        )
    }

    /// The section always shows a detail, so entering it lands on the first entry. The
    /// coordinator is told at this call site that the step is automatic, so it replaces the
    /// route rather than recording a history entry the user never asked for.
    private func selectFirstIfNeeded() {
        guard selectedId == nil, let first = items.first else { return }
        select(first.id, false)
    }

    private func loadItems(forceRefresh: Bool = false) async {
        errorMessage = nil
        do {
            try await load(forceRefresh)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMoreItems() async {
        do {
            try await loadMore()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct LibraryRow<Entity: LibraryEntity>: View {
    let entity: Entity
    let style: LibrarySectionStyle
    let playbackViewModel: PlaybackViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    private let imageSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            if let url = entity.images.url(for: imageSize, scale: displayScale) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder
                    case let .success(image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: imageSize, height: imageSize)
                            .clipShape(style.artworkShape)
                    case .failure:
                        placeholder
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                placeholder
            }

            Text(entity.name)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .overlay(alignment: .trailing) {
            if isHovering {
                Button {
                    Task {
                        await playbackViewModel.play(uriOrUrl: entity.uri)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var placeholder: some View {
        Image(systemName: style.placeholderGlyph)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
            .frame(width: imageSize, height: imageSize)
            .background(.quaternary)
            .clipShape(style.artworkShape)
    }
}
