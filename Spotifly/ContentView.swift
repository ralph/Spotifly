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
    
    func startOAuth() {
        isAuthenticating = true
        errorMessage = nil
        
        Task {
            do {
                let result = try await SpotifyAuth.authenticate()
                self.authResult = result
                self.isAuthenticating = false
            } catch {
                self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                self.isAuthenticating = false
            }
        }
    }
    
    func logout() {
        SpotifyAuth.clearAuthResult()
        authResult = nil
    }
}

struct ContentView: View {
    @State private var viewModel = AuthViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .imageScale(.large)
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Spotifly")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            if let result = viewModel.authResult {
                VStack(spacing: 12) {
                    Label("Authenticated!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    
                    GroupBox("Token Info") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Access Token:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(result.accessToken.prefix(50)) + "...")
                                .font(.caption2)
                                .monospaced()
                            
                            Text("Expires in: \(result.expiresIn) seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Button("Logout", role: .destructive) {
                        viewModel.logout()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
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
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
}
