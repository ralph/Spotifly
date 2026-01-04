//
//  DevicesView.swift
//  Spotifly
//
//  View for selecting audio output devices and Spotify Connect devices
//

import SwiftUI

struct DevicesView: View {
    @Environment(SpotifySession.self) private var session
    @Environment(DevicesViewModel.self) private var viewModel

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
                        await viewModel.loadDevices(accessToken: session.accessToken)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
            .padding()

            Divider()

            // Content
            List {
                #if os(macOS)
                // AirPlay Section
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "airplayaudio")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)

                        Text("devices.airplay_select")
                            .font(.body)

                        Spacer()

                        AirPlayRoutePickerView()
                            .frame(width: 30, height: 30)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("devices.audio_output")
                } footer: {
                    Text("devices.airplay_hint")
                        .font(.caption2)
                }
                #endif

                // Spotify Connect Section
                Section {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if let errorMessage = viewModel.errorMessage {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else if viewModel.devices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "speaker.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("devices.empty")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("devices.empty_hint")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(viewModel.devices) { device in
                            DeviceRow(device: device, viewModel: viewModel)
                        }
                    }
                } header: {
                    Text("devices.spotify_connect")
                } footer: {
                    Text("devices.spotify_connect_hint")
                        .font(.caption2)
                }
            }
            .listStyle(.sidebar)
        }
        .task {
            await viewModel.loadDevices(accessToken: session.accessToken)
        }
    }
}

struct DeviceRow: View {
    let device: SpotifyDevice
    let viewModel: DevicesViewModel
    @Environment(SpotifySession.self) private var session

    var body: some View {
        Button {
            Task {
                await viewModel.transferPlayback(to: device, accessToken: session.accessToken)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: viewModel.deviceIcon(for: device.type))
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
