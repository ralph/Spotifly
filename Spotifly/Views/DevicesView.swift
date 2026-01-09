//
//  DevicesView.swift
//  Spotifly
//
//  View for selecting Spotify Connect devices
//

import SwiftUI

struct DevicesView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(DeviceService.self) private var deviceService
    @Environment(ConnectService.self) private var connectService
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("devices.title")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button {
                    Task {
                        let token = await session.validAccessToken()
                        await deviceService.loadDevices(accessToken: token)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(store.devicesIsLoading)
            }
            .padding()

            Divider()

            // Content
            if store.devicesIsLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            } else if let errorMessage = store.devicesErrorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    // Now Playing section
                    if store.isSpotifyConnectActive, let deviceName = store.spotifyConnectDeviceName {
                        Section {
                            HStack(spacing: 12) {
                                // Album art
                                if let artURL = store.currentAlbumArtURL,
                                   let url = URL(string: artURL)
                                {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case let .success(image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 50, height: 50)
                                                .cornerRadius(6)
                                        default:
                                            Image(systemName: "music.note")
                                                .font(.title2)
                                                .frame(width: 50, height: 50)
                                                .background(Color.gray.opacity(0.2))
                                                .cornerRadius(6)
                                        }
                                    }
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.title2)
                                        .frame(width: 50, height: 50)
                                        .background(Color.gray.opacity(0.2))
                                        .cornerRadius(6)
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    if let trackName = store.currentTrackName {
                                        Text(trackName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                    }
                                    if let artistName = store.currentArtistName {
                                        Text(artistName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Image(systemName: "hifispeaker.fill")
                                            .font(.caption2)
                                        Text(deviceName)
                                            .font(.caption)
                                    }
                                    .foregroundStyle(.green)
                                }

                                Spacer()
                            }
                            .padding(.vertical, 4)
                        } header: {
                            Text("devices.now_playing")
                        }
                    }

                    // Audio Output section (AirPlay)
                    #if os(macOS)
                        Section {
                            AirPlayRoutePickerView()
                                .frame(height: 30)
                        } header: {
                            Text("devices.audio_output")
                        } footer: {
                            Text("devices.airplay_hint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    #endif

                    // This Computer (local playback) - only when Connect is active
                    if store.isSpotifyConnectActive {
                        Section {
                            ThisComputerRow(playbackViewModel: playbackViewModel)
                        } header: {
                            Text("devices.this_computer")
                        }
                    }

                    // Spotify Connect devices
                    Section {
                        if store.availableDevices.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "speaker.slash")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("devices.empty")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text("devices.empty_hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        } else {
                            ForEach(store.availableDevices) { device in
                                DeviceRow(device: device)
                            }
                        }
                    } header: {
                        Text("devices.spotify_connect")
                    } footer: {
                        Text("devices.spotify_connect_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            let token = await session.validAccessToken()
            await deviceService.loadDevices(accessToken: token)
        }
    }
}

struct DeviceRow: View {
    let device: Device
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(DeviceService.self) private var deviceService
    @Environment(ConnectService.self) private var connectService

    var body: some View {
        Button {
            Task {
                let token = await session.validAccessToken()
                let success = await deviceService.transferPlayback(to: device, accessToken: token)
                if success {
                    connectService.activateConnect(
                        deviceId: device.id,
                        deviceName: device.name,
                        accessToken: token,
                    )
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceService.deviceIcon(for: device.type))
                    .font(.title3)
                    .foregroundStyle(device.isActive ? .green : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.body)
                        .fontWeight(device.isActive ? .semibold : .regular)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(device.type)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if device.isActive {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("devices.active")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        if let volume = device.volumePercent {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(volume)%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if device.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(device.isRestricted)
        .opacity(device.isRestricted ? 0.5 : 1.0)
    }
}

struct ThisComputerRow: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(ConnectService.self) private var connectService
    @Environment(DeviceService.self) private var deviceService
    @Bindable var playbackViewModel: PlaybackViewModel

    var body: some View {
        Button {
            transferToLocalPlayback()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text("devices.this_computer.name")
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("devices.this_computer.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.left.circle")
                    .foregroundStyle(.green)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func transferToLocalPlayback() {
        guard let currentTrackUri = store.currentTrackId else { return }
        let currentPosition = store.currentPositionMs

        Task {
            let token = await session.validAccessToken()

            // Pause the remote device first
            await connectService.pause(accessToken: token)

            // Deactivate Connect mode
            connectService.deactivateConnect()

            // Start playing locally from the same position
            await playbackViewModel.play(uriOrUrl: currentTrackUri, accessToken: token)

            // Seek to the position we were at
            if currentPosition > 0 {
                try? await Task.sleep(for: .milliseconds(500))
                playbackViewModel.seek(to: currentPosition)
            }

            // Refresh devices list so the UI updates
            await deviceService.loadDevices(accessToken: token)
        }
    }
}
