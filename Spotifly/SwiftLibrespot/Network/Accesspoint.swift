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

    /// Pending audio key requests awaiting response
    private var pendingAudioKeyRequests: [UInt32: CheckedContinuation<Data, Error>] = [:]
    private var nextAudioKeySeq: UInt32 = 1

    /// Spotify version code (matching librespot-rs)
    private static let spotifyVersionCode: UInt64 = 124_200_290

    /// Version string (matching librespot-rs format)
    private static let versionString = "librespot 0.8.0"

    // MARK: - Shannon Cipher Test

    /// Test Shannon cipher with known test vectors
    /// Call this to verify the cipher implementation is correct
    public static func testShannonCipher() -> Bool {
        // Test vectors from https://github.com/twonky4/shannon
        let key = Data([0x65, 0x87, 0xD8, 0x8F, 0x6C, 0x32, 0x9D, 0x8A, 0xE4, 0x6B])
        let plaintext = "My secret message".data(using: .utf8)!
        let expectedCiphertext = Data([0x91, 0x9D, 0xA9, 0xB6, 0x29, 0xFC, 0x9C, 0xDD, 0x17, 0x8C, 0x15, 0x31, 0x9A, 0xAE, 0xCC, 0x6E, 0xD4])
        let expectedMac = Data([0xBE, 0x7B, 0xEF, 0x39, 0xEE, 0xFE, 0x54, 0xFD, 0x8D, 0xB0, 0xBC, 0x6F, 0xD5, 0x30, 0x35, 0x19])

        // Test WITHOUT nonce (raw encryption)
        let cipher = ShannonCipher(key: key)
        var data = plaintext
        cipher.encrypt(&data)
        let mac = cipher.finish(16)

        debugLog("Accesspoint", "=== SHANNON CIPHER TEST ===")
        debugLog("Accesspoint", "Key: \(key.hexString)")
        debugLog("Accesspoint", "Plaintext: \(String(data: plaintext, encoding: .utf8) ?? "?")")
        debugLog("Accesspoint", "Plaintext hex: \(plaintext.hexString)")
        debugLog("Accesspoint", "Expected ciphertext: \(expectedCiphertext.hexString)")
        debugLog("Accesspoint", "Actual ciphertext:   \(data.hexString)")
        debugLog("Accesspoint", "Expected MAC: \(expectedMac.hexString)")
        debugLog("Accesspoint", "Actual MAC:   \(mac.hexString)")
        debugLog("Accesspoint", "Ciphertext match: \(data == expectedCiphertext)")
        debugLog("Accesspoint", "MAC match: \(mac == expectedMac)")
        debugLog("Accesspoint", "=== END TEST ===")

        return data == expectedCiphertext && mac == expectedMac
    }

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

    public init(endpoint: String, preGeneratedDH: DiffieHellman? = nil) {
        self.endpoint = endpoint
        dh = preGeneratedDH
        debugLog("Accesspoint", "Created for endpoint: \(endpoint), pre-generated DH: \(preGeneratedDH != nil)")
    }

    // MARK: - Connection

    /// Connect and authenticate with credentials
    /// Returns the server's welcome message, whose reusable credentials are
    /// what later sessions log in from.
    @discardableResult
    public func connect(credentials: APCredentials, deviceId: String) async throws -> APWelcome {
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
        // Use a class wrapper to safely track if continuation was resumed (thread-safe)
        final class ResumeState: @unchecked Sendable {
            private var hasResumed = false
            private let lock = NSLock()

            func tryResume(_ continuation: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return false }
                hasResumed = true
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
                return true
            }
        }

        let resumeState = ResumeState()
        let conn = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            conn?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Clear handler and resume
                    conn?.stateUpdateHandler = nil
                    _ = resumeState.tryResume(continuation, with: .success(()))
                case let .failed(error):
                    _ = resumeState.tryResume(continuation, with: .failure(LibrespotError.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    _ = resumeState.tryResume(continuation, with: .failure(LibrespotError.connectionFailed("Connection cancelled")))
                default:
                    break
                }
            }
            conn?.start(queue: .global())
        }

        debugLog("Accesspoint", "TCP connected, performing handshake...")

        // Perform Diffie-Hellman key exchange (keys were pre-generated)
        try await performKeyExchange()

        debugLog("Accesspoint", "Handshake complete, authenticating...")

        // Authenticate with credentials and device ID
        let welcome = try await authenticate(credentials: credentials, deviceId: deviceId)

        isConnected = true
        debugLog("Accesspoint", "Connected and authenticated as \(welcome.canonicalUsername)")

        // Start receive loop
        Task {
            await receiveLoop()
        }

        // Start ping loop
        Task {
            await pingLoop()
        }

        return welcome
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

        // Use pre-generated DH key pair if available, otherwise generate now
        if dh == nil {
            debugLog("Accesspoint", "DH keys not pre-generated, generating now...")
            dh = try DiffieHellman()
        } else {
            debugLog("Accesspoint", "Using pre-generated DH keys")
        }

        // Build ClientHello
        // Platform must match librespot-rs for handshake HMAC to succeed
        // On macOS Apple Silicon, librespot-rs uses OSX_X86 (falls through to default)
        // because there's no explicit ARM case in their match statement
        #if os(macOS)
            #if arch(x86_64)
                let platform = SpotifyPlatform.osxX8664
            #else
                // Apple Silicon (arm64) - librespot uses osxX86 as default fallthrough
                let platform = SpotifyPlatform.osxX86
            #endif
        #elseif os(iOS)
            let platform = SpotifyPlatform.iphoneArm64
        #else
            let platform = SpotifyPlatform.linuxX86
        #endif

        let buildInfo = BuildInfo(
            product: .client,
            productFlags: [.none],
            platform: platform,
            version: Self.spotifyVersionCode,
        )

        let clientHello = ClientHello(
            buildInfo: buildInfo,
            cryptosuitesSupported: [.shannon],
            loginCryptoHello: LoginCryptoHelloUnion(
                diffieHellman: LoginCryptoDiffieHellmanHello(
                    gc: dh!.publicKeyBytes,
                    serverKeysKnown: 1,
                ),
            ),
            clientNonce: nonce,
            padding: Data([0x1E]),
        )

        // Serialize and send ClientHello
        let clientHelloData = clientHello.serialize()

        debugLog("Accesspoint", "ClientHello protobuf: \(clientHelloData.count) bytes, first 32: \(clientHelloData.prefix(32).hexString)")
        debugLog("Accesspoint", "DH public key: \(dh!.publicKeyBytes.count) bytes, first 16: \(dh!.publicKeyBytes.prefix(16).hexString)")

        // Write with hello prefix (0x00, 0x04) and length
        var message = Data()
        message.append(contentsOf: [0x00, 0x04]) // Hello prefix
        let totalLength = UInt32(2 + 4 + clientHelloData.count) // prefix + length + data
        message.append(contentsOf: withUnsafeBytes(of: totalLength.bigEndian) { Data($0) })
        message.append(clientHelloData)

        debugLog("Accesspoint", "Full message: \(message.count) bytes, first 32: \(message.prefix(32).hexString)")

        // Track for challenge - include the FULL message with framing (per librespot)
        // The accumulator must include: 0x00 0x04 prefix + 4-byte length + protobuf
        handshakeAccumulator.append(message)

        try await sendRaw(message)

        debugLog("Accesspoint", "Sent ClientHello (\(message.count) bytes)")

        // Read APResponseMessage
        debugLog("Accesspoint", "Waiting for server response...")
        let responseLengthBytes = try await readRawBytes(count: 4)
        let responseLength = Int(responseLengthBytes[0]) << 24 | Int(responseLengthBytes[1]) << 16 |
            Int(responseLengthBytes[2]) << 8 | Int(responseLengthBytes[3])
        debugLog("Accesspoint", "Got response length: \(responseLength)")
        let responseData = try await readRawBytes(count: responseLength - 4) // Length includes itself

        // Track for challenge - include the 4-byte length prefix AND protobuf data (per librespot)
        handshakeAccumulator.append(responseLengthBytes)
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
        debugLog("Accesspoint", "Server DH public key: \(dhChallenge.gs.count) bytes, first 16: \(dhChallenge.gs.prefix(16).hexString)")
        let sharedSecret = dh!.exchange(remotePublicKeyBytes: dhChallenge.gs)

        // Derive keys using HMAC-SHA1
        let keys = deriveKeys(sharedSecret: sharedSecret, exchangeData: handshakeAccumulator)

        debugLog("Accesspoint", "Keys derived")

        // Solve challenge
        try await solveChallenge(keys: keys)

        debugLog("Accesspoint", "Challenge solved, encryption established")
    }

    private func deriveKeys(sharedSecret: Data, exchangeData: Data) -> (challenge: Data, sendKey: Data, recvKey: Data) {
        debugLog("Accesspoint", "Deriving keys from shared secret (\(sharedSecret.count) bytes), exchange data (\(exchangeData.count) bytes)")
        debugLog("Accesspoint", "Shared secret (first 16): \(sharedSecret.prefix(16).hexString)")

        // Generate 5 blocks of HMAC-SHA1 output (100 bytes)
        var macData = Data()

        for i: UInt8 in 1 ... 5 {
            var dataToMac = exchangeData
            dataToMac.append(i)
            let hmac = hmacSHA1(key: sharedSecret, data: dataToMac)
            macData.append(hmac)
            if i == 1 {
                debugLog("Accesspoint", "HMAC input 1 size: \(dataToMac.count), last 8 bytes: \(dataToMac.suffix(8).hexString)")
                debugLog("Accesspoint", "HMAC output 1: \(hmac.hexString)")
            }
        }

        // macData[0:20] = challenge key
        // macData[20:52] = send key (32 bytes)
        // macData[52:84] = recv key (32 bytes)

        let challengeKey = Data(macData[0 ..< 20])
        let sendKey = Data(macData[20 ..< 52])
        let recvKey = Data(macData[52 ..< 84])

        let sendKeyHex = sendKey.prefix(16).map { String(format: "%02x", $0) }.joined()
        let recvKeyHex = recvKey.prefix(16).map { String(format: "%02x", $0) }.joined()
        debugLog("Accesspoint", "Send key (first 16): \(sendKeyHex)")
        debugLog("Accesspoint", "Recv key (first 16): \(recvKeyHex)")

        // Compute challenge HMAC using the same exchange data (not the actor property)
        debugLog("Accesspoint", "Challenge key (20 bytes): \(challengeKey.hexString)")
        debugLog("Accesspoint", "Accumulator size: \(exchangeData.count) bytes")
        debugLog("Accesspoint", "Accumulator first 32: \(exchangeData.prefix(32).hexString)")
        debugLog("Accesspoint", "Accumulator last 32: \(exchangeData.suffix(32).hexString)")
        let challenge = hmacSHA1(key: Data(challengeKey), data: exchangeData)
        debugLog("Accesspoint", "Challenge HMAC: \(challenge.hexString)")

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
                    &hmac,
                )
            }
        }

        return Data(hmac)
    }

    private func solveChallenge(keys: (challenge: Data, sendKey: Data, recvKey: Data)) async throws {
        // Build ClientResponsePlaintext
        let response = ClientResponsePlaintext(
            loginCryptoResponse: LoginCryptoResponseUnion(
                diffieHellman: LoginCryptoDiffieHellmanResponse(hmac: keys.challenge),
            ),
        )

        let responseData = response.serialize()
        debugLog("Accesspoint", "ClientResponsePlaintext protobuf: \(responseData.count) bytes, hex: \(responseData.hexString)")

        // Send without hello prefix, just length + data
        var message = Data()
        let length = UInt32(4 + responseData.count)
        message.append(contentsOf: withUnsafeBytes(of: length.bigEndian) { Data($0) })
        message.append(responseData)

        try await sendRaw(message)

        debugLog("Accesspoint", "Sent ClientResponsePlaintext (\(message.count) bytes, including 4-byte length)")

        // Initialize cipher pair
        cipherPair = CipherPair(sendKey: keys.sendKey, recvKey: keys.recvKey)
    }

    private func verifySignature(data: Data, signature _: Data) -> Bool {
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

    /// Authenticates and returns the server welcome.
    ///
    /// A `APCredentials` carries either an OAuth access token (the first
    /// login, minted by the browser grant) or a previously captured reusable
    /// blob (`storedAuthData`) — the same two paths librespot supports. The
    /// welcome's own reusable credentials are what every later session logs in
    /// from, so a browser grant happens once per machine.
    private func authenticate(credentials: APCredentials, deviceId: String) async throws -> APWelcome {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // CPU family must match the actual architecture (ARM for Apple Silicon, x86_64 for Intel)
        #if arch(arm64)
            let cpuFamily = CpuFamily.arm
        #elseif arch(x86_64)
            let cpuFamily = CpuFamily.x8664
        #else
            let cpuFamily = CpuFamily.unknown
        #endif

        #if os(macOS)
            let os = SpotifyOS.osx
        #elseif os(iOS)
            let os = SpotifyOS.iphone
        #else
            let os = SpotifyOS.linux
        #endif

        let loginCredentials: LoginCredentials
        if let authData = credentials.storedAuthData {
            debugLog("Accesspoint", "Authenticating with reusable credentials as \(credentials.username)")
            loginCredentials = LoginCredentials(
                username: credentials.username,
                typ: .storedSpotifyCredentials,
                authData: authData,
            )
        } else {
            debugLog("Accesspoint", "Authenticating with OAuth token as \(credentials.username)")
            loginCredentials = LoginCredentials(
                username: credentials.username,
                typ: .spotifyToken,
                authData: credentials.accessToken?.data(using: .utf8),
            )
        }

        let systemInfo = SystemInfo(
            cpuFamily: cpuFamily,
            os: os,
            systemInformationString: Self.versionString,
            deviceId: deviceId,
        )

        let loginRequest = ClientResponseEncrypted(
            loginCredentials: loginCredentials,
            systemInfo: systemInfo,
            versionString: Self.versionString,
        )

        // Send as encrypted Login packet
        let packet = SpotifyPacket(command: .login, payload: loginRequest.serialize())
        try await sendPacket(packet)

        debugLog("Accesspoint", "Login packet sent; waiting for response...")

        // Check if server sent unencrypted error response. The server uses a 4-byte
        // big-endian length prefix for unencrypted messages vs 3-byte encrypted
        // header for Shannon packets; three zero bytes never occur in ciphertext by accident.
        let firstFourBytes = try await readRawBytes(count: 4)
        let potentialLength = Int(firstFourBytes[0]) << 24 | Int(firstFourBytes[1]) << 16 |
            Int(firstFourBytes[2]) << 8 | Int(firstFourBytes[3])

        if firstFourBytes[0] == 0, firstFourBytes[1] == 0, firstFourBytes[2] == 0, potentialLength < 1000 {
            // The length INCLUDES the 4-byte prefix itself.
            let dataLength = potentialLength - 4
            let errorData = try await readRawBytes(count: dataLength)

            if let errorResponse = try? APResponseMessage.parse(from: errorData),
               let loginFailed = errorResponse.loginFailed
            {
                debugLog("Accesspoint", "Login failed: \(loginFailed.errorCode), desc: \(loginFailed.errorDescription ?? "none")")
                throw LibrespotError.authenticationFailed("Server rejected: \(loginFailed.errorCode)")
            }
            throw LibrespotError.authenticationFailed("Challenge verification failed (unencrypted error)")
        }

        // Normal encrypted response; we already consumed its first bytes above.
        let response = try await receivePacketWithPrefix(firstFourBytes)

        switch response.command {
        case .apWelcome:
            return try APWelcome.parse(from: response.payload)
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
        debugLog("Accesspoint", "Sending packet: cmd=0x\(String(format: "%02X", packet.rawCommand)), payload=\(packet.payload.count) bytes, serialized=\(serialized.count) bytes, nonce=\(sendNonce)")
        debugLog("Accesspoint", "Serialized packet header: \(serialized.prefix(3).hexString)")
        debugLog("Accesspoint", "Pre-encryption frame: \(serialized.count) bytes, first 16: \(serialized.prefix(16).hexString)")
        let (encrypted, mac) = await cipher.encrypt(serialized, nonce: sendNonce)
        sendNonce += 1

        var frame = encrypted
        frame.append(mac)
        debugLog("Accesspoint", "Encrypted frame: \(frame.count) bytes (encrypted=\(encrypted.count), mac=\(mac.count))")
        debugLog("Accesspoint", "Post-encryption first 16: \(frame.prefix(16).hexString), mac: \(mac.hexString)")
        try await sendRaw(frame)
    }

    /// Receive and decrypt a packet
    private func receivePacket() async throws -> SpotifyPacket {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // Begin decryption session with current nonce
        await cipher.beginDecrypt(nonce: recvNonce)

        // Read and decrypt header (3 bytes: command + 2-byte length)
        let headerEncrypted = try await readRawBytes(count: 3)
        debugLog("Accesspoint", "Header encrypted: \(headerEncrypted.map { String(format: "%02X", $0) }.joined(separator: " ")), nonce=\(recvNonce)")
        let headerDecrypted = await cipher.decryptPart(headerEncrypted)
        debugLog("Accesspoint", "Header decrypted: \(headerDecrypted.map { String(format: "%02X", $0) }.joined(separator: " "))")

        let command = headerDecrypted[0]
        let length = Int(headerDecrypted[1]) << 8 | Int(headerDecrypted[2])
        debugLog("Accesspoint", "Packet header: cmd=0x\(String(format: "%02X", command)), length=\(length)")

        // Read and decrypt payload (continues cipher stream from header)
        let payloadDecrypted: Data
        if length > 0 {
            let payloadEncrypted = try await readRawBytes(count: length)
            payloadDecrypted = await cipher.decryptPart(payloadEncrypted)
        } else {
            payloadDecrypted = Data()
        }

        // Finish decryption and get expected MAC
        let expectedMac = await cipher.finishDecrypt()

        // Read and verify MAC
        let receivedMac = try await readRawBytes(count: 4)
        if expectedMac != receivedMac {
            debugLog("Accesspoint", "MAC mismatch! expected=\(expectedMac.hexString) received=\(receivedMac.hexString)")
            throw LibrespotError.macMismatch
        }

        recvNonce += 1

        return SpotifyPacket(rawCommand: command, payload: payloadDecrypted)
    }

    /// Receive and decrypt a packet where we've already read the first 4 bytes
    /// This handles the case where we needed to peek at bytes to check for unencrypted error
    private func receivePacketWithPrefix(_ prefixBytes: Data) async throws -> SpotifyPacket {
        guard let cipher = cipherPair else {
            throw LibrespotError.notInitialized
        }

        // Begin decryption session with current nonce
        await cipher.beginDecrypt(nonce: recvNonce)

        // First 3 bytes are the encrypted header
        let headerEncrypted = Data(prefixBytes.prefix(3))
        debugLog("Accesspoint", "Header encrypted (from prefix): \(headerEncrypted.map { String(format: "%02X", $0) }.joined(separator: " ")), nonce=\(recvNonce)")
        let headerDecrypted = await cipher.decryptPart(headerEncrypted)
        debugLog("Accesspoint", "Header decrypted: \(headerDecrypted.map { String(format: "%02X", $0) }.joined(separator: " "))")

        let command = headerDecrypted[0]
        let length = Int(headerDecrypted[1]) << 8 | Int(headerDecrypted[2])
        debugLog("Accesspoint", "Packet header: cmd=0x\(String(format: "%02X", command)), length=\(length)")

        // The 4th prefix byte is the first payload byte (if any)
        var payloadParts = Data()
        if prefixBytes.count > 3 {
            payloadParts.append(prefixBytes[3])
        }

        // Read remaining payload bytes if needed
        let remainingPayloadBytes = length - payloadParts.count
        if remainingPayloadBytes > 0 {
            let morePayload = try await readRawBytes(count: remainingPayloadBytes)
            payloadParts.append(morePayload)
        }

        // Decrypt payload
        let payloadDecrypted = payloadParts.isEmpty ? Data() : await cipher.decryptPart(payloadParts)

        // Finish decryption and get expected MAC
        let expectedMac = await cipher.finishDecrypt()

        // Read and verify MAC
        let receivedMac = try await readRawBytes(count: 4)
        if expectedMac != receivedMac {
            debugLog("Accesspoint", "MAC mismatch! expected=\(expectedMac.hexString) received=\(receivedMac.hexString)")
            throw LibrespotError.macMismatch
        }

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
        guard isConnected else {
            throw LibrespotError.notInitialized
        }

        let seqId = nextAudioKeySeq
        nextAudioKeySeq += 1

        // Build request payload:
        // - 20 bytes: file ID
        // - 16 bytes: track ID (gid)
        // - 4 bytes: sequence ID (big-endian)
        // - 2 bytes: 0x00 0x00 (unknown)
        var payload = Data()

        // Ensure file ID is exactly 20 bytes
        if fileId.count >= 20 {
            payload.append(fileId.prefix(20))
        } else {
            payload.append(fileId)
            payload.append(Data(repeating: 0, count: 20 - fileId.count))
        }

        // Ensure track ID is exactly 16 bytes
        if trackId.count >= 16 {
            payload.append(trackId.prefix(16))
        } else {
            payload.append(trackId)
            payload.append(Data(repeating: 0, count: 16 - trackId.count))
        }

        // Sequence ID (big-endian)
        var seqBE = seqId.bigEndian
        payload.append(Data(bytes: &seqBE, count: 4))

        // Unknown bytes
        payload.append(contentsOf: [0x00, 0x00])

        debugLog("Accesspoint", "Requesting audio key, seq=\(seqId), fileId=\(fileId.prefix(8).hexString)")

        let packet = SpotifyPacket(command: .requestKey, payload: payload)
        try await sendPacket(packet)

        // Wait for response
        return try await withCheckedThrowingContinuation { continuation in
            pendingAudioKeyRequests[seqId] = continuation

            // Add timeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                guard let self else { return }
                if let cont = await removePendingAudioKeyRequest(seqId) {
                    cont.resume(throwing: LibrespotError.timeout("Audio key request timed out"))
                }
            }
        }
    }

    /// Remove and return a pending audio key request
    private func removePendingAudioKeyRequest(_ seqId: UInt32) -> CheckedContinuation<Data, Error>? {
        pendingAudioKeyRequests.removeValue(forKey: seqId)
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

    private func readRawBytes(count: Int, timeout: TimeInterval = 10.0) async throws -> Data {
        guard let conn = connection else {
            throw LibrespotError.notInitialized
        }

        // Use actor-based result holder
        actor ReadResult {
            var data: Data?
            var error: Error?
            var completed = false

            func setResult(_ data: Data) {
                if !completed {
                    self.data = data
                    completed = true
                }
            }

            func setError(_ error: Error) {
                if !completed {
                    self.error = error
                    completed = true
                }
            }

            func getState() -> (completed: Bool, data: Data?, error: Error?) {
                (completed, data, error)
            }
        }

        let result = ReadResult()

        // Start the read on the connection
        debugLog("Accesspoint", "Starting receive for \(count) bytes, conn state: \(conn.state)")
        conn.receive(minimumIncompleteLength: count, maximumLength: count) { [result] content, _, isComplete, error in
            debugLog("Accesspoint", "Receive callback fired! content=\(content?.count ?? 0) isComplete=\(isComplete) error=\(String(describing: error))")
            Task {
                if let error {
                    debugLog("Accesspoint", "readRawBytes(\(count)) error: \(error)")
                    await result.setError(LibrespotError.connectionFailed(error.localizedDescription))
                } else if let data = content, data.count >= count {
                    await result.setResult(data)
                } else {
                    let receivedCount = content?.count ?? 0
                    debugLog("Accesspoint", "readRawBytes(\(count)) incomplete: got \(receivedCount) bytes, isComplete=\(isComplete)")
                    await result.setError(LibrespotError.connectionFailed("Incomplete data received (expected \(count), got \(receivedCount))"))
                }
            }
        }

        // Poll for result with timeout
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await result.getState()
            if state.completed {
                if let data = state.data {
                    return data
                } else if let error = state.error {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        throw LibrespotError.connectionFailed("Read timeout after \(timeout) seconds")
    }

    /// Peek raw bytes without consuming them (for error detection)
    private func peekRawBytes(count: Int) async throws -> Data {
        // NWConnection doesn't support peek natively, so we read the bytes
        // and the caller must pass them to receivePacketWithPeeked
        try await readRawBytes(count: count)
    }

    /// Receive and decrypt a packet, using already-peeked data for the start
    private func receivePacketWithPeeked(_ peekedData: Data) async throws -> SpotifyPacket {
        debugLog("Accesspoint", "receivePacketWithPeeked called with \(peekedData.count) bytes")
        guard let cipher = cipherPair else {
            debugLog("Accesspoint", "ERROR: cipher not initialized")
            throw LibrespotError.notInitialized
        }

        debugLog("Accesspoint", "About to beginDecrypt with nonce=\(recvNonce)")
        // Begin decryption session with current nonce
        await cipher.beginDecrypt(nonce: recvNonce)
        debugLog("Accesspoint", "beginDecrypt complete")

        // Use the first 3 bytes from peeked data as header
        let headerEncrypted = peekedData.prefix(3)
        debugLog("Accesspoint", "Header encrypted (from peek): \(headerEncrypted.map { String(format: "%02X", $0) }.joined(separator: " ")), nonce=\(recvNonce)")
        let headerDecrypted = await cipher.decryptPart(Data(headerEncrypted))
        debugLog("Accesspoint", "Header decrypted: \(headerDecrypted.map { String(format: "%02X", $0) }.joined(separator: " "))")

        let command = headerDecrypted[0]
        let length = Int(headerDecrypted[1]) << 8 | Int(headerDecrypted[2])
        debugLog("Accesspoint", "Packet header: cmd=0x\(String(format: "%02X", command)), length=\(length)")

        // Calculate how many more bytes we need for the payload
        // We already have (peekedData.count - 3) bytes that are part of the payload
        let peekedPayloadBytes = peekedData.count - 3
        var payloadParts = Data()

        // Use any payload bytes we already have from peeked data
        if peekedPayloadBytes > 0 {
            let availablePayload = peekedData.dropFirst(3)
            payloadParts.append(contentsOf: availablePayload)
        }

        // Read remaining payload bytes if needed
        let remainingPayloadBytes = length - peekedPayloadBytes
        if remainingPayloadBytes > 0 {
            let morePayload = try await readRawBytes(count: remainingPayloadBytes)
            payloadParts.append(morePayload)
        }

        // Decrypt the payload
        let payloadDecrypted = payloadParts.isEmpty ? Data() : await cipher.decryptPart(payloadParts)

        // Finish decryption and get expected MAC
        let expectedMac = await cipher.finishDecrypt()

        // Read and verify MAC
        let receivedMac = try await readRawBytes(count: 4)
        if expectedMac != receivedMac {
            debugLog("Accesspoint", "MAC mismatch! expected=\(expectedMac.hexString) received=\(receivedMac.hexString)")
            throw LibrespotError.macMismatch
        }

        recvNonce += 1

        return SpotifyPacket(rawCommand: command, payload: payloadDecrypted)
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
            // Audio key response format:
            // - 4 bytes: sequence ID (big-endian)
            // - 16 bytes: AES key
            guard packet.payload.count >= 20 else {
                debugLog("Accesspoint", "Invalid audio key response length: \(packet.payload.count)")
                return
            }

            let seqId = packet.payload.subdata(in: 0 ..< 4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let audioKey = packet.payload.subdata(in: 4 ..< 20)

            debugLog("Accesspoint", "Received audio key for seq=\(seqId), key=\(audioKey.prefix(4).hexString)...")

            if let continuation = pendingAudioKeyRequests.removeValue(forKey: seqId) {
                continuation.resume(returning: audioKey)
            }

        case .aesKeyError:
            // Audio key error response
            guard packet.payload.count >= 6 else {
                debugLog("Accesspoint", "Invalid audio key error response")
                return
            }

            let seqId = packet.payload.subdata(in: 0 ..< 4).withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            let errorCode = packet.payload.subdata(in: 4 ..< 6).withUnsafeBytes {
                UInt16(bigEndian: $0.load(as: UInt16.self))
            }

            debugLog("Accesspoint", "Audio key error for seq=\(seqId), code=\(errorCode)")

            if let continuation = pendingAudioKeyRequests.removeValue(forKey: seqId) {
                continuation.resume(throwing: LibrespotError.audioKeyError(Int(errorCode)))
            }

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
