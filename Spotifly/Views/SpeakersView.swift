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
    @Bindable var playbackViewModel: PlaybackViewModel

    /// Whether AirPlay is available (only when Spotifly is the active device)
    private var isAirPlayEnabled: Bool {
        store.activeDevice?.name == "Spotifly"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("speakers.title")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
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
                    // Spotify Connect devices
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

                    // Audio Output section (AirPlay) - only enabled when Spotifly is active
                    #if os(macOS)
                        Section {
                            AirPlayRoutePickerView()
                                .frame(height: 30)
                                .disabled(!isAirPlayEnabled)
                                .opacity(isAirPlayEnabled ? 1.0 : 0.5)
                        } header: {
                            Text("speakers.audio_output")
                        } footer: {
                            if isAirPlayEnabled {
                                Text("speakers.airplay_hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("speakers.airplay_disabled_hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    #endif

                    // Librespot Connection Status
                    Section {
                        ConnectionStatusView {
                            let token = await session.validAccessToken()
                            await playbackViewModel.forceReinitialize(accessToken: token)
                        }
                    } header: {
                        Text("speakers.librespot_connection")
                    }
                }
                .listStyle(.inset)
                .safeAreaInset(edge: .bottom) {
                    Spacer().frame(height: 80)
                }
            }
        }
        .task {
            let token = await session.validAccessToken()
            await deviceService.loadDevices(accessToken: token)
        }
    }
}

struct SpeakerRow: View {
    let device: Device
    @Environment(SpotifySession.self) private var session
    @Environment(DeviceService.self) private var deviceService

    var body: some View {
        Button {
            Task {
                let token = await session.validAccessToken()
                _ = await deviceService.transferPlayback(to: device, accessToken: token)
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
