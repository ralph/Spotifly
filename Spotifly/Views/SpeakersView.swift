//
//  SpeakersView.swift
//  Spotifly
//
//  View for selecting speakers (Spotify Connect and AirPlay)
//

import SwiftUI

struct SpeakersView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(AppStore.self) private var store
    @Environment(DeviceService.self) private var deviceService
    @Environment(ConnectService.self) private var connectService
    @Bindable var playbackViewModel: PlaybackViewModel

    @AppStorage("showSpotifyConnectSpeakers") private var showConnectSpeakers: Bool = false
    @AppStorage("showAirPlaySpeakers") private var showAirPlaySpeakers: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("speakers.title")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                if showConnectSpeakers {
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
            }
            .padding()

            Divider()

            // Content
            if showConnectSpeakers, store.devicesIsLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            } else if showConnectSpeakers, let errorMessage = store.devicesErrorMessage {
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
                    // Now Playing section (only when Connect is active)
                    if showConnectSpeakers, store.isSpotifyConnectActive,
                       let deviceName = store.spotifyConnectDeviceName
                    {
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
                            Text("speakers.now_playing")
                        }
                    }

                    // This Computer (local playback) - only when Connect is active on a REMOTE device
                    // Don't show when Spotifly itself is the active device (we're already here)
                    if showConnectSpeakers, store.isSpotifyConnectActive,
                       store.spotifyConnectDeviceName != "Spotifly"
                    {
                        Section {
                            ThisComputerRow(playbackViewModel: playbackViewModel)
                        } header: {
                            Text("speakers.this_computer")
                        }
                    }

                    // Spotify Connect devices (before AirPlay)
                    if showConnectSpeakers {
                        Section {
                            if store.availableDevices.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "speaker.slash")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                    Text("speakers.empty")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text("speakers.empty_hint")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                            } else {
                                ForEach(store.availableDevices) { device in
                                    SpeakerRow(device: device)
                                }
                            }
                        } header: {
                            Text("speakers.spotify_connect")
                        } footer: {
                            Text("speakers.spotify_connect_hint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Audio Output section (AirPlay) - after Spotify Connect
                    #if os(macOS)
                        if showAirPlaySpeakers {
                            Section {
                                AirPlayRoutePickerView()
                                    .frame(height: 30)
                            } header: {
                                Text("speakers.audio_output")
                            } footer: {
                                Text("speakers.airplay_hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    #endif
                }
                .listStyle(.inset)
            }
        }
        .task {
            if showConnectSpeakers {
                let token = await session.validAccessToken()
                await deviceService.loadDevices(accessToken: token)
            }
        }
    }
}

struct SpeakerRow: View {
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
                            Text("speakers.active")
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
                    Text("speakers.this_computer.name")
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("speakers.this_computer.hint")
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
        Task {
            let token = await session.validAccessToken()
            await connectService.transferToLocal(playbackViewModel: playbackViewModel, accessToken: token)
            // Refresh devices list so the UI updates
            await deviceService.loadDevices(accessToken: token)
        }
    }
}
