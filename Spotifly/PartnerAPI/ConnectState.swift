//
//  ConnectState.swift
//  Spotifly
//
//  The commands Spotify Connect takes, at spclient's connect-state API.
//

import Foundation

/// One player command, in the shape `POST /connect-state/v1/player/command/from/{from}/to/{to}`
/// expects.
///
/// This replaces the seven `/me/player/*` transport endpoints — pause, play, next, previous,
/// seek, shuffle — with one endpoint that names the action in its body. It is what Spotify's own
/// clients send, and unlike the Web API it does not require a first-party-or-your-own client id.
///
/// **No connection id is needed.** Reading connect-state does require an
/// `x-spotify-connection-id` from a dealer websocket, which is why the device list and player
/// state come from librespot instead. Commands do not: measured on 2026-08-13, a bare
/// bearer-plus-client-token POST is answered with `200 {"ack_id": …}` and the target device acts
/// on it. A command aimed at a device id that does not exist answers `404 DEVICE_NOT_FOUND`,
/// which is how "the request shape is right" was established separately from "the target was
/// there".
nonisolated struct ConnectCommand: Encodable, Sendable {
    /// The `endpoint` values this app sends. Spotify defines more — `set_options` for repeat —
    /// which stay out until something calls for them.
    enum Kind: String, Encodable, Sendable {
        case pause
        case resume
        case skipNext = "skip_next"
        case skipPrev = "skip_prev"
        case seekTo = "seek_to"
        case setShufflingContext = "set_shuffling_context"
        case play
        case addToQueue = "add_to_queue"
    }

    /// The track an `add_to_queue` names, in the shape the web player sends it — marked as
    /// queued twice over, in its metadata and as its provider. Captured from open.spotify.com's
    /// network tab on 2026-09-27, queueing a track on another device.
    struct QueuedTrack: Encodable, Sendable {
        let uri: String
        let metadata = ["is_queued": "true"]
        let provider = "queue"
    }

    /// Where a `play` command starts.
    ///
    /// **This endpoint plays contexts, not tracks**, which is the one place the Web API was
    /// more forgiving: `/me/player/play` took a bare `uris` array. Here a single track is sent
    /// as a context with a `skip_to`, and an arbitrary list of tracks as an *inline* context —
    /// `pages[].tracks[]` — since there is no album or playlist to name.
    struct Context: Encodable, Sendable {
        struct Track: Encodable, Sendable {
            let uri: String
        }

        struct Page: Encodable, Sendable {
            let tracks: [Track]
        }

        struct SkipTo: Encodable, Sendable {
            var trackUri: String?
            var trackIndex: Int?

            enum CodingKeys: String, CodingKey {
                case trackUri = "track_uri"
                case trackIndex = "track_index"
            }
        }

        struct Options: Encodable, Sendable {
            let skipTo: SkipTo

            enum CodingKeys: String, CodingKey {
                case skipTo = "skip_to"
            }
        }

        let uri: String
        let url: String
        var pages: [Page]?
        let options: Options?

        /// A context uri (album, playlist, artist) plays from its start, or from the track
        /// `skip_to` names; a *track* uri becomes a context plus a `skip_to` naming it.
        /// Getting that distinction wrong plays the first track of the album rather than the
        /// one asked for.
        ///
        /// `trackUri` and `trackIndex` go together, as the web player sends them. A receiver
        /// starts at the uri and falls back to the index only without one: librespot's
        /// `PlayingTrack::try_from` and go-librespot's `loadContext` both do. So a list that
        /// disagrees with the context still plays the row that was clicked.
        init(uri: String, trackIndex: Int? = nil, trackUri: String? = nil) {
            self.uri = uri
            url = "context://\(uri)"
            pages = nil

            if uri.hasPrefix("spotify:track:") {
                options = Options(skipTo: SkipTo(trackUri: uri))
            } else if trackUri != nil || trackIndex != nil {
                options = Options(skipTo: SkipTo(trackUri: trackUri, trackIndex: trackIndex))
            } else {
                options = nil
            }
        }

        /// A list of tracks with no context of their own, carried inline.
        init(trackUris: [String]) {
            uri = ""
            url = ""
            pages = [Page(tracks: trackUris.map { Track(uri: $0) })]
            options = nil
        }
    }

    /// The correlation id the real client stamps on every command. Spotify does not require it
    /// to mean anything, and it shows up in their logs rather than ours.
    struct LoggingParams: Encodable, Sendable {
        let commandId: String

        enum CodingKeys: String, CodingKey {
            case commandId = "command_id"
        }

        init() {
            commandId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
    }

    let endpoint: Kind
    let loggingParams = LoggingParams()

    /// `seek_to` carries a position in milliseconds here.
    var value: Int?
    /// `set_shuffling_context` carries a flag under the *same* `value` key. Two Swift
    /// properties rather than one of mixed type, because only one is ever set and JSON cares
    /// which of the two it is.
    var boolValue: Bool?
    var context: Context?
    var track: QueuedTrack?

    enum CodingKeys: String, CodingKey {
        case endpoint
        case loggingParams = "logging_params"
        case value
        case context
        case options
        case track
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(endpoint, forKey: .endpoint)
        try container.encode(loggingParams, forKey: .loggingParams)
        try container.encodeIfPresent(value, forKey: .value)
        if let boolValue {
            try container.encode(boolValue, forKey: .value)
        }

        // `play` puts the context beside the endpoint and its skip_to under `options`, rather
        // than nesting one inside the other.
        if let context {
            try container.encode(context, forKey: .context)
            try container.encodeIfPresent(context.options, forKey: .options)
        }
        try container.encodeIfPresent(track, forKey: .track)
    }

    static let pause = ConnectCommand(endpoint: .pause)
    static let resume = ConnectCommand(endpoint: .resume)
    static let next = ConnectCommand(endpoint: .skipNext)
    static let previous = ConnectCommand(endpoint: .skipPrev)

    static func seek(toMs positionMs: Int) -> ConnectCommand {
        ConnectCommand(endpoint: .seekTo, value: max(0, positionMs))
    }

    static func shuffle(_ enabled: Bool) -> ConnectCommand {
        ConnectCommand(endpoint: .setShufflingContext, boolValue: enabled)
    }

    static func play(uri: String, trackIndex: Int? = nil, trackUri: String? = nil) -> ConnectCommand {
        ConnectCommand(endpoint: .play, context: Context(uri: uri, trackIndex: trackIndex, trackUri: trackUri))
    }

    /// Plays a bare list of tracks, which this endpoint can only do as an inline context.
    static func play(trackUris: [String]) -> ConnectCommand {
        ConnectCommand(endpoint: .play, context: Context(trackUris: trackUris))
    }

    /// Queues one track on the device that is playing.
    static func addToQueue(trackUri: String) -> ConnectCommand {
        ConnectCommand(endpoint: .addToQueue, track: QueuedTrack(uri: trackUri))
    }
}

/// The body `PUT /connect-state/v1/connect/volume/from/{from}/to/{to}` takes.
///
/// **Volume is not a player command**, which is the one asymmetry here: it has its own path and
/// its own verb. The scale differs too — the wire wants 0…65535 where the app and the Web API
/// both use a percentage — so the conversion lives in the initializer rather than at the call
/// site.
nonisolated struct ConnectVolume: Encodable, Sendable {
    let volume: Int

    init(percent: Int) {
        let clamped = min(100, max(0, percent))
        volume = Int((Double(clamped) / 100.0 * 65535.0).rounded())
    }
}

/// The body a player command is actually sent as.
///
/// **The command goes inside a `command` object**, and forgetting that is not a subtle failure:
/// `{"error_type":"BAD_COMMAND","message":"Payload does not contain a command object"}`. This
/// type exists so the envelope cannot be forgotten at a call site — and so a test can assert on
/// it, which is what was missing when the first version of this shipped encoding the command's
/// fields at the top level.
///
/// A successful command answers `{"ack_id": "..."}`, which nothing reads: unlike the pathfinder
/// mutations, failure here *is* reported by status code, so there is no 200-that-means-no to
/// unpick and no reason to decode the ack.
nonisolated struct ConnectCommandEnvelope: Encodable, Sendable {
    let command: ConnectCommand

    init(_ command: ConnectCommand) {
        self.command = command
    }
}
