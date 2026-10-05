//
//  SpeakersView.swift
//  Spotifly
//
//  View for selecting speakers (Spotify Connect and AirPlay)
//

import SwiftUI

struct SpeakersView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AuthViewModel.self) private var authViewModel
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// Whether AirPlay is available (only when Spotifly is the active device)
    private var isAirPlayEnabled: Bool {
        player.activeDevice?.name == "Spotifly"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("speakers.title")
                    .font(.title2)
                    .bold()
                Spacer()
            }
            .padding()

            Divider()

            // Content
            List {
                // Spotify Connect devices
                Section {
                    if player.devices.isEmpty {
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
                        ForEach(player.devices) { device in
                            SpeakerRow(device: device)
                        }
                    }

                    // Without a usable local player this Mac never registers with
                    // Spotify Connect, so it is genuinely absent from the list above.
                    // That absence is the indicator; this row is the way back.
                    //
                    // Keyed on whether playback actually works, not on whether a
                    // credentials file exists: revoked or stale credentials leave the
                    // file in place while every initialization fails, and keying on the
                    // file would hide the only way to recover from exactly that.
                    if playbackViewModel.localPlayback == .needsAuthorization {
                        // Stays enabled while the grant waits, and cancels it instead of
                        // starting a second one. A browser tab closed without authorizing
                        // sends nothing at all, so without this the row spun until the
                        // listener's timeout with no way back to it.
                        Button {
                            if authViewModel.isAuthorizingStreaming {
                                authViewModel.cancelStreamingAuthorization()
                            } else {
                                authViewModel.startStreamingAuthorization()
                            }
                        } label: {
                            HStack {
                                if authViewModel.isAuthorizingStreaming {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "laptopcomputer.slash")
                                        .foregroundStyle(.secondary)
                                }
                                Text(
                                    authViewModel.isAuthorizingStreaming
                                        ? "speakers.enable_this_mac_cancel"
                                        : "speakers.enable_this_mac",
                                )
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    } else if playbackViewModel.localPlayback == .needsPremium {
                        // Registered hidden, so absent too, and nothing here enables it.
                        Label("speakers.this_mac_needs_premium", systemImage: "laptopcomputer.slash")
                            .foregroundStyle(.secondary)
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
                        Text(isAirPlayEnabled ? "speakers.airplay_hint" : "speakers.airplay_disabled_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                #endif

                // Connection to Spotify: session, dealer and Connect state
                Section {
                    ConnectionStatusView {
                        // Reconnecting re-registers our device, which changes the cluster
                        // and pushes a fresh device list back on its own.
                        await playbackViewModel.forceReinitialize()
                    }
                } header: {
                    Text("speakers.spotify_connection")
                }
            }
            .listStyle(.inset)
            // A `List` takes no content margins on macOS, so it leaves the bar's room itself.
            .safeAreaInset(edge: .bottom) {
                Spacer().frame(height: NowPlayingBarView.contentClearance)
            }
        }
    }
}

struct SpeakerRow: View {
    let device: Device
    @Environment(DeviceService.self) private var deviceService

    var body: some View {
        Button {
            Task {
                _ = await deviceService.transferPlayback(to: device)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceService.deviceIcon(for: device.type))
                    .font(.title3)
                    .foregroundStyle(device.isActive ? .green : .secondary)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(device.isActive ? .body.weight(.semibold) : .body)
                        .foregroundStyle(.primary)

                    HStack(spacing: 4) {
                        Text(device.type)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if device.isActive {
                            Text("metadata.separator")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("speakers.active")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        if let volume = device.volumePercent {
                            Text("metadata.separator")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // "50 %" in German and French.
                            Text(volume.formatted(.percent))
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
