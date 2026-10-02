//
//  TransferState.swift
//  SwiftLibrespot
//
//  What another device hands over along with playback.
//

import Foundation

/// The `data` of a Connect `transfer` command: librespot's `TransferState`
/// (`protocol/proto/transfer_state.proto` and the messages it nests), reduced
/// to what this player can act on. A device writes the same message into its `PutState` as
/// `transfer_data` (`serialized`), which the backend hands the next device.
///
/// ```
/// TransferState {
///   1 options         { 1 shuffling_context, 2 repeating_context, 3 repeating_track }
///   2 playback        { 1 timestamp, 2 position_as_of_timestamp, 3 playback_speed, 4 is_paused,
///                       5 current_track }
///   3 current_session { 2 context { 1 uri, 2 url, 3 metadata, 5 pages { 4 tracks } },
///                       3 current_uid, 8 main_context { 1 uri, 2 url, 3 metadata } }
///   4 queue           { 1 tracks, 2 is_playing_queue }
/// }
/// ContextTrack { 1 uri, 2 uid, 3 gid, 4 metadata { 1 key, 2 value } }
/// ```
public nonisolated struct TransferState: Sendable {
    var contextUri = ""
    /// The context's tracks as the sender had them, when it sent any. Often
    /// only a window of the context, so the uri is the better source. A bare list has no uri
    /// and comes whole: a phone sent all 20 rows of one (2026-10-02).
    var contextTrackUris: [String] = []
    /// Those rows' uids, beside them, with none for a row sent without one.
    var contextTrackUids: [String?] = []
    /// Which of those rows is the current track, where the rows say: another device's mirrored
    /// rows do (`LibrespotClient.takeOverState`), a handover's pages do not.
    var currentRow: Int?
    /// The track that was playing.
    var currentTrackUri: String?
    /// Its row's uid in the context, which names the row when the track plays under another id
    /// than the context lists, as a relinked track does. Read as nil when it plays from the
    /// queue.
    var currentTrackUid: String?
    /// Whether the track playing came from autoplay, after the context ended: its metadata's
    /// `autoplay.is_autoplay`, or its provider in another device's mirrored state, where the
    /// autoplay rows are `contextTrackUris` from `currentRow` on.
    var currentIsAutoplay = false
    /// The station an autoplay track came from, as its row's metadata names it (`context_uri`).
    var autoplayContextUri: String?
    /// While autoplay plays, the context it went on from: the session's `main_context`, beside the
    /// station as its `context`. The web player wrote it so on 2026-10-02.
    var mainContextUri: String?
    /// The metadata `mainContextUri` is written with, the resolver's, which names it to the
    /// device taking over.
    var mainContextMetadata: [String: String] = [:]
    /// Tracks the user queued on the sending device, which play before the
    /// context continues.
    var queuedTrackUris: [String] = []
    /// While a queued track plays, the uid of the context row that plays after it: the session's
    /// `current_uid`. Measured on 2026-09-30 with the web player, it names the row the context
    /// goes on with, and librespot's `finish_transfer` reads it the same way; so it does in a
    /// bare list a phone handed over (2026-10-02). Nil while a context track plays, when it only
    /// names that track again.
    var contextResumeUid: String?
    /// Whether the current track plays from the queue, the queue's `is_playing_queue`.
    var playsQueuedTrack = false

    var positionAsOfTimestamp: Int64 = 0
    var timestamp: Int64 = 0
    var isPaused = false

    var shuffle = false
    var repeatContext = false
    var repeatTrack = false

    init() {}

    init(parsing data: Data) {
        var sessionUid: String?

        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1:
                for option in field.fields {
                    switch option.number {
                    case 1: shuffle = option.bool
                    case 2: repeatContext = option.bool
                    case 3: repeatTrack = option.bool
                    default: break
                    }
                }
            case 2:
                for playback in field.fields {
                    switch playback.number {
                    case 1: timestamp = playback.int64
                    case 2: positionAsOfTimestamp = Int64(Int32(truncatingIfNeeded: playback.value))
                    case 4: isPaused = playback.bool
                    case 5:
                        let track = playback.fields
                        currentTrackUri = Self.trackUri(track)
                        currentTrackUid = Self.trackUid(track)
                        let metadata = track.filter { $0.number == 4 }.map(\.mapEntry)
                        currentIsAutoplay = metadata.contains { $0 == ("autoplay.is_autoplay", "true") }
                        autoplayContextUri = metadata.first { $0.key == "context_uri" && $0.value.hasPrefix("spotify:station:") }?.value
                    default: break
                    }
                }
            case 3:
                let session = field.fields
                sessionUid = session.last(3).map(\.string).flatMap { $0.isEmpty ? nil : $0 }
                mainContextUri = session.last(8)?.fields.last(1).map(\.string).flatMap { $0.isEmpty ? nil : $0 }
                for context in session where context.number == 2 {
                    for part in context.fields {
                        switch part.number {
                        case 1:
                            contextUri = part.string
                        case 5:
                            for row in part.fields where row.number == 4 {
                                guard let uri = Self.trackUri(row.fields) else { continue }
                                contextTrackUris.append(uri)
                                contextTrackUids.append(Self.trackUid(row.fields))
                            }
                        default:
                            break
                        }
                    }
                }
            case 4:
                for queue in field.fields {
                    switch queue.number {
                    case 1:
                        if let uri = Self.trackUri(queue.fields) {
                            queuedTrackUris.append(uri)
                        }
                    case 2:
                        playsQueuedTrack = queue.bool
                    default:
                        break
                    }
                }
            default:
                break
            }
        }

        // Playing from the queue means the queue's head *is* the current track
        // (librespot's `current_track_from_transfer`).
        if playsQueuedTrack, !queuedTrackUris.isEmpty {
            currentTrackUri = queuedTrackUris.removeFirst()
            currentTrackUid = nil
            contextResumeUid = sessionUid
        }

        // A context started from a bare list of uris is sent as "-" or nothing.
        if contextUri == "-" {
            contextUri = ""
        }
    }

    /// The message as a sending device writes it, which `init(parsing:)` reads back. Each track
    /// says where it came from, as a phone's do: an autoplay track `autoplay.is_autoplay` and its
    /// station, a queued one `is_queued`. A playing queued track is the queue's head as well
    /// as the current track, as a phone wrote it (2026-10-02).
    var serialized: Data {
        ProtobufWriter.message { message in
            message.message(field: 1) {
                $0.flag(field: 1, shuffle)
                $0.flag(field: 2, repeatContext)
                $0.flag(field: 3, repeatTrack)
            }
            message.message(field: 2) { playback in
                playback.varint(field: 1, timestamp)
                playback.varint(field: 2, positionAsOfTimestamp)
                playback.double(field: 3, isPaused ? 0 : 1)
                playback.flag(field: 4, isPaused)
                if let currentTrackUri {
                    playback.message(field: 5) { Self.write(track: currentTrackUri, uid: currentTrackUid, metadata: currentTrackMetadata, into: &$0) }
                }
            }
            message.message(field: 3) { session in
                session.message(field: 2) { Self.write(context: contextUri, into: &$0) }
                if let uid = playsQueuedTrack ? contextResumeUid : currentTrackUid {
                    session.string(field: 3, uid)
                }
                if let mainContextUri {
                    session.message(field: 8) { Self.write(context: mainContextUri, metadata: mainContextMetadata, into: &$0) }
                }
            }
            message.message(field: 4) { queue in
                let playing = playsQueuedTrack ? [currentTrackUri].compactMap(\.self) : []
                for uri in playing + queuedTrackUris {
                    queue.message(field: 1) { Self.write(track: uri, uid: nil, metadata: ["is_queued": "true"], into: &$0) }
                }
                queue.flag(field: 2, playsQueuedTrack)
            }
        }
    }

    /// The current track's metadata, as `init(parsing:)` reads it.
    private var currentTrackMetadata: [String: String] {
        var metadata: [String: String] = [:]
        if currentIsAutoplay {
            metadata["autoplay.is_autoplay"] = "true"
            metadata["context_uri"] = autoplayContextUri
            metadata["entity_uri"] = autoplayContextUri
        }
        if playsQueuedTrack {
            metadata["is_queued"] = "true"
        }
        return metadata
    }

    private static func write(track uri: String, uid: String?, metadata: [String: String], into track: inout ProtobufWriter) {
        track.string(field: 1, uri)
        track.nonEmptyString(field: 2, uid ?? "")
        track.map(field: 4, metadata)
    }

    private static func write(context uri: String, metadata: [String: String] = [:], into context: inout ProtobufWriter) {
        context.nonEmptyString(field: 1, uri)
        if !uri.isEmpty {
            context.string(field: 2, "context://\(uri)")
        }
        context.map(field: 3, metadata)
    }

    /// Where the track is now: it kept playing on the sender since `timestamp`
    /// unless it was paused.
    ///
    /// librespot only carries a position forward when it is above zero. That
    /// misses the common case: a sender reports its position when something
    /// changes, and a track played from its start is reported once, as 0 at
    /// the moment it started — which the backend passes on as it is. Measured
    /// with two instances: a track 48 s in was handed over at 0.
    func position(atMs now: Int64) -> Int64 {
        guard !isPaused, timestamp > 0 else {
            return max(0, positionAsOfTimestamp)
        }
        return max(0, positionAsOfTimestamp + now - timestamp)
    }

    /// A `ContextTrack`'s uid, or none for an empty one.
    private static func trackUid(_ fields: [ProtobufField]) -> String? {
        fields.last(2).map(\.string).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A `ContextTrack`'s uri, rebuilt from its gid when only that was sent.
    private static func trackUri(_ fields: [ProtobufField]) -> String? {
        if let uri = fields.first(where: { $0.number == 1 })?.string, !uri.isEmpty {
            return uri
        }
        guard let gid = fields.first(where: { $0.number == 3 })?.bytes, gid.count == 16,
              let id = SpotifyGID.base62(fromGID: gid.hexString)
        else { return nil }
        return "spotify:track:\(id)"
    }
}
