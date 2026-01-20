//
//  KeyExchange.swift
//  SwiftLibrespot
//
//  Spotify key exchange protocol messages (manual protobuf implementation)
//

import Foundation

// MARK: - Enums

/// Product type for client identification
public enum SpotifyProduct: UInt32, Sendable {
    case client = 0
    case libspotify = 1
    case mobile = 2
    case partner = 3
    case libspotifyEmbedded = 5
}

/// Product flags
public enum SpotifyProductFlags: UInt32, Sendable {
    case none = 0
    case devBuild = 1
}

/// Platform identification
public enum SpotifyPlatform: UInt32, Sendable {
    case win32X86 = 0
    case osxX86 = 1
    case linuxX86 = 2
    case iphoneArm = 3
    case osxX8664 = 9
    case iphoneArm64 = 36
    case win32X8664 = 39
}

/// Cryptosuite type
public enum Cryptosuite: UInt32, Sendable {
    case shannon = 0
    case rc4Sha1Hmac = 1
}

/// Authentication error codes
public enum SpotifyErrorCode: UInt32, Sendable {
    case protocolError = 0
    case tryAnotherAP = 2
    case badConnectionId = 5
    case travelRestriction = 9
    case premiumAccountRequired = 11
    case badCredentials = 12
    case couldNotValidateCredentials = 13
    case accountExists = 14
    case extraVerificationRequired = 15
    case invalidAppKey = 16
    case applicationBanned = 17
}

// MARK: - Build Info

/// Build information for client identification
public struct BuildInfo: Sendable {
    public let product: SpotifyProduct
    public let productFlags: [SpotifyProductFlags]
    public let platform: SpotifyPlatform
    public let version: UInt64

    public nonisolated init(
        product: SpotifyProduct = .client,
        productFlags: [SpotifyProductFlags] = [.none],
        platform: SpotifyPlatform,
        version: UInt64,
    ) {
        self.product = product
        self.productFlags = productFlags
        self.platform = platform
        self.version = version
    }

    /// Serialize to protobuf binary format
    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): product (varint)
        data.append(contentsOf: [0x50]) // wire type 0, field 10
        data.append(contentsOf: encodeVarint(UInt64(product.rawValue)))

        // Field 20 (0x14): product_flags (repeated varint)
        for flag in productFlags {
            data.append(contentsOf: [0xA0, 0x01]) // wire type 0, field 20
            data.append(contentsOf: encodeVarint(UInt64(flag.rawValue)))
        }

        // Field 30 (0x1e): platform (varint)
        data.append(contentsOf: [0xF0, 0x01]) // wire type 0, field 30
        data.append(contentsOf: encodeVarint(UInt64(platform.rawValue)))

        // Field 40 (0x28): version (varint)
        data.append(contentsOf: [0xC0, 0x02]) // wire type 0, field 40
        data.append(contentsOf: encodeVarint(version))

        return data
    }
}

// MARK: - Login Crypto Hello

/// DH hello message
public struct LoginCryptoDiffieHellmanHello: Sendable {
    /// Our public key (gc)
    public let gc: Data
    /// Server keys known (always 1)
    public let serverKeysKnown: UInt32

    public nonisolated init(gc: Data, serverKeysKnown: UInt32 = 1) {
        self.gc = gc
        self.serverKeysKnown = serverKeysKnown
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): gc (bytes)
        data.append(contentsOf: [0x52]) // wire type 2, field 10
        data.append(contentsOf: encodeVarint(UInt64(gc.count)))
        data.append(gc)

        // Field 20 (0x14): server_keys_known (varint)
        data.append(contentsOf: [0xA0, 0x01]) // wire type 0, field 20
        data.append(contentsOf: encodeVarint(UInt64(serverKeysKnown)))

        return data
    }
}

/// Login crypto hello union
public struct LoginCryptoHelloUnion: Sendable {
    public let diffieHellman: LoginCryptoDiffieHellmanHello?

    public nonisolated init(diffieHellman: LoginCryptoDiffieHellmanHello?) {
        self.diffieHellman = diffieHellman
    }

    public nonisolated func serialize() -> Data {
        var data = Data()
        if let dh = diffieHellman {
            let dhData = dh.serialize()
            // Field 10 (0xa): diffie_hellman (message)
            data.append(contentsOf: [0x52]) // wire type 2, field 10
            data.append(contentsOf: encodeVarint(UInt64(dhData.count)))
            data.append(dhData)
        }
        return data
    }
}

// MARK: - Client Hello

/// ClientHello message sent to initiate connection
public struct ClientHello: Sendable {
    public let buildInfo: BuildInfo
    public let cryptosuitesSupported: [Cryptosuite]
    public let loginCryptoHello: LoginCryptoHelloUnion
    public let clientNonce: Data
    public let padding: Data?

    public nonisolated init(
        buildInfo: BuildInfo,
        cryptosuitesSupported: [Cryptosuite] = [.shannon],
        loginCryptoHello: LoginCryptoHelloUnion,
        clientNonce: Data,
        padding: Data? = Data([0x1E]),
    ) {
        self.buildInfo = buildInfo
        self.cryptosuitesSupported = cryptosuitesSupported
        self.loginCryptoHello = loginCryptoHello
        self.clientNonce = clientNonce
        self.padding = padding
    }

    /// Serialize to protobuf binary format
    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): build_info (message)
        let buildInfoData = buildInfo.serialize()
        data.append(contentsOf: [0x52]) // wire type 2, field 10
        data.append(contentsOf: encodeVarint(UInt64(buildInfoData.count)))
        data.append(buildInfoData)

        // Field 30 (0x1e): cryptosuites_supported (repeated varint)
        for suite in cryptosuitesSupported {
            data.append(contentsOf: [0xF0, 0x01]) // wire type 0, field 30
            data.append(contentsOf: encodeVarint(UInt64(suite.rawValue)))
        }

        // Field 50 (0x32): login_crypto_hello (message)
        let helloData = loginCryptoHello.serialize()
        data.append(contentsOf: [0x92, 0x03]) // wire type 2, field 50
        data.append(contentsOf: encodeVarint(UInt64(helloData.count)))
        data.append(helloData)

        // Field 60 (0x3c): client_nonce (bytes)
        data.append(contentsOf: [0xE2, 0x03]) // wire type 2, field 60
        data.append(contentsOf: encodeVarint(UInt64(clientNonce.count)))
        data.append(clientNonce)

        // Field 70 (0x46): padding (bytes, optional)
        if let padding {
            data.append(contentsOf: [0xB2, 0x04]) // wire type 2, field 70
            data.append(contentsOf: encodeVarint(UInt64(padding.count)))
            data.append(padding)
        }

        return data
    }
}

// MARK: - AP Response Message

/// DH challenge from server
public struct LoginCryptoDiffieHellmanChallenge: Sendable {
    /// Server's public key
    public let gs: Data
    /// Server signature key index
    public let serverSignatureKey: Int32
    /// Signature of gs
    public let gsSignature: Data

    public nonisolated init(gs: Data, serverSignatureKey: Int32, gsSignature: Data) {
        self.gs = gs
        self.serverSignatureKey = serverSignatureKey
        self.gsSignature = gsSignature
    }
}

/// Login crypto challenge union
public struct LoginCryptoChallengeUnion: Sendable {
    public let diffieHellman: LoginCryptoDiffieHellmanChallenge?

    public nonisolated init(diffieHellman: LoginCryptoDiffieHellmanChallenge?) {
        self.diffieHellman = diffieHellman
    }
}

/// AP challenge message
public struct APChallenge: Sendable {
    public let loginCryptoChallenge: LoginCryptoChallengeUnion
    public let serverNonce: Data

    public nonisolated init(loginCryptoChallenge: LoginCryptoChallengeUnion, serverNonce: Data) {
        self.loginCryptoChallenge = loginCryptoChallenge
        self.serverNonce = serverNonce
    }
}

/// Login failed message
public struct APLoginFailed: Sendable {
    public let errorCode: SpotifyErrorCode
    public let retryDelay: Int32?
    public let expiry: Int32?
    public let errorDescription: String?

    public nonisolated init(
        errorCode: SpotifyErrorCode,
        retryDelay: Int32? = nil,
        expiry: Int32? = nil,
        errorDescription: String? = nil,
    ) {
        self.errorCode = errorCode
        self.retryDelay = retryDelay
        self.expiry = expiry
        self.errorDescription = errorDescription
    }
}

/// AP response message (contains challenge or error)
public struct APResponseMessage: Sendable {
    public let challenge: APChallenge?
    public let loginFailed: APLoginFailed?

    public nonisolated init(challenge: APChallenge?, loginFailed: APLoginFailed?) {
        self.challenge = challenge
        self.loginFailed = loginFailed
    }

    /// Parse from protobuf binary data
    public nonisolated static func parse(from data: Data) throws -> APResponseMessage {
        var challenge: APChallenge?
        var loginFailed: APLoginFailed?

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 2): // challenge message
                let (msgData, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                challenge = try parseAPChallenge(from: msgData)

            case (30, 2): // login_failed message
                let (msgData, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                loginFailed = try parseAPLoginFailed(from: msgData)

            default:
                // Skip unknown field
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return APResponseMessage(challenge: challenge, loginFailed: loginFailed)
    }

    private nonisolated static func parseAPChallenge(from data: Data) throws -> APChallenge {
        var loginCryptoChallenge: LoginCryptoChallengeUnion?
        var serverNonce = Data()

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 2): // login_crypto_challenge
                let (msgData, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                loginCryptoChallenge = try parseLoginCryptoChallengeUnion(from: msgData)

            case (50, 2): // server_nonce
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                serverNonce = bytes

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        guard let crypto = loginCryptoChallenge else {
            throw LibrespotError.handshakeFailed("Missing login crypto challenge")
        }

        return APChallenge(loginCryptoChallenge: crypto, serverNonce: serverNonce)
    }

    private nonisolated static func parseLoginCryptoChallengeUnion(from data: Data) throws -> LoginCryptoChallengeUnion {
        var diffieHellman: LoginCryptoDiffieHellmanChallenge?

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 2): // diffie_hellman
                let (msgData, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                diffieHellman = try parseDHChallenge(from: msgData)

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return LoginCryptoChallengeUnion(diffieHellman: diffieHellman)
    }

    private nonisolated static func parseDHChallenge(from data: Data) throws -> LoginCryptoDiffieHellmanChallenge {
        var gs = Data()
        var serverSignatureKey: Int32 = 0
        var gsSignature = Data()

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 2): // gs
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                gs = bytes

            case (20, 0): // server_signature_key
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                serverSignatureKey = Int32(bitPattern: UInt32(truncatingIfNeeded: value))

            case (30, 2): // gs_signature
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                gsSignature = bytes

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return LoginCryptoDiffieHellmanChallenge(
            gs: gs,
            serverSignatureKey: serverSignatureKey,
            gsSignature: gsSignature,
        )
    }

    private nonisolated static func parseAPLoginFailed(from data: Data) throws -> APLoginFailed {
        var errorCode: SpotifyErrorCode = .protocolError
        var retryDelay: Int32?
        var expiry: Int32?
        var errorDescription: String?

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 0): // error_code
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                errorCode = SpotifyErrorCode(rawValue: UInt32(value)) ?? .protocolError

            case (20, 0): // retry_delay
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                retryDelay = Int32(value)

            case (30, 0): // expiry
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                expiry = Int32(value)

            case (40, 2): // error_description
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                errorDescription = String(data: bytes, encoding: .utf8)

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return APLoginFailed(
            errorCode: errorCode,
            retryDelay: retryDelay,
            expiry: expiry,
            errorDescription: errorDescription,
        )
    }
}

// MARK: - Client Response Plaintext

/// DH response with HMAC
public struct LoginCryptoDiffieHellmanResponse: Sendable {
    public let hmac: Data

    public nonisolated init(hmac: Data) {
        self.hmac = hmac
    }

    public nonisolated func serialize() -> Data {
        var data = Data()
        // Field 10 (0xa): hmac (bytes)
        data.append(contentsOf: [0x52]) // wire type 2, field 10
        data.append(contentsOf: encodeVarint(UInt64(hmac.count)))
        data.append(hmac)
        return data
    }
}

/// Login crypto response union
public struct LoginCryptoResponseUnion: Sendable {
    public let diffieHellman: LoginCryptoDiffieHellmanResponse?

    public nonisolated init(diffieHellman: LoginCryptoDiffieHellmanResponse?) {
        self.diffieHellman = diffieHellman
    }

    public nonisolated func serialize() -> Data {
        var data = Data()
        if let dh = diffieHellman {
            let dhData = dh.serialize()
            // Field 10 (0xa): diffie_hellman (message)
            data.append(contentsOf: [0x52]) // wire type 2, field 10
            data.append(contentsOf: encodeVarint(UInt64(dhData.count)))
            data.append(dhData)
        }
        return data
    }
}

/// PoW response union (empty for now)
public struct PoWResponseUnion: Sendable {
    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        Data()
    }
}

/// Crypto response union (empty for Shannon)
public struct CryptoResponseUnion: Sendable {
    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        Data()
    }
}

/// Client response after challenge
public struct ClientResponsePlaintext: Sendable {
    public let loginCryptoResponse: LoginCryptoResponseUnion
    public let powResponse: PoWResponseUnion
    public let cryptoResponse: CryptoResponseUnion

    public nonisolated init(
        loginCryptoResponse: LoginCryptoResponseUnion,
        powResponse: PoWResponseUnion = PoWResponseUnion(),
        cryptoResponse: CryptoResponseUnion = CryptoResponseUnion(),
    ) {
        self.loginCryptoResponse = loginCryptoResponse
        self.powResponse = powResponse
        self.cryptoResponse = cryptoResponse
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): login_crypto_response (message)
        let cryptoData = loginCryptoResponse.serialize()
        data.append(contentsOf: [0x52]) // wire type 2, field 10
        data.append(contentsOf: encodeVarint(UInt64(cryptoData.count)))
        data.append(cryptoData)

        // Field 20 (0x14): pow_response (message) - empty
        let powData = powResponse.serialize()
        if !powData.isEmpty {
            data.append(contentsOf: [0xA2, 0x01]) // wire type 2, field 20
            data.append(contentsOf: encodeVarint(UInt64(powData.count)))
            data.append(powData)
        }

        // Field 30 (0x1e): crypto_response (message) - empty
        let cryptoRespData = cryptoResponse.serialize()
        if !cryptoRespData.isEmpty {
            data.append(contentsOf: [0xF2, 0x01]) // wire type 2, field 30
            data.append(contentsOf: encodeVarint(UInt64(cryptoRespData.count)))
            data.append(cryptoRespData)
        }

        return data
    }
}

// MARK: - Protobuf Helpers

/// Encode a value as a varint
nonisolated func encodeVarint(_ value: UInt64) -> [UInt8] {
    var result: [UInt8] = []
    var v = value
    while v > 127 {
        result.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    }
    result.append(UInt8(v))
    return result
}

/// Parse a varint from data
nonisolated func parseVarint(data: Data, offset: Int) throws -> (UInt64, Int) {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    var currentOffset = offset

    while currentOffset < data.count {
        let byte = data[currentOffset]
        currentOffset += 1

        result |= UInt64(byte & 0x7F) << shift

        if byte & 0x80 == 0 {
            return (result, currentOffset)
        }

        shift += 7
        if shift >= 64 {
            throw LibrespotError.handshakeFailed("Varint too long")
        }
    }

    throw LibrespotError.handshakeFailed("Unexpected end of data while parsing varint")
}

/// Parse a protobuf tag (field number + wire type)
nonisolated func parseTag(data: Data, offset: Int) throws -> (fieldNumber: Int, wireType: Int, newOffset: Int) {
    let (value, newOffset) = try parseVarint(data: data, offset: offset)
    let wireType = Int(value & 0x7)
    let fieldNumber = Int(value >> 3)
    return (fieldNumber, wireType, newOffset)
}

/// Parse length-delimited bytes
nonisolated func parseBytes(data: Data, offset: Int) throws -> (Data, Int) {
    let (length, lengthOffset) = try parseVarint(data: data, offset: offset)
    let endOffset = lengthOffset + Int(length)
    guard endOffset <= data.count else {
        throw LibrespotError.handshakeFailed("Not enough bytes for length-delimited field")
    }
    return (data.subdata(in: lengthOffset ..< endOffset), endOffset)
}

/// Skip an unknown field
nonisolated func skipField(data: Data, offset: Int, wireType: Int) throws -> Int {
    switch wireType {
    case 0: // Varint
        let (_, newOffset) = try parseVarint(data: data, offset: offset)
        return newOffset
    case 1: // 64-bit
        return offset + 8
    case 2: // Length-delimited
        let (bytes, newOffset) = try parseBytes(data: data, offset: offset)
        _ = bytes
        return newOffset
    case 5: // 32-bit
        return offset + 4
    default:
        throw LibrespotError.handshakeFailed("Unknown wire type: \(wireType)")
    }
}
