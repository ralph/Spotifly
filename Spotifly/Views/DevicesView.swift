//
//  DevicesView.swift
//  Spotifly
//
//  View for selecting Spotify Connect devices
//

import SwiftUI

struct DevicesView: View {
    let authResult: SpotifyAuthResult
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
                        await viewModel.loadDevices(accessToken: authResult.accessToken)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
            .padding()

            Divider()

            // Content
            if viewModel.isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Spacer()
            } else if let errorMessage = viewModel.errorMessage {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if viewModel.devices.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("devices.empty")
                        .foregroundStyle(.secondary)
                    Text("devices.empty_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                List {
                    ForEach(viewModel.devices) { device in
                        DeviceRow(device: device, viewModel: viewModel, authResult: authResult)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            await viewModel.loadDevices(accessToken: authResult.accessToken)
        }
    }
}

struct DeviceRow: View {
    let device: SpotifyDevice
    let viewModel: DevicesViewModel
    let authResult: SpotifyAuthResult

    var body: some View {
        Button {
            Task {
                await viewModel.transferPlayback(to: device, accessToken: authResult.accessToken)
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
        .disabled(device.isActive || device.isRestricted)
        .opacity(device.isRestricted ? 0.5 : 1.0)
    }
}
