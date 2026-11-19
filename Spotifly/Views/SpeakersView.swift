//
//  SpeakersView.swift
//  Spotifly
//
//  View for selecting the Spotify Connect device that plays
//

import SwiftUI

struct SpeakersView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(PlaybackViewModel.self) private var playbackViewModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SoloistEngine.setUpKey) private var soloistIsSetUp = false

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
                    let thisMacId = player.thisMacDeviceId
                    ForEach(player.devices) { device in
                        SpeakerRow(device: device, isThisMac: device.id == thisMacId)
                    }
                }

                // Soloist is what this Mac plays with, so without it this Mac is absent from
                // the list above: the session's own device registers hidden. That absence is
                // the indicator; this row is the way to Settings, where it is set up.
                if !soloistIsSetUp {
                    Button {
                        openSettings()
                    } label: {
                        HStack {
                            Image(systemName: "laptopcomputer.slash")
                                .foregroundStyle(.secondary)
                            Text("speakers.set_up_soloist")
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("speakers.spotify_connect")
            } footer: {
                Text("speakers.spotify_connect_hint")
            }

            ConnectionSection {
                // Reconnecting re-registers our device, which changes the cluster
                // and pushes a fresh device list back on its own.
                await playbackViewModel.forceReinitialize()
            }
        }
        .formStyle(.grouped)
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

    /// The active device's volume: `PlaybackViewModel.sliderVolume`, greyed where the device
    /// controls its own.
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
