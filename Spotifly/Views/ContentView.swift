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
        Group {
            if viewModel.isLoading {
                ProgressView(String(localized: "auth.loading"))
                    .frame(minWidth: 500, minHeight: 400)
            } else if let authResult = viewModel.authResult {
                LoggedInView(authResult: authResult, onLogout: { viewModel.logout() })
            } else {
                loginView
                    .frame(minWidth: 500, minHeight: 400)
            }
        }
    }

    @ViewBuilder
    private var loginView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("app.name")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("auth.connect.description")
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
                    Text(viewModel.isAuthenticating ? "auth.authenticating" : "auth.connect.button")
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

#Preview {
    ContentView()
        .environmentObject(WindowState())
}
