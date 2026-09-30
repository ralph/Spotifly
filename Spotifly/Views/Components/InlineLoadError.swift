//
//  InlineLoadError.swift
//  Spotifly
//
//  Failure message with a retry, for a whole detail view or one section of it.
//

import SwiftUI

/// Used both for a detail view that has nothing to show and for one whose
/// *contents* failed while its header did not — an album whose track list did not
/// arrive, an artist whose discography did not.
///
/// The section case used to have no way out: the full-page error branch is
/// unreachable once the entity itself is in the store, so the section showed bare
/// red text, or in the artist's case nothing at all, and the only retry was
/// navigating away and back.
struct InlineLoadError: View {
    let failure: LoadFailure
    let retry: () async -> Void

    private let network = NetworkMonitor.shared

    var body: some View {
        VStack(spacing: 8) {
            Text(failure.message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            if failure.canRetry {
                Button("action.try_again") {
                    Task { await retry() }
                }
            }
        }
        .padding()
        // A load that failed while the network was away is asked for again when it returns,
        // as its artwork is, rather than waiting for Try again.
        .onChange(of: network.returns) {
            if let retry {
                Task { await retry() }
            }
        }
    }
}

/// What a detail page says went wrong, and whether its Try again could end differently.
struct LoadFailure {
    let message: String
    /// False where asking again gets the same answer, as for an album Spotify has none of: the
    /// button would only ever fail again. See `isRetryable(_:)`.
    let canRetry: Bool

    /// A load that failed.
    init(_ error: Error) {
        message = error.localizedDescription
        canRetry = isRetryable(error)
    }

    /// An action on the page that failed, such as a rename. Try again reloads the page, which
    /// is what brings its contents back after the message took their place.
    init(message: String) {
        self.message = message
        canRetry = true
    }
}
