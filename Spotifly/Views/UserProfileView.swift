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

    @State private var showLogoutConfirmation = false

    /// Spotify's own account page, where subscription, payment and privacy are managed.
    private static let accountURL = URL(string: "https://www.spotify.com/account/overview/")!

    var body: some View {
        Form {
            // Centred over the form, as a header, which has no card behind it: the avatar and
            // the name, or why there is none.
            Section {} header: {
                VStack(spacing: 10) {
                    ProfileAvatarView(userProfile: userProfile, size: 96)

                    if let userProfile {
                        Text(userProfile.displayName)
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
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }

            if let userProfile {
                Section("profile.section.account") {
                    LabeledContent("profile.display_name", value: userProfile.displayName)

                    LabeledContent("profile.id") {
                        HStack(spacing: 6) {
                            Text(verbatim: userProfile.id)
                                .monospaced()
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.copy(userProfile.id)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .named("action.copy")
                        }
                    }

                    if let externalUrl = userProfile.externalUrl, let url = URL(string: externalUrl) {
                        LabeledContent("profile.web") {
                            Link(destination: url) {
                                Text(verbatim: externalUrl.replacing("https://", with: ""))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent("profile.manage_account") {
                    Link(destination: Self.accountURL) {
                        Label("profile.open_in_spotify", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.bordered)
                }

                LabeledContent("profile.app_settings") {
                    SettingsLink {
                        Text("profile.open_settings")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 24) {
                    Text("profile.manage_account.footer")

                    Button("profile.logout", role: .destructive) {
                        showLogoutConfirmation = true
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .playerBarClearance()
        .navigationTitle("nav.profile")
        .confirmationDialog("profile.logout.title", isPresented: $showLogoutConfirmation) {
            Button("auth.logout", role: .destructive, action: onLogout)
        } message: {
            Text("profile.logout.message")
        }
    }
}
