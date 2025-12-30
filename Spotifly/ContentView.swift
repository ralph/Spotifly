//
//  ContentView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

@MainActor
@Observable
final class AuthViewModel {
    var isAuthenticating = false
    var authResult: SpotifyAuthResult?
    var errorMessage: String?
    var isLoading = true

    init() {
        // Try to load existing auth from keychain on init
        loadFromKeychain()
    }

    func loadFromKeychain() {
        isLoading = true
        if let savedResult = KeychainManager.loadAuthResult() {
            authResult = savedResult
        }
        isLoading = false
    }

    func startOAuth() {
        isAuthenticating = true
        errorMessage = nil

        Task {
            do {
                let result = try await SpotifyAuth.authenticate()
                self.authResult = result
                self.isAuthenticating = false

                // Save to keychain
                do {
                    try KeychainManager.saveAuthResult(result)
                } catch {
                    print("Failed to save to keychain: \(error)")
                }
            } catch {
                self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                self.isAuthenticating = false
            }
        }
    }

    func logout() {
        SpotifyAuth.clearAuthResult()
        KeychainManager.clearAuthResult()
        authResult = nil
    }
}

@MainActor
@Observable
final class TrackLookupViewModel {
    var trackURI: String = ""
    var isLoading = false
    var trackMetadata: TrackMetadata?
    var errorMessage: String?

    func clearInput() {
        trackURI = ""
        trackMetadata = nil
        errorMessage = nil
    }

    func lookupTrack(accessToken: String) {
        guard !trackURI.isEmpty else {
            errorMessage = "Please enter a Spotify track URI"
            return
        }

        guard let trackId = SpotifyAPI.parseTrackURI(trackURI) else {
            errorMessage = "Invalid Spotify URI format. Use spotify:track:ID or a Spotify URL"
            return
        }

        isLoading = true
        errorMessage = nil
        trackMetadata = nil

        Task {
            do {
                let metadata = try await SpotifyAPI.fetchTrackMetadata(trackId: trackId, accessToken: accessToken)
                self.trackMetadata = metadata
                self.isLoading = false
            } catch {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

struct ContentView: View {
    @State private var viewModel = AuthViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading...")
            } else if let authResult = viewModel.authResult {
                LoggedInView(authResult: authResult, onLogout: { viewModel.logout() })
            } else {
                loginView
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    @ViewBuilder
    private var loginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Spotifly")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Connect your Spotify account to get started")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.startOAuth()
            } label: {
                HStack {
                    if viewModel.isAuthenticating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }
                    Text(viewModel.isAuthenticating ? "Authenticating..." : "Connect with Spotify")
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(viewModel.isAuthenticating)

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(40)
    }
}

struct LoggedInView: View {
    let authResult: SpotifyAuthResult
    let onLogout: () -> Void

    @State private var trackViewModel = TrackLookupViewModel()

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundStyle(.green)

                Text("Spotifly")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button("Logout", role: .destructive) {
                    onLogout()
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            Divider()

            // Track URI Input
            VStack(alignment: .leading, spacing: 8) {
                Text("Look up a track")
                    .font(.headline)

                HStack {
                    TextField("spotify:track:... or Spotify URL", text: $trackViewModel.trackURI)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            trackViewModel.lookupTrack(accessToken: authResult.accessToken)
                        }

                    Button {
                        trackViewModel.clearInput()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(trackViewModel.trackURI.isEmpty)

                    Button("Submit") {
                        trackViewModel.lookupTrack(accessToken: authResult.accessToken)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(trackViewModel.trackURI.isEmpty || trackViewModel.isLoading)
                }

                if let error = trackViewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal)

            // Track Info Display
            if trackViewModel.isLoading {
                Spacer()
                ProgressView("Loading track info...")
                Spacer()
            } else if let track = trackViewModel.trackMetadata {
                TrackInfoView(track: track)
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Enter a Spotify track URI to see track details")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
    }
}

struct TrackInfoView: View {
    let track: TrackMetadata

    var body: some View {
        VStack(spacing: 16) {
            // Album artwork
            AsyncImage(url: track.albumImageURL) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 200, height: 200)
                case let .success(image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                case .failure:
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                        .frame(width: 200, height: 200)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(8)
                @unknown default:
                    EmptyView()
                }
            }

            // Track info
            VStack(spacing: 4) {
                Text(track.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(track.artistName)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(track.albumName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(track.durationFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            // Track ID for reference
            GroupBox {
                HStack {
                    Text("Track ID:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(track.id)
                        .font(.caption)
                        .monospaced()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("spotify:track:\(track.id)", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Copy track URI")
                }
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
