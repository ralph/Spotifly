//
//  PlaylistChanges.swift
//  Spotifly
//
//  Creating playlists, renaming them, and adding or removing them from the library.
//

import Foundation

/// One operation inside a change, in the shape the playlist service takes it.
///
/// **A playlist's own existence is not pathfinder's business.** The web client's bundle ships no
/// `createPlaylist` and no `renamePlaylist` operation — harvested on 2026-08-14, which lists
/// every `(name, kind, hash)` triple it constructs — so there is no GraphQL mutation to call.
/// Playlists and the list of them belong to the playlist service at
/// `spclient.wg.spotify.com/playlist/v2`, the same service librespot already reads them from.
///
/// **These are protobuf messages sent as JSON.** The schema is `playlist4_external`, which
/// librespot vendors in `protocol/proto/playlist4_external.proto`, and the service speaks
/// proto3's JSON mapping in both directions — so plain `Codable` covers it and no protobuf
/// runtime is involved. Worth measuring rather than assuming: the app carries a hand-rolled
/// `Protobuf.swift` for the client-token handshake, and reaching for it here would have been
/// the obvious wrong move.
///
/// Only the kinds this app sends are modelled, and the unused payloads encode as absent. The
/// factories exist so no call site can name a `kind` without the payload that goes with it.
nonisolated struct PlaylistOp: Encodable, Sendable {
    /// `ListAttributes` — the fields of a playlist that can be edited.
    struct Attributes: Encodable, Sendable {
        var name: String?
        var description: String?
    }

    /// `ListAttributesPartialState`, which is a partial by design: the fields it names are the
    /// fields that move. A nil is omitted by the encoder and the existing value stands, so an
    /// empty string is how a description is cleared and not the same thing as leaving it alone.
    struct PartialState: Encodable, Sendable {
        var values: Attributes
    }

    struct AttributeUpdate: Encodable, Sendable {
        var newAttributes: PartialState
    }

    /// `ItemAttributes`, of which only the added-at time is ever set here.
    struct ItemAttributes: Encodable, Sendable {
        /// **A string, not a number.** The field is an `int64`, and proto3's JSON mapping
        /// renders 64-bit integers as strings so they survive languages whose numbers do not go
        /// that far. The web client sends `"1786645835061"`, quotes included.
        var timestamp: String
    }

    /// `Item`, which names a playlist by uri.
    struct Item: Encodable, Sendable {
        var uri: String
        var attributes: ItemAttributes?
    }

    /// `Add`. `addFirst` puts a new or newly followed playlist at the top of the library, which
    /// is where the web client puts it.
    struct ItemAddition: Encodable, Sendable {
        var items: [Item]
        var addFirst = true
    }

    /// `Rem`. `itemsAsKey` is what makes the removal name *what* to drop rather than *where*
    /// it sits — without it the message means "remove `length` items from `fromIndex`", and a
    /// library that shifted underneath us would delete the wrong playlist.
    struct ItemRemoval: Encodable, Sendable {
        var items: [Item]
        var itemsAsKey = true
    }

    var kind: String
    var updateListAttributes: AttributeUpdate?
    var add: ItemAddition?
    var rem: ItemRemoval?

    private init(
        kind: String,
        updateListAttributes: AttributeUpdate? = nil,
        add: ItemAddition? = nil,
        rem: ItemRemoval? = nil,
    ) {
        self.kind = kind
        self.updateListAttributes = updateListAttributes
        self.add = add
        self.rem = rem
    }

    static func attributes(name: String?, description: String?) -> PlaylistOp {
        PlaylistOp(
            kind: "UPDATE_LIST_ATTRIBUTES",
            updateListAttributes: AttributeUpdate(
                newAttributes: PartialState(
                    values: Attributes(name: name, description: description),
                ),
            ),
        )
    }

    /// `addedAt` is injectable so a test can pin the encoded body; nothing else passes it.
    static func add(uris: [String], addedAt: Date = Date()) -> PlaylistOp {
        // Rounded rather than truncated: a whole number of milliseconds is not exactly
        // representable as a Double, so truncation lands a millisecond early about half the time.
        let timestamp = String(Int64((addedAt.timeIntervalSince1970 * 1000).rounded()))

        return PlaylistOp(
            kind: "ADD",
            add: ItemAddition(items: uris.map {
                Item(uri: $0, attributes: ItemAttributes(timestamp: timestamp))
            }),
        )
    }

    static func remove(uris: [String]) -> PlaylistOp {
        PlaylistOp(kind: "REM", rem: ItemRemoval(items: uris.map { Item(uri: $0) }))
    }
}

/// `ListChanges`: the body every write to an *existing* list takes, whether that list is a
/// playlist or the rootlist holding them all.
///
/// One envelope, two endpoints — `playlist/v2/playlist/{id}/changes` for a playlist's own
/// attributes and `playlist/v2/user/{username}/rootlist/changes` for library membership. Both
/// measured from the web client on 2026-08-14.
nonisolated struct PlaylistListChanges: Encodable, Sendable {
    struct Source: Encodable, Sendable {
        var client: String
    }

    struct Info: Encodable, Sendable {
        var source: Source
    }

    struct Delta: Encodable, Sendable {
        var ops: [PlaylistOp]
        var info: Info
    }

    var deltas: [Delta]

    /// What the change reports itself as having come from.
    ///
    /// `SourceInfo.Client` also defines `CLIENT`, which is arguably what a desktop app is. The
    /// measured value is kept anyway: this whole surface is reached by looking like the client
    /// Spotify serves, and every other header the app sends — `Origin: xpui.app.spotify.com`
    /// above all — already says web player. A value nobody has watched work is not an
    /// improvement on one that has.
    static let client = "WEBPLAYER"

    init(_ ops: PlaylistOp...) {
        deltas = [Delta(ops: ops, info: Info(source: Source(client: Self.client)))]
    }
}

/// The body `POST playlist/v2/playlist` takes: a bare `OpList`.
///
/// **Creating does not use the envelope above**, which is the detail to get right. A new
/// playlist has no revision to base a delta on and no source to record, so the request is ops
/// and nothing else.
nonisolated struct PlaylistCreation: Encodable, Sendable {
    var ops: [PlaylistOp]

    init(name: String, description: String? = nil) {
        ops = [.attributes(name: name, description: description)]
    }
}

/// What creating a playlist answers with: `CreateListReply`.
///
/// The uri is the only part anything reads — it is how the caller learns the id Spotify
/// assigned, and there is no other way to find out. `revision` belongs to the change protocol
/// this app does not otherwise participate in.
nonisolated struct PlaylistCreationReply: Decodable, Sendable {
    let uri: String
}
