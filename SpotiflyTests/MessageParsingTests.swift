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

    /// Measured on the web player, 2026-10-01: an album's last track with repeat off names reasons
    /// for other things, and none for Next.
    @Test func `a reason not to skip next is read from the restrictions, and others are not one`() {
        let other = PlayerState.parse(from: ProtobufWriter.message {
            $0.message(field: 17) { restrictions in
                restrictions.string(field: 2, "not_paused")
                restrictions.string(field: 6, "no_prev_track")
            }
        })
        let next = PlayerState.parse(from: ProtobufWriter.message {
            $0.message(field: 17) { $0.string(field: 7, "no_next_track") }
        })

        #expect(!other.disallowsSkippingNext)
        #expect(next.disallowsSkippingNext)
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

    /// `Capabilities.disable_volume` is field 13 in connect.proto; `supported_types` is 9.
    @Test func `a device that refuses volume says so, and lists only its own types`() {
        let refusing = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.string(field: 9, "audio/track")
            $0.bool(field: 13, true)
        })
        let accepting = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.string(field: 9, "audio/track")
        })

        #expect(refusing.disableVolume)
        #expect(!accepting.disableVolume)
        #expect(refusing.supportedTypes == ["audio/track"])
    }

    @Test func `track metadata goes out in key order`() {
        var track = ProvidedTrack(uri: "spotify:track:abc")
        track.metadata = ["c": "3", "a": "1", "b": "2"]

        let fields = ProtobufReader.fields(in: track.serialize())

        #expect(fields.filter { $0.number == 3 }.map(\.mapEntry.key) == ["a", "b", "c"])
    }
}

/// `metadata.proto`, and `extended_metadata.proto` with `entity_extension_data.proto`.
@MainActor
struct SPClientParsingTests {
    /// `Track.file (12)`: `AudioFile { 1: file_id, 2: format }`, the id twenty bytes of `id`.
    private static func file(_ track: inout ProtobufWriter, id: UInt8, format: Int) {
        track.message(field: 12) {
            $0.bytes(field: 1, Data(repeating: id, count: 20))
            $0.varint(field: 2, format)
        }
    }

    /// A `Track` wrapped the way the extended-metadata endpoint answers with one, or, without
    /// one, the way it answers for an entity it has none of.
    private static func extendedMetadataResponse(track: Data?, status: Int = 200) -> Data {
        ProtobufWriter.message {
            $0.message(field: 2) { array in // extended_metadata
                array.varint(field: 2, 10) // extension_kind: TRACK_V4
                array.message(field: 3) { entry in // extension_data
                    entry.message(field: 1) { $0.varint(field: 1, status) } // header.status_code
                    entry.string(field: 2, "spotify:track:abc") // entity_uri
                    if let track {
                        entry.message(field: 3) { any in // google.protobuf.Any
                            any.string(field: 1, "type.googleapis.com/spotify.metadata.Track")
                            any.bytes(field: 2, track)
                        }
                    }
                }
            }
        }
    }

    private static func ids(_ files: [SPClient.TrackMetadata.AudioFile]) -> [UInt8] {
        files.map { $0.fileId.first ?? 0 }
    }

    private static func parse(_ track: Data) -> SPClient.TrackMetadata? {
        SPClient.parseTrackResponse(extendedMetadataResponse(track: track))
    }

    @Test func `the extended-metadata answer yields the wrapped track's files`() throws {
        let track = ProtobufWriter.message {
            $0.string(field: 2, "Song") // name
            Self.file(&$0, id: 1, format: 1) // OGG_VORBIS_160
            Self.file(&$0, id: 2, format: 2) // OGG_VORBIS_320
        }

        let files = try #require(Self.parse(track)).files

        #expect(Self.ids(files) == [1, 2])
        #expect(files.map(\.format) == [.oggVorbis160, .oggVorbis320])
    }

    /// Measured on 2026-09-29: the wrapped `Track` names the track and says how long it is, which
    /// is why `/metadata/4` is no longer asked.
    @Test func `the wrapped track carries its name and duration`() throws {
        let track = ProtobufWriter.message {
            $0.string(field: 2, "Not Bad for New Jersey")
            $0.varint(field: 7, 430_410) // sint32 215205, as measured
            Self.file(&$0, id: 1, format: 1)
        }

        let metadata = try #require(Self.parse(track))

        #expect(metadata.name == "Not Bad for New Jersey")
        #expect(metadata.durationMs == 215_205)
    }

    /// A track that does not exist: HTTP 200, a 404 in the entity's header, and no `Track`,
    /// measured with `spotify:track:0000000000000000000000`.
    @Test func `an entity without a track is none`() {
        #expect(SPClient.parseTrackResponse(Self.extendedMetadataResponse(track: nil, status: 404)) == nil)
    }

    /// "Girlfriend", which Spotify withholds in DE, measured the same day: a `Track` with its name,
    /// its duration and a restriction (11), and no files, of its own or an alternative's. So it
    /// still reads as withheld, and auto-advance still steps over it.
    @Test func `a withheld track has its name and no files`() throws {
        let track = ProtobufWriter.message {
            $0.string(field: 2, "Girlfriend (feat. Dâm-Funk)")
            $0.varint(field: 7, 402_146) // sint32 201073
            $0.message(field: 11) { $0.string(field: 2, "") } // restriction
        }

        let metadata = try #require(Self.parse(track))

        #expect(metadata.name == "Girlfriend (feat. Dâm-Funk)")
        #expect(metadata.files.isEmpty)
    }

    @Test func `a relinked track's files come from its alternative`() throws {
        let track = ProtobufWriter.message {
            $0.string(field: 2, "Song")
            $0.message(field: 13) { alternative in
                Self.file(&alternative, id: 3, format: 0) // OGG_VORBIS_96
            }
        }

        let metadata = try #require(Self.parse(track))

        #expect(Self.ids(metadata.files) == [3])
        #expect(metadata.files.map(\.format) == [.oggVorbis96])
        #expect(metadata.name == "Song")
    }

    /// `Track.duration` is a `sint32`. The wire value here is the one a live `/metadata/4`
    /// answer carried for "Pearls" on 2026-09-26, read raw as 403518 ms; the decoder counted
    /// 8,897,582 frames of it at 44.1 kHz, which is 201.76 s. It is the same `Track` message
    /// extended metadata wraps.
    @Test func `the duration is read as the zigzag sint32 it is`() throws {
        let track = ProtobufWriter.message { $0.varint(field: 7, 403_518) }

        #expect(try #require(Self.parse(track)).durationMs == 201_759)
    }

    @Test func `own files win over the alternative's`() throws {
        let track = ProtobufWriter.message {
            Self.file(&$0, id: 1, format: 1)
            $0.message(field: 13) { Self.file(&$0, id: 3, format: 0) }
        }

        #expect(try Self.ids(#require(Self.parse(track)).files) == [1])
    }

    @Test func `unnamed formats are dropped before falling back to the alternative`() throws {
        let track = ProtobufWriter.message {
            Self.file(&$0, id: 1, format: 16) // FLAC_FLAC, which AudioFormat does not name
            $0.message(field: 13) { Self.file(&$0, id: 3, format: 0) }
        }

        #expect(try Self.ids(#require(Self.parse(track)).files) == [3])
    }

    /// Found in review. Dropped before the empty check, a track with nothing but such formats
    /// read as having no files at all, which is how Spotify withholds a track, so auto-advance
    /// skipped it and the bar called it unavailable.
    @Test func `unnamed formats are kept when they are all there is`() throws {
        let track = ProtobufWriter.message {
            Self.file(&$0, id: 1, format: 16) // FLAC_FLAC
        }

        let files = try #require(Self.parse(track)).files

        #expect(Self.ids(files) == [1])
        #expect(files.map(\.format) == [.unknown])
    }

    @Test func `a file without an id is skipped`() throws {
        let track = ProtobufWriter.message {
            $0.message(field: 12) { $0.varint(field: 2, 1) }
        }

        #expect(try #require(Self.parse(track)).files.isEmpty)
    }

    @Test func `a context resolve answer names its context`() {
        // The shape measured for Liked Songs on 2026-09-30, cut to one track.
        let json = #"{"metadata":{"format_list_type":"liked-songs","context_description":"Lieblingssongs"},"pages":[{"tracks":[{"uri":"spotify:track:2vaVAZtZ6p2bC1gBrUwrPA","uid":"95942ae3715ec9d21e76"}]}]}"#

        let report = SPClient.parseContextReport(Data(json.utf8))

        #expect(report.metadata == ["format_list_type": "liked-songs", "context_description": "Lieblingssongs"])
        #expect(report.tracks == ["spotify:track:2vaVAZtZ6p2bC1gBrUwrPA"])
        #expect(report.uids == ["95942ae3715ec9d21e76"])
    }

    /// An album's answer, as measured for "Cold Fact", has no uids.
    @Test func `a context resolve answer without uids keeps a nil beside each track`() {
        let json = #"{"pages":[{"tracks":[{"uri":"spotify:track:a"},{"uri":"spotify:track:b"}]}]}"#

        #expect(SPClient.parseContextReport(Data(json.utf8)).uids == [nil, nil])
    }

    @Test func `a context resolve answer with an empty description names nothing`() {
        let json = #"{"metadata":{"context_description":""},"pages":[{"tracks":[{"uri":"spotify:track:a"}]}]}"#

        #expect(SPClient.parseContextReport(Data(json.utf8)).metadata.contextName == nil)
    }
}
