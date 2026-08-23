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
    private var clientTokenProvider: (@Sendable () async throws -> String)?
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var connectionId: String?
    private var messageId: UInt32 = 0

    /// Called when the socket dies on its own, so the session can fail and be
    /// rebuilt. Cleared by `disconnect()`, which is a death we asked for.
    private var closeHandler: (@Sendable () -> Void)?

    /// Resumed by the pong handler or by the deadline, whichever lands first.
    /// Actor-isolated, which is what keeps the resume single.
    private var pongContinuation: CheckedContinuation<Bool, Never>?

    /// Ping cadence and how long a pong may take, both matching librespot's
    /// dealer client.
    private static let pingInterval: Duration = .seconds(30)
    private static let pongTimeout: Duration = .seconds(3)

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

    func setClientTokenProvider(_ provider: @escaping @Sendable () async throws -> String) {
        clientTokenProvider = provider
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
        closeHandler = nil
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionId = nil
        resumePong(false)
    }

    /// Registers the callback for an *unasked-for* socket death.
    func setCloseHandler(_ handler: (@Sendable () -> Void)?) {
        closeHandler = handler
    }

    /// The socket died on its own: the receive loop failed, the peer closed,
    /// or a ping went unanswered.
    ///
    /// Without this the loop simply exited and `isConnected` stayed true, so
    /// the session went on reporting a healthy Connect while no cluster update
    /// or remote command could ever arrive again.
    private func handleSocketDied(_ reason: String) {
        guard isConnected else { return }
        debugLog("DealerConnection", "Socket died: \(reason)")

        isConnected = false
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        connectionId = nil
        resumePong(false)

        let handler = closeHandler
        closeHandler = nil
        handler?()
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

    /// Publish device state to Spotify Connect, and answer the cluster it
    /// replies with.
    ///
    /// **The response body is the current cluster**, and on registration it is
    /// the only place the answer appears: dealer pushes carry *changes*, so a
    /// device joining an otherwise quiet account learns who is active here or
    /// not at all. librespot reads it the same way, at the same moment
    /// (`Spirc::handle_connection_id_update`).
    ///
    /// The body goes out gzipped — every reference client compresses it — and
    /// the connection id is percent-encoded into the path, since it is base64
    /// whose `+`/`/`/`=` would otherwise corrupt the URL.
    @discardableResult
    public func putState(_ request: PutStateRequestProto) async throws -> Cluster? {
        guard let connId = connectionId else {
            throw LibrespotError.spircNotReady
        }

        let encodedId = connId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? connId

        // Format: https://gew1-dealer.spotify.com/connect-state/v1/devices/hobs_{connectionId}
        let url = URL(string: "https://\(endpoint)/connect-state/v1/devices/hobs_\(encodedId)")!

        let payload = Self.gzip(request.serialize())
        debugLog("DealerConnection", "[PUT] connect-state hobs_\(encodedId.prefix(24))… (\(payload.count) bytes gzipped)")

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "PUT"
        httpRequest.timeoutInterval = 15
        httpRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let clientTokenProvider {
            try await httpRequest.setValue(clientTokenProvider(), forHTTPHeaderField: "Client-Token")
        }
        httpRequest.setValue("OSX_ARM64", forHTTPHeaderField: "App-Platform")
        httpRequest.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        httpRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("gzip", forHTTPHeaderField: "Content-Encoding")

        httpRequest.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LibrespotError.commandFailed("PutState failed: no response")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw LibrespotError.commandFailed("PutState failed: HTTP \(httpResponse.statusCode)")
        }

        debugLog("DealerConnection", "PutState accepted (HTTP \(httpResponse.statusCode), \(data.count) bytes back)")
        return try? Cluster.parse(from: data)
    }

    /// Minimal gzip wrapper: RFC 1952 header + raw-deflate body + CRC32 tail,
    /// via the Compression framework's zlibRaw codec.
    nonisolated static func gzip(_ data: Data) -> Data {
        var compressed = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])

        // NSData's .zlib emits a 2-byte header and 4-byte Adler-32 tail;
        // gzip wants the raw deflate stream between them.
        if let zlibbed = try? (data as NSData).compressed(using: .zlib) as Data,
           zlibbed.count > 6
        {
            compressed.append(zlibbed.dropFirst(2).dropLast(4))
        } else {
            debugLog("DealerConnection", "gzip: deflate failed; storing uncompressed blocks")
            // Stored (uncompressed) deflate blocks so the stream stays valid.
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset ..< min(offset + 65535, data.count))
                offset += chunk.count
                let isLast: UInt8 = offset >= data.count ? 0x01 : 0x00
                compressed.append(isLast)
                let n = UInt16(chunk.count)
                compressed.append(contentsOf: withUnsafeBytes(of: n) { Data($0) })
                compressed.append(contentsOf: withUnsafeBytes(of: ~n) { Data($0) })
                compressed.append(chunk)
            }
        }

        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = Self.crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        crc ^= 0xFFFF_FFFF
        withUnsafeBytes(of: crc.littleEndian) { compressed.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian) { compressed.append(contentsOf: $0) }
        return compressed
    }

    private nonisolated static let crc32Table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
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
                handleSocketDied(error.localizedDescription)
                return
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
              let data = firstPayload.decodedData
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

    /// Keeps the socket alive and notices a peer that has stopped answering.
    ///
    /// The ping is a **protocol-level** frame, which is what killed the
    /// earlier attempt: an application-level `{"type":"ping"}` is not a message
    /// this endpoint knows, and the socket died within seconds of the first
    /// one. librespot's dealer pings the same way, on the same cadence.
    ///
    /// Waiting for the pong is the point. A dropped network leaves a half-open
    /// socket that accepts writes into nothing, so the receive loop alone would
    /// not notice for as long as TCP keeps retransmitting.
    private func pingLoop() async {
        while isConnected {
            try? await Task.sleep(for: Self.pingInterval)
            guard isConnected, let task = webSocketTask else { return }

            guard await awaitPong(on: task) else {
                handleSocketDied("no pong within \(Self.pongTimeout)")
                return
            }
        }
    }

    /// Sends one ping and reports whether the pong came back in time.
    private func awaitPong(on task: URLSessionWebSocketTask) async -> Bool {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.pongTimeout)
            await self?.resumePong(false)
        }
        defer { deadline.cancel() }

        return await withCheckedContinuation { continuation in
            pongContinuation = continuation
            task.sendPing { [weak self] error in
                Task { await self?.resumePong(error == nil) }
            }
        }
    }

    private func resumePong(_ received: Bool) {
        guard let continuation = pongContinuation else { return }
        pongContinuation = nil
        continuation.resume(returning: received)
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
