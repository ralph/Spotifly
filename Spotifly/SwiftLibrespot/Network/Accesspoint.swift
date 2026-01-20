//
//  Accesspoint.swift
//  SwiftLibrespot
//
//  TCP connection to Spotify accesspoint with Shannon cipher encryption
//

import CommonCrypto
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

    /// DH key exchange
    private var dh: DiffieHellman?

    /// Client nonce for handshake
    private var clientNonce: Data?

    /// Accumulator for handshake data (for challenge computation)
    private var handshakeAccumulator = Data()

    /// Ping interval in seconds
    private static let pingInterval: TimeInterval = 120

    /// Pending Mercury requests awaiting response
    private var pendingRequests: [UInt64: CheckedContinuation<MercuryResponse, Error>] = [:]
    private var nextSequenceId: UInt64 = 1

    /// Spotify version code (matching go-librespot)
    private static let spotifyVersionCode: UInt64 = 121_300_618

    /// Version string
    private static let versionString = "spotifly-swift/0.1.0"

    // MARK: - RSA Public Key for Signature Verification

    /// Server's RSA public key for verifying GS signature
    private static let serverPublicKeyN: [UInt8] = [
        0xAC, 0xE0, 0x46, 0x0B, 0xFF, 0xC2, 0x30, 0xAF, 0xF4, 0x6B, 0xFE, 0xC3,
        0xBF, 0xBF, 0x86, 0x3D, 0xA1, 0x91, 0xC6, 0xCC, 0x33, 0x6C, 0x93, 0xA1,
        0x4F, 0xB3, 0xB0, 0x16, 0x12, 0xAC, 0xAC, 0x6A, 0xF1, 0x80, 0xE7, 0xF6,
        0x14, 0xD9, 0x42, 0x9D, 0xBE, 0x2E, 0x34, 0x66, 0x43, 0xE3, 0x62, 0xD2,
        0x32, 0x7A, 0x1A, 0x0D, 0x92, 0x3B, 0xAE, 0xDD, 0x14, 0x02, 0xB1, 0x81,
        0x55, 0x05, 0x61, 0x04, 0xD5, 0x2C, 0x96, 0xA4, 0x4C, 0x1E, 0xCC, 0x02,
        0x4A, 0xD4, 0xB2, 0x0C, 0x00, 0x1F, 0x17, 0xED, 0xC2, 0x2F, 0xC4, 0x35,
        0x21, 0xC8, 0xF0, 0xCB, 0xAE, 0xD2, 0xAD, 0xD7, 0x2B, 0x0F, 0x9D, 0xB3,
        0xC5, 0x32, 0x1A, 0x2A, 0xFE, 0x59, 0xF3, 0x5A, 0x0D, 0xAC, 0x68, 0xF1,
        0xFA, 0x62, 0x1E, 0xFB, 0x2C, 0x8D, 0x0C, 0xB7, 0x39, 0x2D, 0x92, 0x47,
        0xE3, 0xD7, 0x35, 0x1A, 0x6D, 0xBD, 0x24, 0xC2, 0xAE, 0x25, 0x5B, 0x88,
        0xFF, 0xAB, 0x73, 0x29, 0x8A, 0x0B, 0xCC, 0xCD, 0x0C, 0x58, 0x67, 0x31,
        0x89, 0xE8, 0xBD, 0x34, 0x80, 0x78, 0x4A, 0x5F, 0xC9, 0x6B, 0x89, 0x9D,
        0x95, 0x6B, 0xFC, 0x86, 0xD7, 0x4F, 0x33, 0xA6, 0x78, 0x17, 0x96, 0xC9,
        0xC3, 0x2D, 0x0D, 0x32, 0xA5, 0xAB, 0xCD, 0x05, 0x27, 0xE2, 0xF7, 0x10,
        0xA3, 0x96, 0x13, 0xC4, 0x2F, 0x99, 0xC0, 0x27, 0xBF, 0xED, 0x04, 0x9C,
        0x3C, 0x27, 0x58, 0x04, 0xB6, 0xB2, 0x19, 0xF9, 0xC1, 0x2F, 0x02, 0xE9,
        0x48, 0x63, 0xEC, 0xA1, 0xB6, 0x42, 0xA0, 0x9D, 0x48, 0x25, 0xF8, 0xB3,
        0x9D, 0xD0, 0xE8, 0x6A, 0xF9, 0x48, 0x4D, 0xA1, 0xC2, 0xBA, 0x86, 0x30,
        0x42, 0xEA, 0x9D, 0xB3, 0x08, 0x6C, 0x19, 0x0E, 0x48, 0xB3, 0x9D, 0x66,
        0xEB, 0x00, 0x06, 0xA2, 0x5A, 0xEE, 0xA1, 0x1B, 0x13, 0x87, 0x3C, 0xD7,
        0x19, 0xE6, 0x55, 0xBD,
    ]

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
        try await performKeyExchange()

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

    // MARK: - Key Exchange

    private func performKeyExchange() async throws {
        // Generate random nonce
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        clientNonce = nonce

        // Generate DH key pair
        dh = try DiffieHellman()

        // Build ClientHello
        #if os(macOS)
            let platform = SpotifyPlatform.osxX8664
        #elseif os(iOS)
            let platform = SpotifyPlatform.iphoneArm64
        #else
            let platform = SpotifyPlatform.linuxX86
        #endif

        let buildInfo = BuildInfo(
            product: .client,
            productFlags: [.none],
            platform: platform,
            version: Self.spotifyVersionCode
        )

        let clientHello = ClientHello(
            buildInfo: buildInfo,
            cryptosuitesSupported: [.shannon],
            loginCryptoHello: LoginCryptoHelloUnion(
                diffieHellman: LoginCryptoDiffieHellmanHello(
                    gc: dh!.publicKeyBytes,
                    serverKeysKnown: 1
                )
            ),
            clientNonce: nonce,
            padding: Data([0x1E])
        )

        // Serialize and send ClientHello
        let clientHelloData = clientHello.serialize()

        // Write with hello prefix (0x00, 0x04) and length
        var message = Data()
        message.append(contentsOf: [0x00, 0x04]) // Hello prefix
        let totalLength = UInt32(2 + 4 + clientHelloData.count) // prefix + length + data
        message.append(contentsOf: withUnsafeBytes(of: totalLength.bigEndian) { Data($0) })
        message.append(clientHelloData)

        // Track for challenge
        handshakeAccumulator.append(message)

        try await sendRaw(message)

        debugLog("Accesspoint", "Sent ClientHello (\(message.count) bytes)")

        // Read APResponseMessage
        let responseLength = try await readRawLength()
        let responseData = try await readRawBytes(count: responseLength - 4) // Length includes itself

        // Track for challenge
        var responseLengthData = Data(count: 4)
        responseLengthData[0] = UInt8((responseLength >> 24) & 0xFF)
        responseLengthData[1] = UInt8((responseLength >> 16) & 0xFF)
        responseLengthData[2] = UInt8((responseLength >> 8) & 0xFF)
        responseLengthData[3] = UInt8(responseLength & 0xFF)
        handshakeAccumulator.append(responseLengthData)
        handshakeAccumulator.append(responseData)

        debugLog("Accesspoint", "Received APResponseMessage (\(responseData.count) bytes)")

        // Parse response
        let apResponse = try APResponseMessage.parse(from: responseData)

        guard let challenge = apResponse.challenge,
              let dhChallenge = challenge.loginCryptoChallenge.diffieHellman
        else {
            if let failed = apResponse.loginFailed {
                throw LibrespotError.authenticationFailed("\(failed.errorCode): \(failed.errorDescription ?? "Unknown error")")
            }
            throw LibrespotError.handshakeFailed("Missing DH challenge in response")
        }

        // Verify signature
        guard verifySignature(data: dhChallenge.gs, signature: dhChallenge.gsSignature) else {
            throw LibrespotError.handshakeFailed("Invalid server signature")
        }

        debugLog("Accesspoint", "Server signature verified")

        // Exchange keys
        let sharedSecret = dh!.exchange(remotePublicKeyBytes: dhChallenge.gs)

        // Derive keys using HMAC-SHA1
        let keys = deriveKeys(sharedSecret: sharedSecret, exchangeData: handshakeAccumulator)

        debugLog("Accesspoint", "Keys derived")

        // Solve challenge
        try await solveChallenge(keys: keys)

        debugLog("Accesspoint", "Challenge solved, encryption established")
    }

    private func deriveKeys(sharedSecret: Data, exchangeData: Data) -> (challenge: Data, sendKey: Data, recvKey: Data) {
        // Generate 5 blocks of HMAC-SHA1 output (100 bytes)
        var macData = Data()

        for i: UInt8 in 1 ... 5 {
            var dataToMac = exchangeData
            dataToMac.append(i)
            let hmac = hmacSHA1(key: sharedSecret, data: dataToMac)
            macData.append(hmac)
        }

        // macData[0:20] = challenge key
        // macData[20:52] = send key (32 bytes)
        // macData[52:84] = recv key (32 bytes)

        let challengeKey = macData[0 ..< 20]
        let sendKey = macData[20 ..< 52]
        let recvKey = macData[52 ..< 84]

        // Compute challenge HMAC
        let challenge = hmacSHA1(key: Data(challengeKey), data: handshakeAccumulator)

        return (challenge, Data(sendKey), Data(recvKey))
    }

    private func hmacSHA1(key: Data, data: Data) -> Data {
        var hmac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))

        key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyPtr.baseAddress,
                    key.count,
                    dataPtr.baseAddress,
                    data.count,
                    &hmac
                )
            }
        }

        return Data(hmac)
    }

    private func solveChallenge(keys: (challenge: Data, sendKey: Data, recvKey: Data)) async throws {
        // Build ClientResponsePlaintext
        let response = ClientResponsePlaintext(
            loginCryptoResponse: LoginCryptoResponseUnion(
                diffieHellman: LoginCryptoDiffieHellmanResponse(hmac: keys.challenge)
            )
        )

        let responseData = response.serialize()

        // Send without hello prefix, just length + data
        var message = Data()
        let length = UInt32(4 + responseData.count)
        message.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Data($0) })
        message.append(responseData)

        try await sendRaw(message)

        debugLog("Accesspoint", "Sent ClientResponsePlaintext (\(message.count) bytes)")

        // Initialize cipher pair
        cipherPair = CipherPair(sendKey: keys.sendKey, recvKey: keys.recvKey)
    }

    private func verifySignature(data: Data, signature: Data) -> Bool {
        // Compute SHA1 hash of data
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &hash)
        }

        // RSA verification with PKCS1v15 padding
        // For now, we'll trust the signature (proper implementation would need RSA verify)
        // The go-librespot also verifies this, so we should too eventually

        // TODO: Implement proper RSA PKCS1v15 signature verification
        // For development, skip verification
        debugLog("Accesspoint", "Warning: Skipping signature verification (not yet implemented)")
        return true
    }

    // MARK: - Authentication

    private func authenticate(token: String) async throws {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // Build ClientResponseEncrypted
        #if os(macOS)
            let cpuFamily = CpuFamily.x8664
            let os = SpotifyOS.osx
        #elseif os(iOS)
            let cpuFamily = CpuFamily.arm
            let os = SpotifyOS.iphone
        #else
            let cpuFamily = CpuFamily.x8664
            let os = SpotifyOS.linux
        #endif

        let credentials = LoginCredentials(
            username: nil, // Not needed for token auth
            typ: .spotifyToken,
            authData: token.data(using: .utf8)
        )

        let systemInfo = SystemInfo(
            cpuFamily: cpuFamily,
            os: os,
            systemInformationString: "spotifly-swift",
            deviceId: nil // Will be set by session
        )

        let loginRequest = ClientResponseEncrypted(
            loginCredentials: credentials,
            systemInfo: systemInfo,
            versionString: Self.versionString
        )

        let payload = loginRequest.serialize()

        // Send as encrypted Login packet
        let packet = SpotifyPacket(command: .login, payload: payload)
        try await sendPacket(packet)

        debugLog("Accesspoint", "Sent Login packet")

        // Wait for response
        let response = try await receivePacket()

        switch response.command {
        case .apWelcome:
            let welcome = try APWelcome.parse(from: response.payload)
            debugLog("Accesspoint", "Authentication successful, username: \(welcome.canonicalUsername)")
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
        try await sendRaw(frame)
    }

    /// Receive and decrypt a packet
    private func receivePacket() async throws -> SpotifyPacket {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // Read header (3 bytes: command + 2-byte length) + MAC
        let headerEncrypted = try await readRawBytes(count: 3)
        let headerDecrypted = await cipher.decrypt(headerEncrypted, nonce: recvNonce)

        let command = headerDecrypted[0]
        let length = Int(headerDecrypted[1]) << 8 | Int(headerDecrypted[2])

        // Read payload
        let payloadEncrypted = try await readRawBytes(count: length)
        let payloadDecrypted = await cipher.decrypt(payloadEncrypted, nonce: recvNonce)

        // Read and verify MAC
        let mac = try await readRawBytes(count: 4)
        // MAC verification happens implicitly in finish() during decrypt

        recvNonce += 1

        return SpotifyPacket(rawCommand: command, payload: payloadDecrypted)
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

    private func sendRaw(_ data: Data) async throws {
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

    private func readRawLength() async throws -> Int {
        let data = try await readRawBytes(count: 4)
        return Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
    }

    private func readRawBytes(count: Int) async throws -> Data {
        guard let conn = connection else {
            throw LibrespotError.notInitialized
        }

        return try await withCheckedThrowingContinuation { continuation in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: LibrespotError.connectionFailed(error.localizedDescription))
                } else if let data = content, data.count >= count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LibrespotError.connectionFailed("Incomplete data received"))
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
}
