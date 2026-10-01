//
//  RetryingAsyncImage.swift
//  Spotifly
//
//  An AsyncImage that asks again when the network comes back, and a few times after it failed.
//

import SwiftUI

/// `AsyncImage`, loaded again when the network returns if its image has not arrived, and a few
/// times after a failure the network never noticed.
///
/// `AsyncImage` loads its url once for as long as the view keeps its identity. Artwork asked
/// for while the network was down stayed a spinner, its request waiting on a connection that
/// had gone, or a placeholder once it failed, until the view happened to be rebuilt: an album's
/// Try again brought back its tracks, and its cover went on spinning. So every artwork in the
/// app goes through this, which gives the `AsyncImage` a new identity on each of
/// `NetworkMonitor`'s returns. An image that has arrived keeps it, so a return does not make
/// the artwork on screen flash.
///
/// **A failure while the network stays up**, a CDN's 5xx or a captive portal, counts no return.
/// So a failed image is also asked for again after `retryPauses`, and then left, until the
/// network returns or its url changes: one the CDN answers 404 for would fail every time.
struct RetryingAsyncImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    /// The pauses before a failed image is asked for again, one per retry.
    static var retryPauses: [Duration] {
        [.seconds(5), .seconds(30), .seconds(180)]
    }

    @State private var attempt = 0
    @State private var loaded = false
    @State private var failed = false
    /// The retries after a failure so far, for this url since the network last returned.
    @State private var retries = 0

    var body: some View {
        AsyncImage(url: url) { phase in
            content(phase)
                // Follows the phase, a new url's included, which starts over empty.
                .onChange(of: phase.image != nil, initial: true) { _, arrived in
                    loaded = arrived
                }
                .onChange(of: phase.error != nil, initial: true) { _, isFailure in
                    failed = isFailure
                }
        }
        .id(attempt)
        .retryingWhenNetworkReturns(if: !loaded) {
            retries = 0
            attempt += 1
        }
        .task(id: failed) {
            guard failed, retries < Self.retryPauses.count else { return }
            // Cancelled when the image arrives, or the view goes.
            guard await (try? Task.sleep(for: Self.retryPauses[retries])) != nil else { return }
            retries += 1
            attempt += 1
        }
        .onChange(of: url) { retries = 0 }
    }
}
