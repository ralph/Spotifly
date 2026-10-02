//
//  TransferState.swift
//  SwiftLibrespot
//
//  What another device hands over along with playback.
//

import Foundation

/// The `data` of a Connect `transfer` command: librespot's `TransferState`
/// (`protocol/proto/transfer_state.proto` and the messages it nests), reduced
/// to what this player can act on.
///
/// ```
/// TransferState {
///   1 options         { 1 shuffling_context, 2 repeating_context, 3 repeating_track }
///   2 playback        { 1 timestamp, 2 position_as_of_timestamp, 4 is_paused, 5 current_track }
///   3 current_session { 2 context { 1 uri, 5 pages { 4 tracks } }, 3 current_uid }
///   4 queue           { 1 tracks, 2 is_playing_queue }
/// }
/// ContextTrack { 1 uri, 2 uid, 3 gid }
/// ```
public nonisolated struct TransferState: Sendable {
    var contextUri = ""
    /// The context's tracks as the sender had them, when it sent any. Often
    /// only a window of the context, so the uri is the better source. A bare list has no uri
    /// and comes whole: a phone sent all 20 rows of one (2026-10-02).
    var contextTrackUris: [String] = []
    /// Those rows' uids, beside them, with none for a row sent without one.
    var contextTrackUids: [String?] = []
    /// The track that was playing.
    var currentTrackUri: String?
    /// Its row's uid in the context, which names the row when the track plays under another id
    /// than the context lists, as a relinked track does. Nil when it plays from the queue.
    var currentTrackUid: String?
    /// Tracks the user queued on the sending device, which play before the
    /// context continues.
    var queuedTrackUris: [String] = []
    /// While a queued track plays, the uid of the context row that plays after it: the session's
    /// `current_uid`. Measured on 2026-09-30 with the web player, it names the row the context
    /// goes on with, and librespot's `finish_transfer` reads it the same way; so it does in a
    /// bare list a phone handed over (2026-10-02). Nil while a context track plays, when it only
    /// names that track again.
    var contextResumeUid: String?

    var positionAsOfTimestamp: Int64 = 0
    var timestamp: Int64 = 0
    var isPaused = false

    var shuffle = false
    var repeatContext = false
    var repeatTrack = false

    init(parsing data: Data) {
        var playingQueue = false
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
                    default: break
                    }
                }
            case 3:
                let session = field.fields
                sessionUid = session.last(3).map(\.string).flatMap { $0.isEmpty ? nil : $0 }
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
                        playingQueue = queue.bool
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
        if playingQueue, !queuedTrackUris.isEmpty {
            currentTrackUri = queuedTrackUris.removeFirst()
            currentTrackUid = nil
            contextResumeUid = sessionUid
        }

        // A context started from a bare list of uris is sent as "-" or nothing.
        if contextUri == "-" {
            contextUri = ""
        }
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
