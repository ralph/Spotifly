//
//  UserNotWhitelistedView.swift
//  Spotifly
//
//  Shown when the logged-in user is not allowlisted for the Spotify app.
//

import SwiftUI

struct UserNotWhitelistedView: View {
    let clientId: String
    let onLogout: () -> Void

    private var dashboardURL: URL? {
        URL(string: "https://developer.spotify.com/dashboard/\(clientId)/users")
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 48))
                .foregroundStyle(.red)

            Text("whitelist.title")
                .font(.title2.bold())

            Text("whitelist.message")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("whitelist.steps")
                        .font(.headline)

                    Text("whitelist.step1 \(clientId)")

                    if let url = dashboardURL {
                        Link(destination: url) {
                            Text("whitelist.open_dashboard")
                        }
                    }

                    Text("whitelist.step2")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            .frame(maxWidth: 450)

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
