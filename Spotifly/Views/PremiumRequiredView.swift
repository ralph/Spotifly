//
//  PremiumRequiredView.swift
//  Spotifly
//
//  Shown when the logged-in account does not have Spotify Premium.
//

import SwiftUI

struct PremiumRequiredView: View {
    let displayName: String?
    let onLogout: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)

            Text("premium.required.title")
                .font(.title2.bold())

            if let displayName {
                Text("premium.required.logged_in_as \(displayName)")
                    .foregroundStyle(.secondary)
            }

            Text("premium.required.message")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button(action: onLogout) {
                Text("auth.logout")
                    .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(40)
    }
}
