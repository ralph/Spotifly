//
//  ContentView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = AuthViewModel()

    var body: some View {
        if viewModel.isLoading {
            ProgressView(String(localized: "auth.loading"))
                .frame(minWidth: 500, minHeight: 400)
        } else if viewModel.isSignedIn {
            LoggedInView(onLogout: { Task { await viewModel.logout() } })
                // Speakers and the play alert both offer the grant again, and it is this view
                // model that runs it.
                .environment(viewModel)
        } else {
            loginView
                .frame(minWidth: 500, minHeight: 400)
        }
    }

    /// The whole login: one authorization, which signs the user in *and* makes this Mac a
    /// playback device.
    ///
    /// It used to be two screens. The first ran an OAuth against a Spotify app the user had to
    /// register themselves, because the Web API would not answer without one; the second ran
    /// this grant, because Spotify lets neither client id do the other's job. Nothing calls the
    /// Web API any more, so the first screen — and the Client ID field on it — has nothing left
    /// to authorize.
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
                .frame(width: 320)

            // Enabled while waiting, where it cancels rather than starting a second grant:
            // a browser tab closed without authorizing sends nothing, so this is the only
            // way back from the wait short of the listener's timeout.
            //
            // No account to compare against yet, so no `expectedAccountId` — at sign-in the
            // account the browser grants *is* the account.
            Button {
                if viewModel.isAuthorizingStreaming {
                    viewModel.cancelStreamingAuthorization()
                } else {
                    viewModel.startStreamingAuthorization()
                }
            } label: {
                HStack {
                    if viewModel.isAuthorizingStreaming {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    }
                    Text(
                        viewModel.isAuthorizingStreaming
                            ? "auth.connect_cancel"
                            : "auth.connect.button",
                    )
                }
                .frame(minWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

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
