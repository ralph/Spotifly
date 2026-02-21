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
    let label: LocalizedStringKey
    let since: Date?
    @State private var currentTime = Date()

    /// Timer that fires every second to update the display
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text(label)
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
        guard let since else { return "--" }

        let interval = currentTime.timeIntervalSince(since)
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
    var onReconnect: (@Sendable () -> Void)?
    var onHardReset: (@Sendable () async -> Void)?
    @State private var isHardResetting = false

    var body: some View {
        if let connection = store.connection {
            let phase = phasePresentation(connection.reconnectPhase)
            let isReconnecting = connection.reconnectPhase == "reconnecting"
            VStack(alignment: .leading, spacing: 12) {
                // Overall status header
                HStack {
                    Text("connection.status")
                        .font(.headline)
                    Spacer()
                    statusBadge(label: phase.label, color: phase.color)
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
                        UptimeDisplay(
                            label: "connection.session_uptime",
                            since: connectedSince,
                        )
                    } else {
                        MetadataRow(label: String(localized: "connection.session_uptime"), value: "--")
                    }

                    UptimeDisplay(
                        label: "connection.continuity_uptime",
                        since: connection.playbackContinuitySince,
                    )

                    MetadataRow(
                        label: String(localized: "connection.reconnect_phase"),
                        value: phase.label,
                    )

                    if let trigger = connection.reconnectTrigger {
                        MetadataRow(
                            label: String(localized: "connection.reconnect_trigger"),
                            value: trigger,
                        )
                    }

                    MetadataRow(
                        label: String(localized: "connection.reconnect_current_attempt"),
                        value: "\(connection.reconnectAttempts)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.reconnect_total_started"),
                        value: "\(connection.reconnectTotalStarted)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.reconnect_total_succeeded"),
                        value: "\(connection.reconnectTotalSucceeded)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.reconnect_total_failed"),
                        value: "\(connection.reconnectTotalFailed)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.reconnect_total_hard_fallbacks"),
                        value: "\(connection.reconnectTotalHardFallbacks)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.audio_interruptions_total"),
                        value: "\(connection.audioInterruptionsTotal)",
                    )

                    MetadataRow(
                        label: String(localized: "connection.last_reconnect"),
                        value: lastReconnectSummary(connection),
                    )

                    MetadataRow(
                        label: String(localized: "connection.last_ready_time"),
                        value: formatMilliseconds(connection.lastReconnectTimeToReadyMs),
                    )

                    MetadataRow(
                        label: String(localized: "connection.last_first_audio_time"),
                        value: formatMilliseconds(connection.lastReconnectTimeToFirstPlayingMs),
                    )

                    if let lastTrigger = connection.lastReconnectTrigger {
                        MetadataRow(
                            label: String(localized: "connection.last_reconnect_trigger"),
                            value: lastTrigger,
                        )
                    }

                    if let reason = connection.lastReconnectFailureReason,
                       connection.lastReconnectSucceeded == false
                    {
                        MetadataRow(
                            label: String(localized: "connection.last_reconnect_failure"),
                            value: reason,
                        )
                    }

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

                // Reconnect actions
                if onReconnect != nil || onHardReset != nil {
                    Divider()
                    HStack(spacing: 8) {
                        if let onReconnect {
                            Button {
                                onReconnect()
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

                        if let onHardReset {
                            Button {
                                isHardResetting = true
                                Task {
                                    await onHardReset()
                                    isHardResetting = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if isHardResetting {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                                    }
                                    Text("connection.hard_reset")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isHardResetting || isReconnecting)
                        }
                    }
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

    private func statusBadge(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15)),
        )
    }

    private func phasePresentation(_ phase: String) -> (label: String, color: Color) {
        switch phase {
        case "connected":
            (String(localized: "connection.phase.connected"), .green)
        case "reconnecting":
            (String(localized: "connection.phase.reconnecting"), .orange)
        case "failed":
            (String(localized: "connection.phase.failed"), .red)
        case "sleeping":
            (String(localized: "connection.phase.sleeping"), .gray)
        case "shutting_down":
            (String(localized: "connection.phase.shutting_down"), .gray)
        default:
            (String(localized: "connection.phase.disconnected"), .orange)
        }
    }

    private func lastReconnectSummary(_ connection: SpotifyConnection) -> String {
        guard let succeeded = connection.lastReconnectSucceeded else {
            return "--"
        }

        let status = succeeded
            ? String(localized: "connection.result.success")
            : String(localized: "connection.result.failed")
        let attempts = connection.lastReconnectAttempts.map(String.init) ?? "--"
        let mode = connection.lastReconnectUsedHardFallback == true
            ? String(localized: "connection.reconnect_mode.hard")
            : String(localized: "connection.reconnect_mode.soft")
        return "\(status) • \(attempts) • \(mode)"
    }

    private func formatMilliseconds(_ ms: UInt64?) -> String {
        guard let ms else { return "--" }
        if ms >= 1000 {
            let seconds = Double(ms) / 1000
            return String(format: "%.2fs", seconds)
        }
        return "\(ms)ms"
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
