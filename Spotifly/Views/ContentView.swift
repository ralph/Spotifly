//
//  ContentView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = AuthViewModel()
    @State private var clientId: String = KeychainManager.loadCustomClientId() ?? ""
    /// Set when the user declines step 2, so the app is reachable without it. Not persisted:
    /// the prompt is worth re-offering next launch, and Speakers carries the same button.
    @State private var didSkipStreamingStep = false

    var body: some View {
        if viewModel.isLoading {
            ProgressView(String(localized: "auth.loading"))
                .frame(minWidth: 500, minHeight: 400)
        } else if let authResult = viewModel.authResult {
            // Step 2 sits between the login and the app: the Web API grant above cannot
            // authorize streaming, because Spotify lets neither client id do the other's
            // job. Skippable — skipping just means this Mac is not a playback device, and
            // Speakers offers the same button later.
            if viewModel.hasStreamingCredentials || didSkipStreamingStep {
                LoggedInView(authResult: authResult, onLogout: { Task { await viewModel.logout() } })
                    // Speakers and the play alert both offer the streaming grant, and it is
                    // this view model that runs it.
                    .environment(viewModel)
            } else {
                enablePlaybackView
                    .frame(minWidth: 500, minHeight: 400)
            }
        } else {
            loginView
                .frame(minWidth: 500, minHeight: 400)
        }
    }

    /// Step 2 of the login: authorize streaming so this Mac can play audio itself.
    private var enablePlaybackView: some View {
        VStack(spacing: 20) {
            Image(systemName: "hifispeaker.and.homepod")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("auth.enable_playback_label")
                .font(.largeTitle)
                .bold()

            Text("auth.enable_playback_note")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 320)

            Button {
                Task { await viewModel.authorizeStreaming() }
            } label: {
                HStack {
                    if viewModel.isAuthorizingStreaming {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }
                    Text(
                        viewModel.isAuthorizingStreaming
                            ? "auth.enable_playback_waiting"
                            : "auth.enable_playback_button",
                    )
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(viewModel.isAuthorizingStreaming)

            Button("auth.enable_playback_skip") {
                didSkipStreamingStep = true
            }
            .buttonStyle(.link)
            .disabled(viewModel.isAuthorizingStreaming)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
    }

    private var loginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("app.name")
                .font(.largeTitle)
                .bold()

            Text("auth.connect.description")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                Text("auth.client_id_label")
                    .font(.headline)

                TextField("auth.client_id_placeholder", text: $clientId)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)

                Link(destination: URL(string: "https://github.com/ralph/homebrew-spotifly?tab=readme-ov-file#setting-up-your-client-id")!) {
                    Text("auth.client_id_help_link")
                        .font(.caption)
                }

                Text("auth.client_id_existing_app_note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 280, alignment: .leading)
            }
            .frame(width: 280, alignment: .leading)

            Button {
                if !clientId.isEmpty {
                    try? KeychainManager.saveCustomClientId(clientId)
                }
                viewModel.startOAuth()
            } label: {
                HStack {
                    if viewModel.isAuthenticating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }
                    Text(viewModel.isAuthenticating ? "auth.authenticating" : "auth.connect.button")
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(viewModel.isAuthenticating || clientId.isEmpty)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
        .environment(WindowState())
}
