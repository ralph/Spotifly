//
//  MessageParsingTests.swift
//  SpotiflyTests
//

import Foundation
@testable import Spotifly
import Testing

// The readers for the protobuf messages Spotify sends.
//
// Every input here is built with `ProtobufWriter` from librespot's .proto schema
// (`librespot/protocol/proto/`), not captured from a live session. The tests check that each
// reader follows the schema's field numbers and nesting — not what Spotify actually sends.

/// `keyexchange.proto` and `authentication.proto`.
struct AccesspointMessageParsingTests {
    @Test func `a Diffie-Hellman challenge is read through its nesting`() {
        let gs = Data(repeating: 0xAB, count: 96)
        let signature = Data(repeating: 0xCD, count: 256)
        let data = ProtobufWriter.message {
            $0.message(field: 10) { challenge in
                challenge.message(field: 10) { loginCryptoChallenge in
                    loginCryptoChallenge.message(field: 10) { diffieHellman in
                        diffieHellman.bytes(field: 10, gs)
                        diffieHellman.varint(field: 20, 0) // server_signature_key
                        diffieHellman.bytes(field: 30, signature)
                    }
                }
                challenge.message(field: 20) { _ in } // fingerprint_challenge
                challenge.message(field: 30) { _ in } // pow_challenge
                challenge.message(field: 40) { _ in } // crypto_challenge
                challenge.bytes(field: 50, Data(repeating: 0x01, count: 16)) // server_nonce
            }
        }

        let response = APResponseMessage.parse(from: data)

        #expect(response.challenge?.gs == gs)
        #expect(response.challenge?.gsSignature == signature)
        #expect(response.loginFailed == nil)
    }

    @Test func `a challenge without a Diffie-Hellman part is no challenge`() {
        let data = ProtobufWriter.message {
            $0.message(field: 10) { $0.message(field: 10) { _ in } }
        }

        #expect(APResponseMessage.parse(from: data).challenge == nil)
    }

    @Test func `a refusal carries its error code and description`() {
        let data = ProtobufWriter.message {
            $0.message(field: 30) { loginFailed in
                loginFailed.varint(field: 10, 12) // BadCredentials
                loginFailed.string(field: 40, "wrong password")
            }
        }

        let response = APResponseMessage.parse(from: data)

        #expect(response.challenge == nil)
        #expect(response.loginFailed?.errorCode == .badCredentials)
        #expect(response.loginFailed?.errorDescription == "wrong password")
    }

    @Test func `an unknown error code reads as a protocol error`() {
        let data = ProtobufWriter.message {
            $0.message(field: 30) { $0.varint(field: 10, 99) }
        }

        #expect(APResponseMessage.parse(from: data).loginFailed?.errorCode == .protocolError)
    }

    @Test func `the welcome yields the reusable credentials`() throws {
        let data = ProtobufWriter.message {
            $0.string(field: 10, "someone")
            $0.varint(field: 20, 0) // account_type_logged_in
            $0.varint(field: 25, 0) // credentials_type_logged_in
            $0.varint(field: 30, 1) // AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS
            $0.bytes(field: 40, Data([9, 8, 7]))
        }

        let welcome = try APWelcome.parse(from: data)

        #expect(welcome.canonicalUsername == "someone")
        #expect(welcome.reusableAuthCredentialsType == .storedSpotifyCredentials)
        #expect(welcome.reusableAuthCredentials == Data([9, 8, 7]))
    }

    @Test func `a welcome without a username is an error`() {
        let data = ProtobufWriter.message { $0.bytes(field: 40, Data([9, 8, 7])) }

        #expect(throws: LibrespotError.self) { try APWelcome.parse(from: data) }
    }
}
