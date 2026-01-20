//
//  DealerConnection.swift
//  SwiftLibrespot
//
//  WebSocket connection to Spotify dealer for SPIRC/Connect
//

import Combine
import Compression
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
    private var messageId: UInt32 = 0

    /// Ping interval in seconds
    private static let pingInterval: TimeInterval = 30

    /// Message publishers
    private nonisolated(unsafe) let clusterUpdateSubject = PassthroughSubject<ClusterUpdateProto, Never>()
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircCommand, Never>()
    private nonisolated(unsafe) let connectionIdSubject = PassthroughSubject<String, Never>()

    // MARK: - Publishers

    public nonisolated var clusterUpdates: AnyPublisher<ClusterUpdateProto, Never> {
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
    public func putState(_ request: PutStateRequestProto) async throws {
        guard let connId = connectionId else {
            throw LibrespotError.spircNotReady
        }

        // Build PUT request to connect-state endpoint
        // Format: https://gew1-dealer.spotify.com/connect-state/v1/devices/hobs_{connectionId}
        let url = URL(string: "https://\(endpoint)/connect-state/v1/devices/hobs_\(connId)")!

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "PUT"
        httpRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        // Serialize PutStateRequest to protobuf
        httpRequest.httpBody = request.serialize()

        debugLog("DealerConnection", "Sending PutState (\(httpRequest.httpBody?.count ?? 0) bytes) to \(url)")

        let (_, response) = try await URLSession.shared.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibrespotError.commandFailed("PutState failed: no response")
        }

        guard httpResponse.statusCode == 200 else {
            throw LibrespotError.commandFailed("PutState failed: HTTP \(httpResponse.statusCode)")
        }

        debugLog("DealerConnection", "PutState successful")
    }

    /// Get next message ID
    public func nextMessageId() -> UInt32 {
        messageId += 1
        return messageId
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

        // Handle message type
        switch dealerMsg.type {
        case "pong":
            // Server responded to our ping, nothing to do
            debugLog("DealerConnection", "Received pong")
            return

        case "ping":
            // Server is pinging us, respond with pong
            await sendPong()
            return

        case "request":
            // Server is making a request, handle it and reply
            await handleRequest(dealerMsg)
            return

        case "message":
            // Regular message, process it
            break

        default:
            debugLog("DealerConnection", "Unknown message type: \(dealerMsg.type ?? "nil")")
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

        if uri.starts(with: "hm://pusher/v1/connections/") {
            // Extract connection ID from URI path (it's URL-encoded base64)
            let prefix = "hm://pusher/v1/connections/"
            let encoded = String(uri.dropFirst(prefix.count))
            if let decoded = encoded.removingPercentEncoding {
                connectionId = decoded
                connectionIdSubject.send(decoded)
                debugLog("DealerConnection", "Connection ID from pusher: \(decoded.prefix(50))...")
            }
        } else if uri.starts(with: "hm://connect-state/v1/cluster") {
            await handleClusterUpdate(dealerMsg)
        } else if uri.starts(with: "hm://connect-state/v1/player/command") {
            await handleCommand(dealerMsg)
        } else if uri.starts(with: "hm://connect-state/v1/connect/volume") {
            await handleVolumeCommand(dealerMsg)
        } else {
            debugLog("DealerConnection", "Unhandled URI: \(uri)")
        }
    }

    /// Handle a request from the server and send a reply
    private func handleRequest(_ message: DealerMessage) async {
        guard let key = message.key else {
            debugLog("DealerConnection", "Request has no key")
            return
        }

        // Process the request based on URI
        if let uri = message.uri {
            if uri.starts(with: "hm://connect-state/v1/player/command") {
                await handleCommand(message)
            } else if uri.starts(with: "hm://connect-state/v1/connect/volume") {
                await handleVolumeCommand(message)
            } else if uri.starts(with: "hm://connect-state/v1/cluster") {
                await handleClusterUpdate(message)
            } else {
                debugLog("DealerConnection", "Unhandled request URI: \(uri)")
            }
        }

        // Send success reply
        await sendReply(key: key, success: true)
    }

    /// Send a reply to a server request
    private func sendReply(key: String, success: Bool) async {
        struct ReplyMessage: Encodable {
            let type: String
            let key: String
            let payload: ReplyPayload
        }

        struct ReplyPayload: Encodable {
            let success: Bool
        }

        let reply = ReplyMessage(
            type: "reply",
            key: key,
            payload: ReplyPayload(success: success),
        )

        do {
            let data = try JSONEncoder().encode(reply)
            try await send(data)
            debugLog("DealerConnection", "Sent reply for key: \(key)")
        } catch {
            debugLog("DealerConnection", "Failed to send reply: \(error)")
        }
    }

    /// Send a pong response to server ping
    private func sendPong() async {
        struct PongMessage: Encodable {
            let type: String
        }

        let pong = PongMessage(type: "pong")

        do {
            let data = try JSONEncoder().encode(pong)
            try await send(data)
            debugLog("DealerConnection", "Sent pong")
        } catch {
            debugLog("DealerConnection", "Failed to send pong: \(error)")
        }
    }

    private func handleClusterUpdate(_ message: DealerMessage) async {
        guard let payloadData = getPayloadData(from: message, headers: message.headers) else {
            debugLog("DealerConnection", "No payload data in cluster update")
            return
        }

        do {
            let update = try ClusterUpdateProto.parse(from: payloadData)
            debugLog("DealerConnection", "Received cluster update, active device: \(update.cluster.activeDeviceId)")
            clusterUpdateSubject.send(update)
        } catch {
            debugLog("DealerConnection", "Failed to parse cluster update: \(error)")
        }
    }

    private func handleCommand(_ message: DealerMessage) async {
        guard let payloadData = getPayloadData(from: message, headers: message.headers) else {
            debugLog("DealerConnection", "No payload data in command")
            return
        }

        // Commands come as JSON with a "command" object
        do {
            // The payload contains a PlayerCommand JSON object
            if let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
               let endpoint = json["endpoint"] as? String
            {
                let command = parseCommand(endpoint: endpoint, json: json)
                debugLog("DealerConnection", "Received command: \(endpoint)")
                commandSubject.send(command)
            }
        }
    }

    private func handleVolumeCommand(_ message: DealerMessage) async {
        guard let payloadData = getPayloadData(from: message, headers: message.headers) else {
            debugLog("DealerConnection", "No payload data in volume command")
            return
        }

        do {
            let volumeCmd = try SetVolumeCommandProto.parse(from: payloadData)
            debugLog("DealerConnection", "Received volume command: \(volumeCmd.volume)")
            commandSubject.send(.setVolume(UInt32(volumeCmd.volume)))
        } catch {
            debugLog("DealerConnection", "Failed to parse volume command: \(error)")
        }
    }

    /// Extract and decompress payload data from a message
    private nonisolated func getPayloadData(from message: DealerMessage, headers: [String: String]?) -> Data? {
        guard let payloads = message.payloads,
              let firstPayload = payloads.first,
              var data = firstPayload.decodedData
        else {
            return nil
        }

        // Check if data is gzip compressed
        let transferEncoding = headers?["Transfer-Encoding"] ?? headers?["transfer-encoding"]
        if transferEncoding == "gzip" {
            if let decompressed = decompressGzip(data) {
                data = decompressed
            }
        }

        return data
    }

    /// Decompress gzip data
    private nonisolated func decompressGzip(_ data: Data) -> Data? {
        // Check gzip magic number
        guard data.count >= 2, data[0] == 0x1F, data[1] == 0x8B else {
            return data // Not gzip, return as-is
        }

        // Use Compression framework
        let bufferSize = data.count * 10 // Estimate decompressed size
        var decompressed = Data(count: bufferSize)

        let result = data.withUnsafeBytes { srcPtr in
            decompressed.withUnsafeMutableBytes { dstPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    bufferSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 10), // Skip gzip header
                    data.count - 18, // Skip header (10) and trailer (8)
                    nil,
                    COMPRESSION_ZLIB,
                )
            }
        }

        if result > 0 {
            return decompressed.prefix(result)
        }

        return nil
    }

    /// Parse a command from JSON endpoint
    private nonisolated func parseCommand(endpoint: String, json: [String: Any]) -> SpircCommand {
        switch endpoint {
        case "play":
            let contextUri = json["context_uri"] as? String
            let trackUri = (json["uris"] as? [String])?.first
            return .play(SpircCommand.PlayCommand(
                contextUri: contextUri,
                trackUri: trackUri,
                trackUris: json["uris"] as? [String],
                index: json["offset_position"] as? Int,
                positionMs: (json["position_ms"] as? Int).map { UInt64($0) },
            ))

        case "pause":
            return .pause

        case "resume":
            return .resume

        case "seek_to":
            let position = (json["position"] as? Int) ?? (json["position_ms"] as? Int) ?? 0
            return .seekTo(positionMs: UInt64(position))

        case "skip_next":
            return .next

        case "skip_prev":
            return .prev

        case "set_shuffling_context":
            let shuffle = (json["value"] as? Bool) ?? false
            return .setShuffle(shuffle)

        case "set_repeating_context", "set_repeating_track":
            let repeating = (json["value"] as? Bool) ?? false
            let mode: ClusterUpdate.RepeatMode = endpoint == "set_repeating_track" ? .track : (repeating ? .context : .off)
            return .setRepeat(mode)

        case "add_to_queue":
            let uri = json["track_uri"] as? String ?? ""
            return .addToQueue(uri: uri)

        default:
            return .unknown(endpoint)
        }
    }

    // MARK: - Ping Loop

    private func pingLoop() async {
        while isConnected {
            try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))

            guard webSocketTask != nil, isConnected else { break }

            // Send JSON ping message (Spotify dealer protocol)
            struct PingMessage: Encodable {
                let type: String
            }

            let ping = PingMessage(type: "ping")

            do {
                let data = try JSONEncoder().encode(ping)
                try await send(data)
            } catch {
                debugLog("DealerConnection", "Ping failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func buildWebSocketURL() -> URL {
        // Format: wss://dealer.spotify.com/?access_token=...
        // Endpoint may include port (e.g., "gew4-dealer.spotify.com:443")
        var components = URLComponents()
        components.scheme = "wss"

        // Parse host and port from endpoint
        if let colonIndex = endpoint.lastIndex(of: ":"),
           let port = Int(endpoint[endpoint.index(after: colonIndex)...])
        {
            components.host = String(endpoint[..<colonIndex])
            components.port = port
        } else {
            components.host = endpoint
        }

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
