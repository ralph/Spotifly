//
//  LoadMoreRow.swift
//  Spotifly
//
//  The end of a paged list: asks for the next page, or says why it did not come.
//

import SwiftUI

/// A spinner that loads the next page once it scrolls into view, or, once that page has failed,
/// the failure with a Try again, which the network's return presses too. The spinner alone could
/// not ask again: it stays on screen, so its `onAppear` does not fire a second time.
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
                    .onAppear {
                        Task {
                            await loadMore()
                        }
                    }
            }
        }
    }
}
