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
    private nonisolated(unsafe) let commandSubject = PassthroughSubject<SpircRemoteCommand, Never>()
    private nonisolated(unsafe) let connectionIdSubject = PassthroughSubject<String, Never>()

    // MARK: - Publishers

    public nonisolated var clusterUpdates: AnyPublisher<ClusterUpdateProto, Never> {
        clusterUpdateSubject.eraseToAnyPublisher()
    }

    public nonisolated var commands: AnyPublisher<SpircRemoteCommand, Never> {
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

        // Start receive loop before waiting on anything: it is what delivers
        // the connection-id announcement we are about to wait for.
        Task {
            await receiveLoop()
        }

        // Registration (PutState) needs the connection id, which arrives as
        // the first message over the socket. Wait for it rather than racing
        // Spirc's hello against it.
        let deadline = Date().addingTimeInterval(15)
        while connectionId == nil, isConnected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let identifier = connectionId else {
            isConnected = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            throw LibrespotError.connectionFailed("Dealer never announced a connection id")
        }
        _ = identifier
        debugLog("DealerConnection", "WebSocket connected with connection id")

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

    /// Handle a request from the server and send a reply.
    ///
    /// Requests carry their payload as base64(gzip(JSON)) in `payload.compressed`
    /// — for commands that is `{message_id, sent_by_device_id, command:{endpoint,…}}`.
    private func handleRequest(_ message: DealerMessage) async {
        guard let key = message.key else {
            debugLog("DealerConnection", "Request has no key")
            return
        }

        defer {
            Task { await self.sendReply(key: key, success: true) }
        }

        guard let decoded = Self.decodeCompressedPayload(message.payloadCompressed),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else {
            debugLog("DealerConnection", "Request payload could not be decompressed or parsed")
            return
        }

        let messageId = (json["message_id"] as? NSNumber)?.uint32Value
        let sentBy = json["sent_by_device_id"] as? String

        if let uri = message.uri {
            if uri.starts(with: "hm://connect-state/v1/player/command"),
               let commandJson = json["command"] as? [String: Any]
            {
                let command = Self.parseCommand(endpoint: commandJson["endpoint"] as? String ?? "", json: commandJson)
                debugLog("DealerConnection", "Command received: \(commandJson["endpoint"] ?? "?")")
                commandSubject.send(SpircRemoteCommand(command: command, messageId: messageId, sentByDeviceId: sentBy))
            } else if uri.starts(with: "hm://connect-state/v1/connect/volume"),
                      let volume = json["volume"] as? NSNumber
            {
                debugLog("DealerConnection", "Volume command: \(volume)")
                commandSubject.send(SpircRemoteCommand(
                    command: .setVolume(volume.uint32Value),
                    messageId: messageId,
                    sentByDeviceId: sentBy,
                ))
            } else if uri.starts(with: "hm://connect-state/v1/cluster") {
                await handleClusterUpdate(message)
            }
        }
    }

    /// Base64-decodes and gunzips a request payload.
    static func decodeCompressedPayload(_ compressed: String?) -> Data? {
        guard let compressed, let raw = Data(base64Encoded: compressed) else { return nil }
        return decompressGzipData(raw)
    }

    /// Gunzip helper shared by request payloads and cluster pushes.
    private nonisolated static func decompressGzipData(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B else {
            return data.isEmpty ? nil : data
        }

        // Stream through the Compression framework in chunks; a fixed output
        // estimate breaks on larger cluster states.
        let destinationCapacity = 256 * 1024
        var destination = Data(count: destinationCapacity)
        let result = destination.withUnsafeMutableBytes { dstPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    destinationCapacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!.advanced(by: 10),
                    data.count - 18,
                    nil,
                    COMPRESSION_ZLIB,
                )
            }
        }

        guard result > 0 else { return nil }
        return destination.prefix(result)
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
        guard let payloadData = getPayloadData(from: message, headers: message.headers),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            debugLog("DealerConnection", "No parsable payload in command message")
            return
        }

        let command = Self.parseCommand(endpoint: json["endpoint"] as? String ?? "", json: json)
        commandSubject.send(SpircRemoteCommand(command: command, messageId: nil, sentByDeviceId: nil))
    }

    private func handleVolumeCommand(_ message: DealerMessage) async {
        guard let payloadData = getPayloadData(from: message, headers: message.headers),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            debugLog("DealerConnection", "No parsable payload in volume message")
            return
        }

        if let volume = (json["volume"] as? NSNumber)?.uint32Value {
            commandSubject.send(SpircRemoteCommand(command: .setVolume(volume), messageId: nil, sentByDeviceId: nil))
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
            return Self.decompressGzipData(data)
        }

        return data
    }

    /// Parses a player command in the shape librespot's `dealer::protocol::request`
    /// describes: `{endpoint: "…", …}` with endpoint-specific fields nested
    /// underneath (`options.seek_to`, `options.skip_to.track_uri`,
    /// `track.uri`, plain `value` for the toggles).
    private nonisolated static func parseCommand(endpoint: String, json: [String: Any]) -> SpircCommand {
        let options = json["options"] as? [String: Any]

        switch endpoint {
        case "play":
            let context = json["context"] as? [String: Any]
            let skipTo = options?["skip_to"] as? [String: Any]
            let trackUri = (skipTo?["track_uri"] as? String)
                ?? (json["uris"] as? [String])?.first
                ?? (context?["uri"] as? String).flatMap(Self.trackUriIfTrack)

            let index = (skipTo?["track_index"] as? NSNumber)?.intValue

            return .play(SpircCommand.PlayCommand(
                contextUri: context?["uri"] as? String,
                trackUri: trackUri,
                trackUris: json["uris"] as? [String],
                index: index,
                positionMs: (options?["seek_to"] as? NSNumber)?.uint64Value,
            ))

        case "pause":
            return .pause

        case "resume":
            return .resume

        case "seek_to":
            let position = (json["value"] as? NSNumber) ?? (json["position"] as? NSNumber) ?? 0
            return .seekTo(positionMs: position.uint64Value)

        case "skip_next":
            return .next

        case "skip_prev":
            return .prev

        case "set_shuffling_context":
            return .setShuffle((json["value"] as? Bool) ?? false)

        case "set_repeating_track":
            return .setRepeat(((json["value"] as? Bool) ?? false) ? .track : .off)

        case "set_repeating_context":
            return .setRepeat(((json["value"] as? Bool) ?? false) ? .context : .off)

        case "add_to_queue":
            let track = json["track"] as? [String: Any]
            return .addToQueue(uri: track?["uri"] as? String ?? "")

        case "transfer":
            // We only receive this when we are the transfer target; the
            // embedded state blob is protobuf we do not consume yet.
            return .transfer(SpircCommand.TransferCommand(
                targetDeviceId: json["from_device_identifier"] as? String ?? "",
                transferData: nil,
            ))

        default:
            return .unknown(endpoint)
        }
    }

    /// A context uri that is actually a single-track context, or nil.
    private nonisolated static func trackUriIfTrack(_ uri: String) -> String? {
        uri.starts(with: "spotify:track:") ? uri : nil
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
