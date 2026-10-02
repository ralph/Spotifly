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
/// Asks when it appears, and again when the list starts over and when that first page lands
/// (`isLoaded`). A refresh keeps the list showing, so the spinner can stay on screen through it;
/// its ask during the refresh finds the refresh running and does nothing, and without the second
/// ask it would spin there until scrolled away and back. Not keyed on the offset, which changes
/// with every page: the spinner, still laid out as a page lands, would then fetch the one after
/// it too.
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
                    .task(id: pagination.isLoaded) {
                        await loadMore()
                    }
            }
        }
    }
}
