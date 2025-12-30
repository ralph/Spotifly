//
//  LoggedInView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

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
