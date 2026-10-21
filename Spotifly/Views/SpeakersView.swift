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

    /// This Mac's output device, followed while the page shows.
    @State private var outputDeviceName: String?

    /// Whether AirPlay is available: only while this Mac is the active device.
    private var isAirPlayEnabled: Bool {
        player.isPlayingHere
    }

    var body: some View {
        Form {
            Section {
                if player.devices.isEmpty {
                    ContentUnavailableView {
                        Label("speakers.empty", systemImage: "hifispeaker.slash")
                    } description: {
                        Text("speakers.empty_hint")
                    }
                } else {
                    let ownDeviceId = player.ownDeviceId
                    ForEach(player.devices) { device in
                        SpeakerRow(device: device, isThisMac: device.id == ownDeviceId)
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
                                    .controlSize(.small)
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
                        .contentShape(.rect)
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
            }

            // The system's route picker, for this Mac's output, while Spotifly plays here.
            // `plans/open/spotifly-only-airplay.md` puts Spotifly's audio alone behind it.
            Section {
                LabeledContent {
                    AirPlayRoutePickerView()
                        .frame(width: 30, height: 24)
                        .disabled(!isAirPlayEnabled)
                        .opacity(isAirPlayEnabled ? 1 : 0.5)
                } label: {
                    Text("speakers.output_device")
                    if let name = outputDeviceName {
                        Text(verbatim: name)
                    }
                }
            } header: {
                Text("speakers.audio_output")
            } footer: {
                Text(isAirPlayEnabled ? "speakers.airplay_hint" : "speakers.airplay_disabled_hint")
            }

            ConnectionSection {
                // Reconnecting re-registers our device, which changes the cluster
                // and pushes a fresh device list back on its own.
                await playbackViewModel.forceReinitialize()
            }
        }
        .formStyle(.grouped)
        .task {
            for await name in AudioOutputDevice.names() {
                outputDeviceName = name
            }
        }
        .playerBarClearance()
    }
}

/// A Connect device: its symbol on a tile, accent while it plays, its name over its type, and a
/// tick. A click moves playback to it. The active one has its volume under it.
struct SpeakerRow: View {
    let device: Device
    let isThisMac: Bool
    @Environment(DeviceService.self) private var deviceService
    @Environment(PlaybackViewModel.self) private var playbackViewModel

    /// "This Mac" for this Mac, the device's type otherwise.
    private var typeName: String {
        isThisMac
            ? String(localized: "device_type.this_mac")
            : deviceService.deviceTypeName(for: device.type)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    _ = await deviceService.transferPlayback(to: device)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: deviceService.deviceIcon(for: device.type))
                        .font(.system(size: 15))
                        .foregroundStyle(device.isActive ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            device.isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                            in: .rect(cornerRadius: 7),
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                        Group {
                            if device.isActive {
                                Text("speakers.type_active \(typeName)")
                            } else {
                                Text(verbatim: typeName)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if device.isActive {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(device.isRestricted)
            .opacity(device.isRestricted ? 0.5 : 1.0)

            if device.isActive {
                volume
            }
        }
    }

    /// The active device's volume: `PlaybackViewModel.sliderVolume`, this Mac's or the remote
    /// device's, greyed where the device controls its own.
    private var volume: some View {
        let percent = playbackViewModel.sliderVolume
        return Slider(
            value: Binding(
                get: { percent },
                set: { playbackViewModel.setVolumeFromSlider($0) },
            ),
            in: 0 ... 1,
        ) {
            Text("volume.title")
        } minimumValueLabel: {
            // Both labels are one type, so the symbol goes in a `Text` too.
            Text(Image(systemName: "speaker.wave.2.fill"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } maximumValueLabel: {
            Text(percent, format: .percent.precision(.fractionLength(0)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.leading, 40)
        .disabled(playbackViewModel.sliderRefused)
        .help(playbackViewModel.sliderRefused ? Text("volume.device_controls_itself \(device.name)") : Text("volume.title"))
    }
}
