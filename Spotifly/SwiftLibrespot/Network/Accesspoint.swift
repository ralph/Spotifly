//
//  Accesspoint.swift
//  SwiftLibrespot
//
//  TCP connection to Spotify accesspoint with Shannon cipher encryption
//

import CryptoKit
import Foundation
import Network

/// Connection to a Spotify accesspoint
/// Handles TCP connection, Diffie-Hellman key exchange, and encrypted communication
public actor Accesspoint {
    // MARK: - Properties

    private let endpoint: String
    private var connection: NWConnection?
    private var cipherPair: CipherPair?
    private var sendNonce: UInt32 = 0
    private var recvNonce: UInt32 = 0
    private var isConnected = false

    /// Ping interval in seconds
    private static let pingInterval: TimeInterval = 120

    /// Pending Mercury requests awaiting response
    private var pendingRequests: [UInt64: CheckedContinuation<MercuryResponse, Error>] = [:]
    private var nextSequenceId: UInt64 = 1

    // MARK: - Initialization

    public init(endpoint: String) {
        self.endpoint = endpoint
        debugLog("Accesspoint", "Created for endpoint: \(endpoint)")
    }

    // MARK: - Connection

    /// Connect and authenticate with credentials
    public func connect(credentials: SpotifyCredentials) async throws {
        debugLog("Accesspoint", "Connecting to \(endpoint)...")

        // Parse endpoint (format: "host:port")
        let parts = endpoint.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1])
        else {
            throw LibrespotError.connectionFailed("Invalid endpoint format: \(endpoint)")
        }

        let host = String(parts[0])
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port)!

        // Create TCP connection
        connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

        // Wait for connection to be ready
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case let .failed(error):
                    continuation.resume(throwing: LibrespotError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    continuation.resume(throwing: LibrespotError.connectionFailed("Connection cancelled"))
                default:
                    break
                }
            }
            connection?.start(queue: .global())
        }

        debugLog("Accesspoint", "TCP connected, performing handshake...")

        // Perform Diffie-Hellman key exchange
        try await performHandshake()

        debugLog("Accesspoint", "Handshake complete, authenticating...")

        // Authenticate with token
        try await authenticate(token: credentials.accessToken)

        isConnected = true
        debugLog("Accesspoint", "Connected and authenticated")

        // Start receive loop
        Task {
            await receiveLoop()
        }

        // Start ping loop
        Task {
            await pingLoop()
        }
    }

    /// Disconnect from the accesspoint
    public func disconnect() {
        debugLog("Accesspoint", "Disconnecting...")
        isConnected = false
        connection?.cancel()
        connection = nil
        cipherPair = nil

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: LibrespotError.connectionFailed("Disconnected"))
        }
        pendingRequests.removeAll()
    }

    // MARK: - Handshake

    private func performHandshake() async throws {
        // Generate our DH key pair using CryptoKit
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey

        // Build ClientHello message
        var clientHello = Data()
        // Version: 0x00, 0x04 (product type + version)
        clientHello.append(contentsOf: [0x00, 0x04])
        // Our public key
        clientHello.append(publicKey.rawRepresentation)
        // Random nonce (16 bytes)
        var clientNonce = Data(count: 16)
        _ = clientNonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        clientHello.append(clientNonce)

        // Send ClientHello
        try await send(raw: clientHello)

        // Receive APResponseMessage
        let response = try await receiveRaw(minLength: 4)

        // Parse server's public key and nonce from response
        guard response.count >= 96 else {
            throw LibrespotError.handshakeFailed("Response too short")
        }

        let serverPublicKeyData = response.subdata(in: 0 ..< 32)
        guard let serverPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPublicKeyData) else {
            throw LibrespotError.handshakeFailed("Invalid server public key")
        }

        // Compute shared secret
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)

        // Derive send and receive keys using HKDF
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        let sendKey = deriveKey(secret: sharedSecretData, info: "send", length: 32)
        let recvKey = deriveKey(secret: sharedSecretData, info: "receive", length: 32)

        // Initialize cipher pair
        cipherPair = CipherPair(sendKey: sendKey, recvKey: recvKey)

        debugLog("Accesspoint", "Key exchange complete")
    }

    private func deriveKey(secret: Data, info: String, length: Int) -> Data {
        // Simple key derivation (in production, use proper HKDF)
        let combined = secret + info.data(using: .utf8)!
        let hash = SHA256.hash(data: combined)
        return Data(hash.prefix(length))
    }

    // MARK: - Authentication

    private func authenticate(token: String) async throws {
        // Build login packet with OAuth token
        var loginPayload = Data()

        // Authentication type: AUTHENTICATION_SPOTIFY_TOKEN = 14
        loginPayload.append(14)

        // Token length (varint) + token
        let tokenData = token.data(using: .utf8)!
        loginPayload.append(contentsOf: encodeVarint(UInt64(tokenData.count)))
        loginPayload.append(tokenData)

        // Send encrypted login packet
        let packet = SpotifyPacket(command: .login, payload: loginPayload)
        try await sendPacket(packet)

        // Wait for response
        let response = try await receivePacket()

        switch response.command {
        case .apWelcome:
            debugLog("Accesspoint", "Authentication successful")
        case .authFailure:
            throw LibrespotError.authenticationFailed("Server rejected authentication")
        default:
            throw LibrespotError.authenticationFailed("Unexpected response: \(response.command)")
        }
    }

    // MARK: - Packet I/O

    /// Send an encrypted packet
    public func sendPacket(_ packet: SpotifyPacket) async throws {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        let serialized = packet.serialize()
        let (encrypted, mac) = await cipher.encrypt(serialized, nonce: sendNonce)
        sendNonce += 1

        var frame = encrypted
        frame.append(mac)
        try await send(raw: frame)
    }

    /// Receive and decrypt a packet
    private func receivePacket() async throws -> SpotifyPacket {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // Read header (3 bytes: command + 2-byte length)
        let header = try await receiveRaw(minLength: 3)
        let decryptedHeader = await cipher.decrypt(header, nonce: recvNonce)

        let command = decryptedHeader[0]
        let length = Int(decryptedHeader[1]) << 8 | Int(decryptedHeader[2])

        // Read payload + MAC
        let payloadAndMac = try await receiveRaw(minLength: length + 4)
        recvNonce += 1

        let payload = await cipher.decrypt(payloadAndMac.prefix(length), nonce: recvNonce - 1)

        return SpotifyPacket(rawCommand: command, payload: Data(payload))
    }

    // MARK: - Mercury RPC

    /// Send a Mercury request and wait for response
    public func mercury(uri: String, method: String = "GET", payload: [Data] = []) async throws -> MercuryResponse {
        let seqId = nextSequenceId
        nextSequenceId += 1

        let header = MercuryHeader(uri: uri, method: method)
        let request = MercuryRequest(sequenceId: seqId, header: header, payload: payload)

        // TODO: Serialize Mercury request to protobuf and send

        // Wait for response
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[seqId] = continuation
        }
    }

    /// Request an audio key for a track
    public func requestAudioKey(fileId: Data, trackId: Data) async throws -> Data {
        var payload = Data()
        payload.append(fileId)
        payload.append(trackId)

        let packet = SpotifyPacket(command: .requestKey, payload: payload)
        try await sendPacket(packet)

        // Wait for response (handled in receive loop)
        // TODO: Implement proper request/response tracking
        throw LibrespotError.notInitialized
    }

    // MARK: - Low-level I/O

    private func send(raw data: Data) async throws {
        guard let conn = connection else {
            throw LibrespotError.notInitialized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LibrespotError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveRaw(minLength: Int) async throws -> Data {
        guard let conn = connection else {
            throw LibrespotError.notInitialized
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: minLength, maximumLength: 65536) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: LibrespotError.connectionFailed(error.localizedDescription))
                } else if let data = content {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LibrespotError.connectionFailed("No data received"))
                }
            }
        }
    }

    // MARK: - Background Tasks

    private func receiveLoop() async {
        while isConnected {
            do {
                let packet = try await receivePacket()
                await handlePacket(packet)
            } catch {
                if isConnected {
                    debugLog("Accesspoint", "Receive error: \(error)")
                }
                break
            }
        }
    }

    private func handlePacket(_ packet: SpotifyPacket) async {
        switch packet.command {
        case .ping:
            // Respond with pong
            let pong = SpotifyPacket(command: .pong, payload: packet.payload)
            try? await sendPacket(pong)

        case .countryCode:
            let country = String(data: packet.payload, encoding: .utf8) ?? "??"
            debugLog("Accesspoint", "Country code: \(country)")

        case .mercuryEvent:
            // TODO: Parse and dispatch Mercury event
            break

        case .aesKey:
            // TODO: Handle audio key response
            break

        default:
            debugLog("Accesspoint", "Unhandled packet type: \(packet.command)")
        }
    }

    private func pingLoop() async {
        while isConnected {
            try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
            if isConnected {
                // AP expects us to respond to pings, not initiate them
                // The ping loop is mainly to detect disconnection
            }
        }
    }

    // MARK: - Helpers

    private func encodeVarint(_ value: UInt64) -> [UInt8] {
        var result: [UInt8] = []
        var v = value
        while v > 127 {
            result.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        result.append(UInt8(v))
        return result
    }
}
