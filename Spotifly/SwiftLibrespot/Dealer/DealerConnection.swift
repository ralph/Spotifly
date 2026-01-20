//
//  DealerConnection.swift
//  SwiftLibrespot
//
//  WebSocket connection to Spotify dealer for SPIRC/Connect
//

import Combine
import Foundation

/// WebSocket connection to Spotify dealer
/// Handles SPIRC commands and cluster state updates
public actor DealerConnection {
    // MARK: - Properties

    private let endpoint: String
    private let accessToken: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var connectionId: String?

    /// Ping interval in seconds
    private static let pingInterval: TimeInterval = 30

    /// Message publishers
    private nonisolated(unsafe) let clusterUpdateSubject = PassthroughSubject<ClusterUpdate, Never>()
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircCommand, Never>()
    private nonisolated(unsafe) let connectionIdSubject = PassthroughSubject<String, Never>()

    // MARK: - Publishers

    public nonisolated var clusterUpdates: AnyPublisher<ClusterUpdate, Never> {
        clusterUpdateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commands: AnyPublisher<SpircCommand, Never> {
        commandSubject.eraseToAnyPublisher()
    }

    public nonisolated var connectionIds: AnyPublisher<String, Never> {
        connectionIdSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(endpoint: String, accessToken: String) {
        self.endpoint = endpoint
        self.accessToken = accessToken
        debugLog("DealerConnection", "Created for endpoint: \(endpoint)")
    }

    // MARK: - Connection

    /// Connect to the dealer WebSocket
    public func connect() async throws {
        debugLog("DealerConnection", "Connecting to dealer...")

        // Build WebSocket URL with access token
        let wsURL = buildWebSocketURL()

        // Create WebSocket task
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()

        isConnected = true
        debugLog("DealerConnection", "WebSocket connected")

        // Start receive loop
        Task {
            await receiveLoop()
        }

        // Start ping loop
        Task {
            await pingLoop()
        }
    }

    /// Disconnect from dealer
    public func disconnect() {
        debugLog("DealerConnection", "Disconnecting...")
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionId = nil
    }

    // MARK: - Messaging

    /// Send a message to the dealer
    public func send(_ message: Data) async throws {
        guard let task = webSocketTask, isConnected else {
            throw LibrespotError.notInitialized
        }

        let wsMessage = URLSessionWebSocketTask.Message.data(message)
        try await task.send(wsMessage)
    }

    /// Send a JSON message
    public func sendJSON(_ object: some Encodable) async throws {
        let data = try JSONEncoder().encode(object)
        try await send(data)
    }

    // MARK: - PutState

    /// Publish device state to Spotify Connect
    public func putState(_: PutStateRequest) async throws {
        guard let connId = connectionId else {
            throw LibrespotError.spircNotReady
        }

        // Build PUT request to connect-state endpoint
        let url = URL(string: "https://\(endpoint)/connect-state/v1/devices/hobs_\(connId)")!

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "PUT"
        httpRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

        // TODO: Serialize PutStateRequest to protobuf
        // For now, send as JSON placeholder
        httpRequest.httpBody = try JSONEncoder().encode(["placeholder": true])

        let (_, response) = try await URLSession.shared.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw LibrespotError.commandFailed("PutState failed")
        }

        debugLog("DealerConnection", "PutState successful")
    }

    // MARK: - Receive Loop

    private func receiveLoop() async {
        while isConnected {
            guard let task = webSocketTask else { break }

            do {
                let message = try await task.receive()
                await handleMessage(message)
            } catch {
                if isConnected {
                    debugLog("DealerConnection", "Receive error: \(error)")
                }
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data
        switch message {
        case let .data(d):
            data = d
        case let .string(s):
            data = s.data(using: .utf8) ?? Data()
        @unknown default:
            return
        }

        // Try to parse as DealerMessage
        guard let dealerMsg = decodeDealerMessage(data) else {
            debugLog("DealerConnection", "Failed to parse dealer message")
            return
        }

        // Check for connection ID
        if let connId = dealerMsg.connectionId {
            connectionId = connId
            connectionIdSubject.send(connId)
            debugLog("DealerConnection", "Connection ID: \(connId)")
            return
        }

        // Route message based on URI
        guard let uri = dealerMsg.uri else { return }

        if uri.starts(with: "hm://connect-state/v1/cluster") {
            await handleClusterUpdate(dealerMsg)
        } else if uri.starts(with: "hm://connect-state/v1/player/command") {
            await handleCommand(dealerMsg)
        } else if uri.starts(with: "hm://connect-state/v1/connect/volume") {
            await handleVolumeCommand(dealerMsg)
        } else {
            debugLog("DealerConnection", "Unhandled URI: \(uri)")
        }
    }

    private func handleClusterUpdate(_ message: DealerMessage) async {
        guard let payloads = message.payloads,
              let firstPayload = payloads.first,
              let data = firstPayload.decodedData
        else { return }

        // TODO: Parse protobuf ClusterUpdate
        // For now, log that we received it
        debugLog("DealerConnection", "Received cluster update (\(data.count) bytes)")

        // Placeholder: would parse and emit
        // clusterUpdateSubject.send(parsedUpdate)
    }

    private func handleCommand(_ message: DealerMessage) async {
        guard let payloads = message.payloads,
              let firstPayload = payloads.first,
              let data = firstPayload.decodedData
        else { return }

        // TODO: Parse protobuf command
        debugLog("DealerConnection", "Received command (\(data.count) bytes)")

        // Placeholder: would parse and emit
        // commandSubject.send(parsedCommand)
    }

    private func handleVolumeCommand(_ message: DealerMessage) async {
        guard let payloads = message.payloads,
              let firstPayload = payloads.first,
              let data = firstPayload.decodedData
        else { return }

        // TODO: Parse volume command
        debugLog("DealerConnection", "Received volume command (\(data.count) bytes)")
    }

    // MARK: - Ping Loop

    private func pingLoop() async {
        while isConnected {
            try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))

            guard let task = webSocketTask, isConnected else { break }

            // Send ping frame
            task.sendPing { error in
                if let error {
                    debugLog("DealerConnection", "Ping failed: \(error)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func buildWebSocketURL() -> URL {
        // Format: wss://dealer.spotify.com/?access_token=...
        var components = URLComponents()
        components.scheme = "wss"
        components.host = endpoint
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
        ]
        return components.url!
    }

    /// Decode DealerMessage outside of actor isolation
    private nonisolated func decodeDealerMessage(_ data: Data) -> DealerMessage? {
        try? JSONDecoder().decode(DealerMessage.self, from: data)
    }
}
