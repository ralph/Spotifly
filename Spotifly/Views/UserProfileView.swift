//
//  UserProfileView.swift
//  Spotifly
//
//  User profile view showing account info, web profile link, and logout.
//

import SwiftUI

/// The account screen — and the way out of the app.
///
/// **The profile is optional, and logout does not wait for it.** This screen used to require
/// one, and the router drew nothing at all when it was nil, which was survivable only while the
/// profile came from `/me` on the dashboard grant: a broken *streaming* grant left it standing.
/// Since the profile moved to `profileAttributes`, both run on the same grant — so a revoked
/// refresh token emptied this screen and took the logout button with it, and logout is exactly
/// what clears the revoked grant. The app could not be recovered from inside itself.
///
/// Nothing here may depend on a request having succeeded.
struct UserProfileView: View {
    let userProfile: UserProfile?
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile header
                VStack(spacing: 12) {
                    ProfileAvatarView(userProfile: userProfile, size: 96)

                    if let userProfile {
                        Text("profile.logged_in_as \(userProfile.displayName)")
                            .font(.title2.bold())
                    } else {
                        Text("profile.unavailable")
                            .font(.title2.bold())
                        Text("profile.unavailable.description")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 24)

                // Account info
                if let userProfile {
                    GroupBox {
                        VStack(spacing: 0) {
                            profileRow(label: "profile.id", value: userProfile.id)
                        }
                    }
                    .frame(maxWidth: 400)
                }

                // Actions
                VStack(spacing: 12) {
                    if let externalUrl = userProfile?.externalUrl,
                       let url = URL(string: externalUrl)
                    {
                        Link(destination: url) {
                            Label("profile.open_in_spotify", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(role: .destructive, action: onLogout) {
                        Label("auth.logout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("nav.profile")
    }

    private func profileRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
