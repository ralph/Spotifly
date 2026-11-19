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

/// `connect.proto` and `player.proto`.
struct ConnectMessageParsingTests {
    @Test func `a cluster update is read through its cluster, player state and device map`() throws {
        let data = ProtobufWriter.message {
            $0.message(field: 1) { cluster in
                cluster.string(field: 2, "phone") // active_device_id
                cluster.message(field: 3) { player in
                    player.varint(field: 1, 1_790_000_000_123) // timestamp
                    player.string(field: 2, "spotify:album:abc") // context_uri
                    player.message(field: 7) { track in
                        track.string(field: 1, "spotify:track:current")
                        track.message(field: 3) { entry in // metadata
                            entry.string(field: 1, "key")
                            entry.string(field: 2, "value")
                        }
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
            }
        }

        let cluster = try ClusterUpdateProto.parse(from: data).cluster
        #expect(cluster.activeDeviceId == "phone")

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

    /// A station's restrictions, as the web player playing one sent them (2026-10-02): at
    /// field 17, each reason at its field's number.
    @Test func `restrictions are read at player.proto's numbers`() {
        let radio = ProtobufWriter.message {
            $0.string(field: 8, "radio")
            $0.string(field: 10, "radio")
        }
        let state = PlayerState.parse(from: ProtobufWriter.message {
            $0.bytes(field: 17, radio)
        })

        #expect(state.restrictions == .radio)
        #expect(!state.restrictions.allowsShuffle)
        #expect(!state.restrictions.allows(.context))
        #expect(state.restrictions.allows(.track))
        #expect(!state.disallowsSkippingNext)
    }

    @Test func `the context metadata is read at player.proto's number`() {
        // map<string, string> context_metadata: one entry message per key.
        let data = ProtobufWriter.message {
            for (key, value) in [("zeta", "1"), ("alpha", "2")] {
                $0.message(field: 21) { entry in
                    entry.string(field: 1, key)
                    entry.string(field: 2, value)
                }
            }
        }

        let state = PlayerState.parse(from: data)

        #expect(state.contextMetadata == ["zeta": "1", "alpha": "2"])
    }

    /// `Capabilities.disable_volume` is field 13 in connect.proto.
    @Test func `a device that refuses volume says so`() {
        let refusing = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.string(field: 9, "audio/track")
            $0.bool(field: 13, true)
        })
        let accepting = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.string(field: 9, "audio/track")
        })

        #expect(refusing.disableVolume)
        #expect(!accepting.disableVolume)
    }

    /// `Capabilities.hidden` is field 12 in connect.proto. A hidden device is one no device
    /// list offers as a speaker, so Speakers leaves it out.
    @Test func `a hidden device says so`() {
        let hidden = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.bool(field: 12, true)
        })
        let shown = ConnectCapabilities.parse(from: ProtobufWriter.message {
            $0.bool(field: 2, true)
        })

        #expect(hidden.hidden)
        #expect(!shown.hidden)
    }
}

/// The context resolver's answer, which is JSON despite the protobuf `Accept`.
struct SPClientParsingTests {
    @Test func `a context resolve answer lists its tracks`() {
        // The shape measured for Liked Songs on 2026-09-30, cut to one track.
        let json = #"{"metadata":{"format_list_type":"liked-songs","context_description":"Lieblingssongs"},"pages":[{"tracks":[{"uri":"spotify:track:2vaVAZtZ6p2bC1gBrUwrPA","uid":"95942ae3715ec9d21e76"}]}]}"#

        let report = SpclientAPI.parseContextReport(Data(json.utf8))

        #expect(report.tracks == ["spotify:track:2vaVAZtZ6p2bC1gBrUwrPA"])
        #expect(report.nextPageUrl == nil)
    }
}
