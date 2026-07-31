//
//  InlineLoadError.swift
//  Spotifly
//
//  Failure message with a retry, for one section of a view that otherwise loaded.
//

import SwiftUI

/// Shown where a detail view's *contents* failed but its header did not — an
/// album whose track list did not arrive, an artist whose discography did not.
///
/// Those cases used to have no way out: the full-page error branch is unreachable
/// once the entity itself is in the store, so the section showed bare red text, or
/// in the artist's case nothing at all, and the only retry was navigating away and
/// back.
struct InlineLoadError: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Button("action.try_again") {
                Task { await retry() }
            }
        }
        .padding()
    }
}
