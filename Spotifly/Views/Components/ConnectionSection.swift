//
//  ConnectionSection.swift
//  Spotifly
//
//  Playing On's connection section: the session's state, its details, and Reconnect.
//

import SwiftUI

/// The connection to Spotify as form rows: a status with a dot and how long it has held, the
/// session's details under a disclosure, and Reconnect.
struct ConnectionSection: View {
    @Environment(PlayerModel.self) private var player
    var onReconnect: (@Sendable () async -> Void)?
    @State private var isReconnecting = false

    var body: some View {
        Section("speakers.spotify_connection") {
            if let connection = player.connection {
                LabeledContent {
                    if connection.isConnected, let connectedSince = connection.connectedSince {
                        // A relative date, which keeps itself up to date.
                        Text("connection.connected_for \(Text(connectedSince, style: .relative))")
                    } else {
                        Text(connection.isConnected ? "connection.connected" : "connection.disconnected")
                    }
                } label: {
                    Label {
                        Text("connection.status")
                    } icon: {
                        Circle()
                            .fill(connection.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                }

                DisclosureGroup("connection.details") {
                    LabeledContent("connection.reconnect_attempts", value: "\(connection.reconnectAttempts)")
                    if let deviceId = connection.deviceId {
                        LabeledContent("connection.device_id") {
                            Text(verbatim: deviceId)
                                .monospaced()
                                .textSelection(.enabled)
                        }
                    }
                    if let lastError = connection.lastError {
                        LabeledContent("connection.last_error") {
                            Text(verbatim: lastError)
                                .textSelection(.enabled)
                        }
                    }
                }

                if let onReconnect {
                    LabeledContent {
                        Button("connection.reconnect") {
                            isReconnecting = true
                            Task {
                                await onReconnect()
                                isReconnecting = false
                            }
                        }
                        .disabled(isReconnecting)
                    } label: {
                        Text("connection.reconnect")
                        Text("connection.reconnect_hint")
                    }
                }
            } else {
                Text("connection.no_data")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
