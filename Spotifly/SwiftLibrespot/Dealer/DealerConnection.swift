//
//  DealerConnection.swift
//  SwiftLibrespot
//
//  WebSocket connection to Spotify dealer for SPIRC/Connect
//

import Combine
import Compression
import Foundation

/// WebSocket connection to Spotify dealer, which pushes cluster updates. Requests, the player
/// commands sent to this device among them, are answered and otherwise left alone: the device
/// is hidden and plays nothing.
public actor DealerConnection {
    // MARK: - Properties

    private let endpoint: String
    /// Sign the socket's URL and PutState, as the app's pages are signed. Asked
    /// for the bearer on every use: a token held from the start expired an
    /// hour into the session, and every PutState after that was answered 401.
    private let credentials: SpotifyCredentials
    /// Where connect-state lives. It is *not* the dealer host, which is what
    /// PutState was aimed at until every one of them came back 403.
    private let spclientHost: String
    /// The device's own id — the connect-state resource this session owns.
    private let deviceId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var connectionId: String?

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

    /// Message publisher
    private nonisolated(unsafe) let clusterUpdateSubject = PassthroughSubject<ClusterUpdateProto, Never>()

    // MARK: - Publishers

    public nonisolated var clusterUpdates: AnyPublisher<ClusterUpdateProto, Never> {
        clusterUpdateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(
        endpoint: String,
        credentials: SpotifyCredentials,
        spclientHost: String,
        deviceId: String,
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.spclientHost = spclientHost
        self.deviceId = deviceId
        debugLog("DealerConnection", "Created for endpoint: \(endpoint)")
    }

    // MARK: - Connection

    /// Connect to the dealer WebSocket
    public func connect() async throws {
        debugLog("DealerConnection", "Connecting to dealer...")

        // Build WebSocket URL with access token
        let wsURL = try await buildWebSocketURL(accessToken: credentials.accessToken())

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
        guard connectionId != nil else {
            isConnected = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            throw LibrespotError.connectionFailed("Dealer never announced a connection id")
        }
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
    /// could ever arrive again.
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

    /// Sends a JSON message to the dealer — as a **text** frame.
    ///
    /// The dealer closes the connection on a binary one. Every request reply
    /// went out binary, so each request took the socket down with its own
    /// acknowledgement: the session rebuilt, and the sender never heard back.
    /// librespot sends these as `WsMessage::Text`.
    public func send(_ message: Data) async throws {
        guard let task = webSocketTask, isConnected else {
            throw LibrespotError.notInitialized
        }

        try await task.send(.string(String(decoding: message, as: UTF8.self)))
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
    @discardableResult
    public func putState(_ request: PutStateRequestProto) async throws -> Cluster? {
        guard let connId = connectionId else {
            throw LibrespotError.spircNotReady
        }

        // `PUT https://{spclient}/connect-state/v1/devices/{device_id}`, with the
        // connection id as a **header**. Every part of that was wrong before:
        // the request went to the dealer host, named the resource
        // `hobs_{percent-encoded connection id}`, and sent no connection-id
        // header at all — so all of them, registration included, were answered
        // 403 and this device never joined the cluster. librespot's
        // `SpClient::put_connect_state_request` is the shape being matched.
        let url = URL(string: "https://\(spclientHost)/connect-state/v1/devices/\(deviceId)")!

        // Uncompressed. librespot sends this protobuf raw, and there is no
        // gzip anywhere in its spclient; compressing it here was answered 503.
        let payload = request.serialize()
        debugLog("DealerConnection", "[PUT] connect-state devices/\(deviceId.prefix(12))… (\(payload.count) bytes)")

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "PUT"
        httpRequest.timeoutInterval = 15
        httpRequest.setValue(connId, forHTTPHeaderField: "X-Spotify-Connection-Id")
        httpRequest.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

        httpRequest.httpBody = payload

        // A refused client token is asked again with a fresh one, but no server error: a report
        // asked again later could land after the newer one that replaced it.
        let (data, status) = try await credentials.send(httpRequest)

        guard (200 ..< 300).contains(status) else {
            throw LibrespotError.requestFailed("PutState", status: status)
        }

        debugLog("DealerConnection", "PutState accepted (HTTP \(status), \(data.count) bytes back)")
        return try? Cluster.parse(from: data)
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
                debugLog("DealerConnection", "Connection ID from pusher: \(decoded.prefix(50))...")
            }
        } else if uri.starts(with: "hm://connect-state/v1/cluster") {
            await handleClusterUpdate(dealerMsg)
        } else {
            debugLog("DealerConnection", "Unhandled URI: \(uri)")
        }
    }

    /// Answers a request from the server, as handled: a command sent to this device, which
    /// plays nothing, or a cluster update, which is adopted as a pushed one is. Unanswered,
    /// its sender would wait for an acknowledgement that never comes.
    private func handleRequest(_ message: DealerMessage) async {
        guard let key = message.key else {
            debugLog("DealerConnection", "Request has no key")
            return
        }

        defer {
            Task { await self.sendReply(key: key, success: true) }
        }

        if let uri = message.uri, uri.starts(with: "hm://connect-state/v1/cluster") {
            await handleClusterUpdate(message)
        } else {
            debugLog("DealerConnection", "Request answered, not acted on: \(message.uri ?? "no uri")")
        }
    }

    /// Gunzips a cluster push.
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
        guard let payloadData = Self.payloadData(from: message, headers: message.headers) else {
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

    /// Extract and decompress payload data from a message
    nonisolated static func payloadData(from message: DealerMessage, headers: [String: String]?) -> Data? {
        guard let payloads = message.payloads,
              let firstPayload = payloads.first,
              let data = firstPayload.decodedData
        else {
            return nil
        }

        // Check if data is gzip compressed
        let transferEncoding = headers?["Transfer-Encoding"] ?? headers?["transfer-encoding"]
        if transferEncoding == "gzip" {
            return decompressGzipData(data)
        }

        return data
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

    private func buildWebSocketURL(accessToken: String) -> URL {
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
