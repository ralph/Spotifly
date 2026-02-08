//
//  ConnectionStatusView.swift
//  Spotifly
//
//  Dashboard showing librespot connection status and details.
//

import Combine
import SwiftUI

// MARK: - Connection Status Row

/// A single status indicator row with icon and label
private struct ConnectionStatusRow: View {
    let label: String
    let isConnected: Bool
    let detail: String?

    init(label: String, isConnected: Bool, detail: String? = nil) {
        self.label = label
        self.isConnected = isConnected
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.subheadline)

            Spacer()

            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(isConnected ? String(localized: "connection.connected") : String(localized: "connection.disconnected"))
                    .font(.caption)
                    .foregroundStyle(isConnected ? .green : .secondary)
            }
        }
    }
}

// MARK: - Metadata Row

/// A key/value info row for displaying connection metadata
private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Uptime Display

/// Displays connection uptime with automatic timer updates
private struct UptimeDisplay: View {
    let connectedSince: Date?
    @State private var currentTime = Date()

    /// Timer that fires every second to update the display
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("connection.uptime")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(formattedUptime)
                .font(.caption)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }

    private var formattedUptime: String {
        guard let connectedSince else { return "--" }

        let interval = currentTime.timeIntervalSince(connectedSince)
        guard interval >= 0 else { return "--" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }
}

// MARK: - Connection Status View

/// Main dashboard showing librespot connection status
struct ConnectionStatusView: View {
    @Environment(AppStore.self) private var store
    var onReconnect: (@Sendable () async -> Void)?
    @State private var isReconnecting = false

    var body: some View {
        if let connection = store.connection {
            VStack(alignment: .leading, spacing: 12) {
                // Overall status header
                HStack {
                    Text("connection.status")
                        .font(.headline)
                    Spacer()
                    statusBadge(isConnected: connection.isConnected && connection.spircReady)
                }

                Divider()

                // Status indicators
                VStack(spacing: 8) {
                    ConnectionStatusRow(
                        label: String(localized: "connection.session"),
                        isConnected: connection.isConnected,
                        detail: connection.connectionId.map { truncateId($0) },
                    )

                    ConnectionStatusRow(
                        label: String(localized: "connection.spirc"),
                        isConnected: connection.spircReady,
                        detail: connection.spircReady ? String(localized: "connection.spirc_ready") : String(localized: "connection.spirc_not_ready"),
                    )
                }

                Divider()

                // Metadata
                VStack(spacing: 8) {
                    if connection.isConnected, let connectedSince = connection.connectedSince {
                        UptimeDisplay(connectedSince: connectedSince)
                    } else {
                        MetadataRow(label: String(localized: "connection.uptime"), value: "--")
                    }

                    MetadataRow(
                        label: String(localized: "connection.reconnect_attempts"),
                        value: "\(connection.reconnectAttempts)",
                    )

                    if let deviceId = connection.deviceId {
                        MetadataRow(
                            label: String(localized: "connection.device_id"),
                            value: truncateId(deviceId),
                        )
                    }
                }

                // Error banner (if present)
                if let lastError = connection.lastError {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Reconnect button
                if let onReconnect {
                    Divider()
                    Button {
                        isReconnecting = true
                        Task {
                            await onReconnect()
                            isReconnecting = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isReconnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("connection.reconnect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isReconnecting)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            VStack(spacing: 8) {
                Image(systemName: "network.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("connection.no_data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    private func statusBadge(isConnected: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(isConnected ? String(localized: "connection.connected") : String(localized: "connection.disconnected"))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(isConnected ? .green : .orange)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(isConnected ? Color.green.opacity(0.15) : Color.orange.opacity(0.15)),
        )
    }

    /// Truncate long IDs for display
    private func truncateId(_ id: String) -> String {
        if id.count <= 16 {
            return id
        }
        let prefix = id.prefix(8)
        let suffix = id.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}
