//
//  KeyExchange.swift
//  SwiftLibrespot
//
//  The accesspoint handshake, from librespot's keyexchange.proto: the
//  ClientHello we send, the APResponseMessage it is answered with, and the
//  ClientResponsePlaintext that completes it.
//

import Foundation

/// The platform a ClientHello names.
public nonisolated enum SpotifyPlatform: UInt32, Sendable {
    case osxX86 = 1
    case linuxX86 = 2
    case osxX8664 = 9
    case iphoneArm64 = 36
}

/// Why the accesspoint refused a handshake or a login.
public nonisolated enum SpotifyErrorCode: UInt32, Sendable {
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

/// The two handshake messages the client sends.
///
/// The handshake HMAC covers the ClientHello byte for byte, so its fields — the one-byte
/// padding included — have to be exactly what librespot sends.
nonisolated enum KeyExchange {
    /// `ClientHello`: our build, our Diffie-Hellman public key and a nonce.
    static func clientHello(publicKey: Data, nonce: Data, platform: SpotifyPlatform, version: UInt64) -> Data {
        ProtobufWriter.message {
            $0.message(field: 10) { buildInfo in
                buildInfo.varint(field: 10, 0) // product: PRODUCT_CLIENT
                buildInfo.varint(field: 20, 0) // product_flags: PRODUCT_FLAG_NONE
                buildInfo.varint(field: 30, platform.rawValue)
                buildInfo.varint(field: 40, version)
            }
            $0.varint(field: 30, 0) // cryptosuites_supported: CRYPTO_SUITE_SHANNON
            $0.message(field: 50) { loginCryptoHello in
                loginCryptoHello.message(field: 10) { diffieHellman in
                    diffieHellman.bytes(field: 10, publicKey) // gc
                    diffieHellman.varint(field: 20, 1) // server_keys_known
                }
            }
            $0.bytes(field: 60, nonce) // client_nonce
            $0.bytes(field: 70, Data([0x1E])) // padding
        }
    }

    /// `ClientResponsePlaintext`: the HMAC proving we derived the same keys as the server.
    ///
    /// `pow_response` and `crypto_response` are required fields with nothing to say for
    /// Shannon, so they go out empty rather than not at all.
    static func clientResponsePlaintext(hmac: Data) -> Data {
        ProtobufWriter.message {
            $0.message(field: 10) { loginCryptoResponse in
                loginCryptoResponse.message(field: 10) { $0.bytes(field: 10, hmac) } // diffie_hellman.hmac
            }
            $0.message(field: 20) { _ in } // pow_response
            $0.message(field: 30) { _ in } // crypto_response
        }
    }
}

/// The accesspoint's answer to a ClientHello: a challenge to continue with, or a refusal.
public nonisolated struct APResponseMessage: Sendable {
    /// The server's Diffie-Hellman public key and its signature by Spotify's well-known key.
    public nonisolated struct Challenge: Sendable {
        public let gs: Data
        public let gsSignature: Data
    }

    public nonisolated struct LoginFailed: Sendable {
        public let errorCode: SpotifyErrorCode
        public let errorDescription: String?
    }

    /// Nil unless the answer carries a Diffie-Hellman challenge.
    public let challenge: Challenge?
    public let loginFailed: LoginFailed?

    /// `APResponseMessage { 10: challenge, 30: login_failed }`, where the challenge nests as
    /// `login_crypto_challenge (10) → diffie_hellman (10) → { 10: gs, 30: gs_signature }` and
    /// the refusal is `{ 10: error_code, 40: error_description }`.
    static func parse(from data: Data) -> APResponseMessage {
        let fields = ProtobufReader.fields(in: data)
        let diffieHellman = fields.last(10)?.fields.last(10)?.fields.last(10)?.fields
        let refusal = fields.last(30)?.fields

        return APResponseMessage(
            challenge: diffieHellman.map { diffieHellman in
                Challenge(
                    gs: diffieHellman.last(10)?.bytes ?? Data(),
                    gsSignature: diffieHellman.last(30)?.bytes ?? Data(),
                )
            },
            loginFailed: refusal.map { refusal in
                let code = refusal.last(10).map { UInt32(truncatingIfNeeded: $0.value) }
                return LoginFailed(
                    errorCode: code.flatMap(SpotifyErrorCode.init(rawValue:)) ?? .protocolError,
                    errorDescription: refusal.last(40)?.string,
                )
            },
        )
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
