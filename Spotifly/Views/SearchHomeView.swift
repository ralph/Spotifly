//
//  SearchHomeView.swift
//  Spotifly
//
//  The search page before a search: recent searches.
//

import SwiftUI

/// The search page with nothing typed: the searches made last, which run again on a click, kept
/// on this Mac only. The toolbar's field takes the focus as it opens.
struct SearchHomeView: View {
    @Environment(SearchService.self) private var searchService
    @Environment(NavigationCoordinator.self) private var navigationCoordinator

    var body: some View {
        Group {
            if searchService.recentSearches.isEmpty {
                ContentUnavailableView(
                    "search.no_recent",
                    systemImage: "magnifyingglass",
                    description: Text("search.no_recent_description"),
                )
            } else {
                Form {
                    Section {
                        ForEach(searchService.recentSearches, id: \.self) { query in
                            HStack {
                                Button {
                                    // The toolbar's field follows the search shown.
                                    Task {
                                        await searchService.search(query: query)
                                        navigationCoordinator.navigateToSearchResults(query: query)
                                    }
                                } label: {
                                    Text(verbatim: query)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    searchService.removeRecentSearch(query)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .named("search.remove_recent")
                            }
                        }
                    } header: {
                        Text("search.recent")
                    } footer: {
                        // Beside the footer, not a row of its own: the form boxes every row.
                        HStack {
                            Text("search.recent_footer")
                            Spacer()
                            Button("search.clear_recent") {
                                searchService.clearRecentSearches()
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .onAppear {
            focusToolbarSearchField()
        }
    }
}
