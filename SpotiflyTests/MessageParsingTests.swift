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

/// `connect.proto` and `player.proto`.
struct ConnectMessageParsingTests {
    @Test func `a cluster update is read through its cluster, player state and device map`() throws {
        let data = ProtobufWriter.message {
            $0.message(field: 1) { cluster in
                cluster.varint(field: 1, 1_790_000_000_000) // changed_timestamp_ms
                cluster.string(field: 2, "phone") // active_device_id
                cluster.message(field: 3) { player in
                    player.varint(field: 1, 1_790_000_000_123) // timestamp
                    player.string(field: 2, "spotify:album:abc") // context_uri
                    player.message(field: 7) { track in
                        track.string(field: 1, "spotify:track:current")
                        track.map(field: 3, ["key": "value"]) // metadata
                    }
                    player.varint(field: 10, 42000) // position_as_of_timestamp
                    player.varint(field: 11, 200_000) // duration
                    player.bool(field: 12, true) // is_playing
                    player.message(field: 16) { $0.bool(field: 3, true) } // options.repeating_track
                    player.message(field: 20) { $0.string(field: 1, "spotify:track:next") } // next_tracks
                }
                cluster.message(field: 4) { entry in // map<string, DeviceInfo>
                    entry.string(field: 1, "phone")
                    entry.message(field: 2) { device in
                        device.bool(field: 1, true) // can_play
                        device.varint(field: 2, 32768) // volume
                        device.string(field: 3, "Phone") // name
                        device.varint(field: 7, 3) // device_type: SMARTPHONE
                        device.string(field: 10, "phone") // device_id
                    }
                }
                cluster.varint(field: 6, 1_789_999_000_000) // transfer_data_timestamp
                cluster.bool(field: 8, true) // need_full_player_state
            }
            $0.varint(field: 2, 2) // update_reason: DEVICE_STATE_CHANGED
            $0.string(field: 3, "ack") // ack_id
            $0.string(field: 4, "phone") // devices_that_changed
            $0.string(field: 4, "mac")
        }

        let update = try ClusterUpdateProto.parse(from: data)

        #expect(update.updateReason == .deviceStateChanged)
        #expect(update.ackId == "ack")
        #expect(update.devicesThatChanged == ["phone", "mac"])

        let cluster = update.cluster
        #expect(cluster.changedTimestampMs == 1_790_000_000_000)
        #expect(cluster.activeDeviceId == "phone")
        #expect(cluster.transferDataTimestamp == 1_789_999_000_000)
        #expect(cluster.needFullPlayerState)

        let device = try #require(cluster.devices["phone"])
        #expect(device.name == "Phone")
        #expect(device.volume == 32768)
        #expect(device.deviceType == .smartphone)
        #expect(device.deviceId == "phone")

        let player = try #require(cluster.playerState)
        #expect(player.timestamp == 1_790_000_000_123)
        #expect(player.contextUri == "spotify:album:abc")
        #expect(player.track?.uri == "spotify:track:current")
        #expect(player.track?.metadata == ["key": "value"])
        #expect(player.positionAsOfTimestamp == 42000)
        #expect(player.duration == 200_000)
        #expect(player.isPlaying)
        #expect(player.options.repeatingTrack)
        #expect(player.nextTracks.map(\.uri) == ["spotify:track:next"])
    }

    @Test func `the context fields are read at player.proto's numbers`() {
        let data = ProtobufWriter.message {
            $0.string(field: 3, "context://spotify:album:abc") // context_url
            $0.message(field: 6) { index in
                index.varint(field: 1, 1) // page
                index.varint(field: 2, 7) // track
            }
            $0.double(field: 9, 1.5) // playback_speed
            $0.map(field: 21, ["zeta": "1", "alpha": "2"]) // context_metadata
            $0.string(field: 24, "revision") // queue_revision
        }

        let state = PlayerState.parse(from: data)

        #expect(state.contextUrl == "context://spotify:album:abc")
        #expect(state.index == ContextIndex(page: 1, track: 7))
        #expect(state.playbackSpeed == 1.5)
        #expect(state.contextMetadata == ["zeta": "1", "alpha": "2"])
        #expect(state.queueRevision == "revision")
    }

    @Test func `the context fields are written at player.proto's numbers`() {
        var state = PlayerState()
        state.contextUrl = "context://spotify:album:abc"
        state.index = ContextIndex(page: 1, track: 7)
        state.playbackSpeed = 1.5
        state.contextMetadata = ["zeta": "1", "alpha": "2"]
        state.queueRevision = "revision"

        let fields = ProtobufReader.fields(in: state.serialize())

        #expect(fields.map(\.number) == [1, 3, 6, 9, 10, 11, 21, 21, 24, 25])
        #expect(fields.last(3)?.string == "context://spotify:album:abc")
        #expect(fields.last(6)?.fields.last(1)?.value == 1)
        #expect(fields.last(6)?.fields.last(2)?.value == 7)
        #expect(fields.last(9)?.double == 1.5)
        #expect(fields.filter { $0.number == 21 }.map(\.mapEntry.key) == ["alpha", "zeta"])
        #expect(fields.last(24)?.string == "revision")
    }

    @Test func `left at their defaults, the context fields stay off the wire`() {
        let fields = ProtobufReader.fields(in: PlayerState().serialize())

        #expect(fields.map(\.number) == [1, 10, 11, 25])
    }

    @Test func `track metadata goes out in key order`() {
        var track = ProvidedTrack(uri: "spotify:track:abc")
        track.metadata = ["c": "3", "a": "1", "b": "2"]

        let fields = ProtobufReader.fields(in: track.serialize())

        #expect(fields.filter { $0.number == 3 }.map(\.mapEntry.key) == ["a", "b", "c"])
    }
}
