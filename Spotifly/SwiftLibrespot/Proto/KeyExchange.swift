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

        /// `APLoginFailed { 10: error_code, 40: error_description }`, nested here or alone in
        /// an `AuthFailure` packet.
        init(_ fields: [ProtobufField]) {
            let code = fields.last(10).map { UInt32(truncatingIfNeeded: $0.value) }
            errorCode = code.flatMap(SpotifyErrorCode.init(rawValue:)) ?? .protocolError
            errorDescription = fields.last(40)?.string
        }
    }

    /// Nil unless the answer carries a Diffie-Hellman challenge.
    public let challenge: Challenge?
    public let loginFailed: LoginFailed?

    /// `APResponseMessage { 10: challenge, 30: login_failed }`, where the challenge nests as
    /// `login_crypto_challenge (10) → diffie_hellman (10) → { 10: gs, 30: gs_signature }`.
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
            loginFailed: refusal.map(LoginFailed.init),
        )
    }
}
