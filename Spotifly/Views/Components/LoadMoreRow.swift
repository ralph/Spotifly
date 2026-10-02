//
//  LoadMoreRow.swift
//  Spotifly
//
//  The end of a paged list: asks for the next page, or says why it did not come.
//

import SwiftUI

/// A spinner that loads the next page once it scrolls into view, or, once that page has failed,
/// the failure with a Try again, which the network's return presses too.
///
/// Keyed on the next offset rather than on appearing, because the spinner can stay on screen
/// while that changes: a refresh that keeps the list showing starts over from the first page,
/// and the spinner's ask during it finds the refresh running and does nothing. Once the first
/// page lands, the new offset asks again.
struct LoadMoreRow: View {
    let pagination: PaginationState
    let loadMore: () async -> Void

    var body: some View {
        if pagination.hasMore {
            if let failure = pagination.failure {
                InlineLoadError(failure: failure, retry: loadMore)
            } else {
                ProgressView()
                    .padding()
                    .task(id: pagination.nextOffset) {
                        await loadMore()
                    }
            }
        }
    }
}
