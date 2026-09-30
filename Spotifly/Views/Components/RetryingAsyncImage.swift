//
//  RetryingAsyncImage.swift
//  Spotifly
//
//  An AsyncImage that asks again when the network comes back.
//

import SwiftUI

/// `AsyncImage`, loaded again when the network returns if its image has not arrived.
///
/// `AsyncImage` loads its url once for as long as the view keeps its identity. Artwork asked
/// for while the network was down stayed a spinner, its request waiting on a connection that
/// had gone, or a placeholder once it failed, until the view happened to be rebuilt: an album's
/// Try again brought back its tracks, and its cover went on spinning. So every artwork in the
/// app goes through this, which gives the `AsyncImage` a new identity on each of
/// `NetworkMonitor`'s returns. An image that has arrived keeps it, so a return does not make
/// the artwork on screen flash.
struct RetryingAsyncImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var attempt = 0
    @State private var loaded = false

    var body: some View {
        AsyncImage(url: url) { phase in
            content(phase)
                // Follows the phase, a new url's included, which starts over empty.
                .onChange(of: phase.image != nil, initial: true) { _, arrived in
                    loaded = arrived
                }
        }
        .id(attempt)
        .retryingWhenNetworkReturns(if: !loaded) { attempt += 1 }
    }
}
