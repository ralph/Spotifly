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
    /// The column's own filter field's prompt.
    let filterPrompt: LocalizedStringKey
    /// The row's second line, under the name, where the kind has one.
    var subtitle: (Entity) -> String? = { _ in nil }

    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    @State private var filter = ""

    /// The loaded entries the filter leaves, by name and second line.
    private var filteredItems: [Entity] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.localizedStandardContains(query) || (subtitle($0)?.localizedStandardContains(query) ?? false)
        }
    }

    /// Whether we have content to show (either the ephemeral entity or the library)
    private var hasContent: Bool {
        ephemeral != nil || !items.isEmpty
    }

    var body: some View {
        // A ZStack, not a Group: a Group hands its `.task` to each branch, so switching
        // between loading and the error started the load again, forever.
        ZStack {
            if pagination.isLoading, !hasContent {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(style.loadingText)
                        .foregroundStyle(.secondary)
                }
            } else if let failure = pagination.failure, !hasContent {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(style.errorTitle)
                        .font(.headline)
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("action.try_again") {
                        Task {
                            await loadItems(forceRefresh: true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .retryingWhenNetworkReturns {
                        await loadItems(forceRefresh: true)
                    }
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
                VStack(spacing: 0) {
                    TextField(filterPrompt, text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

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

                            let shown = filteredItems
                            ForEach(shown) { item in
                                row(for: item)
                            }

                            if shown.isEmpty {
                                ContentUnavailableView.search(text: filter)
                            } else if filter.isEmpty {
                                LoadMoreRow(pagination: pagination, loadMore: loadMoreItems)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                    .refreshable {
                        await loadItems(forceRefresh: true)
                    }
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
            subtitle: subtitle(entity),
            style: style,
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

    /// A failure is recorded on `pagination`, where the toolbar's refresh leaves it too.
    private func loadItems(forceRefresh: Bool = false) async {
        try? await load(forceRefresh)
    }

    private func loadMoreItems() async {
        try? await loadMore()
    }
}

private struct LibraryRow<Entity: LibraryEntity>: View {
    let entity: Entity
    let subtitle: String?
    let style: LibrarySectionStyle
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(PlaybackViewModel.self) private var playbackViewModel

    @State private var isHovering = false

    /// A button, so accessibility can press it as a click selects it: a tap gesture announced
    /// nothing and could not be pressed. Play, which shows only under the pointer, is one of the
    /// row's actions too.
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Artwork(
                    images: entity.images,
                    size: 36,
                    shape: style.artworkShape,
                    symbol: style.placeholderGlyph,
                    symbolFont: .system(size: 16),
                    placeholderWhileLoading: true,
                )

                VStack(alignment: .leading, spacing: 1) {
                    Text(entity.name)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("action.play"), play)
        .overlay(alignment: .trailing) {
            if isHovering {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .disabled(playbackViewModel.isLoading)
                .named("action.play")
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private func play() {
        Task {
            await playbackViewModel.play(uriOrUrl: entity.uri)
        }
    }
}
