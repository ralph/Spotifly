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
                        await deviceService.loadDevices(accessToken: session.accessToken)
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
            } else if store.availableDevices.isEmpty {
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
                    ForEach(store.availableDevices) { device in
                        DeviceRow(device: device)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            await deviceService.loadDevices(accessToken: session.accessToken)
        }
    }
}

struct DeviceRow: View {
    let device: Device
    @Environment(SpotifySession.self) private var session
    @Environment(DeviceService.self) private var deviceService

    var body: some View {
        Button {
            Task {
                await deviceService.transferPlayback(to: device, accessToken: session.accessToken)
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
        .disabled(device.isActive || device.isRestricted)
        .opacity(device.isRestricted ? 0.5 : 1.0)
    }
}
