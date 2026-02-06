//
//  UserProfileView.swift
//  Spotifly
//
//  User profile view showing account info, web profile link, and logout.
//

import SwiftUI

struct UserProfileView: View {
    let userProfile: UserProfile
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Profile header
                VStack(spacing: 12) {
                    ProfileAvatarView(userProfile: userProfile, size: 96)

                    Text("profile.logged_in_as \(userProfile.displayName)")
                        .font(.title2.bold())
                }
                .padding(.top, 24)

                // Account info
                GroupBox {
                    VStack(spacing: 0) {
                        if let email = userProfile.email {
                            profileRow(label: "profile.email", value: email)
                        }
                        if let country = userProfile.country {
                            profileRow(label: "profile.country", value: country)
                        }
                        if let product = userProfile.product {
                            profileRow(label: "profile.subscription", value: product.capitalized)
                        }
                        if let followers = userProfile.followers {
                            profileRow(label: "profile.followers", value: "\(followers)")
                        }
                    }
                }
                .frame(maxWidth: 400)

                // Actions
                VStack(spacing: 12) {
                    if let externalUrl = userProfile.externalUrl,
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
