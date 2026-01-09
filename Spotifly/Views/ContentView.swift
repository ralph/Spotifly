//
//  ContentView.swift
//  Spotifly
//
//  Created by Ralph von der Heyden on 30.12.25.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = AuthViewModel()
    @State private var useCustomClientId: Bool = KeychainManager.loadUseCustomClientId()
    @State private var clientId: String = KeychainManager.loadCustomClientId() ?? ""

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

            Toggle("auth.use_custom_client_id", isOn: $useCustomClientId)
                .toggleStyle(.checkbox)
                .frame(width: 280, alignment: .leading)

            if useCustomClientId {
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
            }

            Button {
                if useCustomClientId, !clientId.isEmpty {
                    try? KeychainManager.saveCustomClientId(clientId)
                }
                try? KeychainManager.saveUseCustomClientId(useCustomClientId)
                viewModel.startOAuth(useCustomClientId: useCustomClientId)
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
            .disabled(viewModel.isAuthenticating || (useCustomClientId && clientId.isEmpty))

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
