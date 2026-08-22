//
//  ConnectWebAPI.swift
//  SwiftLibrespot
//
//  The two Web API calls the local player needs as a fallback: transfer
//  playback, and nothing else. Everything else arrives over the cluster.
//

import Foundation

enum ConnectWebAPI {
    struct TransferError: Error, LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    /// Transfers playback to a device via `PUT /me/player`.
    ///
    /// A fallback for handoff to *other* devices; native Spirc transfer is not
    /// implemented yet. Requires the target device to be visible to Spotify's
    /// servers — which, for this app, its own PutState registration provides.
    static func transferPlayback(toDeviceId deviceId: String, accessToken: String, play: Bool = true) async throws {
        let urlString = "https://api.spotify.com/v1/me/player"

        debugLog("ConnectWebAPI", "[PUT] \(urlString) -> \(deviceId)")

        guard let url = URL(string: urlString) else {
            throw TransferError(message: "Invalid transfer URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "device_ids": [deviceId],
            "play": play,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransferError(message: "Transfer got no response")
        }

        switch httpResponse.statusCode {
        case 200, 202, 204:
            return
        case 404:
            // Target unknown to Spotify — typical when it never registered.
            throw TransferError(message: "Device \(deviceId) is not available for transfer (404)")
        default:
            throw TransferError(message: "Transfer failed with HTTP \(httpResponse.statusCode)")
        }
    }
}
