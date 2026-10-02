# This Mac has no autoplay

Status: **Open**, built 2026-10-02: the account's setting, a station lined up on a context's
last row, and the take-over of another device's autoplay; see Progress. Seen on this Mac alone;
the phone's cases are still to see.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (the end of a context,
`takeOverState`, `continuePlayback`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift`,
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (a resolve for autoplay),
`Spotifly/SwiftLibrespot/Network/Accesspoint.swift` (the account's attributes),
`Spotifly/SwiftLibrespot/Dealer/DealerConnection.swift` (`spotify:user:attributes:mutated`)
Found: 2026-10-02, measuring what the mirrored queue took on trust about autoplay
(`plans/open/mirrored-queue-beyond-the-web-player.md`)

## Summary

With the account's autoplay on, Spotify's clients go on after an album or a playlist ends with
tracks like it. This Mac does not: it stops at the end, and taking over another device's
autoplay track plays that track in front of the album, and the album again after it.

## Problem

Measured with a phone, the account's autoplay switched on there, and a throwaway build logging
the rows the Mac mirrored (`plans/open/mirrored-queue-beyond-the-web-player.md`, Progress):

- **What the phone plays after an album:** on the last track of "Love & Hate", it lists 50
  tracks with provider `autoplay` after it, from `spotify:station:album:<the album's id>`
  (`context_uri` and `entity_uri` in each row's metadata, `autoplay.is_autoplay=true`). It keeps
  the album as its context uri while they play.
- **Mirrored, it works:** the Queue section lists the autoplay rows, and Next goes on to them on
  the phone.
- **Taken over, it does not:** Play on the Mac, the phone paused and closed, took "Teardrop",
  the first autoplay track, over in the album. The track is not the album's, so it went in front
  of it, and the album followed from its first track ("Cold Little Heart", 1/11). A handover of
  the same state takes the same path (`continuePlayback`) and would do the same; not tried.
- **On its own:** at the end of an album with repeat off, this Mac stops. Nothing here asks for
  autoplay tracks.
- **The account's setting:** switching it on the phone sent the dealer
  `spotify:user:attributes:mutated`, which this Mac does not handle.

## Solution

Not planned. How librespot does it, read in `connect/src`:
- **The setting** is the user attribute `autoplay` (`Session::autoplay()`), from the login's
  attributes and updated on that mutation (`spirc.rs`, `handle_user_attributes_mutation`).
- **The tracks** come from `POST /context-resolve/v1/autoplay` on spclient, an
  `AutoplayContextRequest` naming the context and the recent tracks
  (`context_resolver.rs`, `core/src/spclient.rs` `get_autoplay_context`).
- **At the end of a context,** with autoplay on and repeat off, the queue fills up from that
  context, the rows provider `autoplay` (`state/tracks.rs`). While one plays, toggling shuffle and
  repeat is disallowed, reason `autoplay` (`state/restrictions.rs`).
- **A transfer of an autoplay track** loads the context uri with `station:` taken out as the
  context, and resolves autoplay for it beside, with the autoplay context active
  (`spirc.rs`, `handle_transfer`).

How go-librespot does it, more simply (`daemon/controls.go`, upstream as of 2026-09-29):
- **The setting** is its own, `disable_autoplay` in its config, not the account's attribute.
- **At the end of a context,** with nothing next and repeat off, it sends up to 50 tracks the
  list played (`maxAutoplaySeedTracks`) with the context uri to the same endpoint
  (`startAutoplay`), and loads the station context that comes back, `spotify:station:…`, as
  the new context, its tracks marked `autoplay.is_autoplay` (`spclient/context_resolver.go`).
  A context that is already a station gets no autoplay.
- **A transfer** of "a queued or autoplayed track is handed over on its own, with no context to
  take it from", and is played as a context of one (`daemon/player.go`).
- The endpoint answers a protobuf `Context`, where this app's resolves read JSON.

To find out first:
- whether to follow the account's setting, as the official clients and librespot do, or an
  own one, as go-librespot does: the login's attributes and the mutation would say;
- what a handover from the phone carries while an autoplay track plays: its pages, and the
  context uri.

## Verification

- Unit tests: `AutoplayTests`, and the take-overs in `MirroredQueueTests` and
  `TransferStateTests`; 542 tests and the lint pass.
- On this Mac: see Progress.
- With a phone, still to see: Play on the Mac over the phone's autoplay track, a handover of
  one, the setting switched off while the Mac is on a last track, and the phone's queue while the
  Mac plays its own autoplay.

## Progress

- **The account's setting** (2026-10-02).
  - **At login:** the `ProductInfo` packet has `<autoplay>1</autoplay>` among its 103 elements,
    a throwaway log found. `Accesspoint.autoplay` reads it, and the session hands it to the
    client.
  - **A change:** switching autoplay off and on again on the phone sent
    `spotify:user:attributes:mutated` twice, 6.5 s apart. Each was a `UserAttributesMutation`
    naming `autoplay`, with a timestamp and no value.
  - The dealer turns it into a Connect command, `userAttributesMutated`, and the client flips
    its setting, as librespot flips the "0" or "1" it keeps.
- **Lining up a station** (2026-10-02). When nothing comes after the track playing here, with
  autoplay on and repeat off, the client asks `context-resolve/v1/autoplay`
  (`SPClient.resolveAutoplay`, from `announceNextTrack`). So a context that ends on a withheld
  track is followed too. The queue keeps whether it was asked (`autoplayAsked`), once per
  context, and again after its rows were taken away. The body is a
  protobuf `AutoplayContextRequest`: the context uri, and its last 50 tracks as the seed. The
  answer is the same JSON as a resolve's.
  - **Where the rows go:** after the context's own, in `PlaybackQueue.appendAutoplay`. The
    context stays the album, as the phone reports it; the rows' provider is `autoplay`, and they
    are reported with `autoplay.is_autoplay` (`SpircController.provided`).
  - **What follows from that:** auto-advance, Next, the fetch-ahead and Previous go through them
    as through the context.
  - **What takes them away:** repeat, the setting switched off, or a rewind, unless one plays.
    Repeat switched on while one plays: the station plays out, then the context's own rows come
    round again, without it. A round of the context, for repeat and shuffle, is its own rows.
  - **Shuffled,** they stay after the context's own rows, in their order; shuffle switched on
    while one plays goes on with the rest of them.
  - **Not asked for:** a station's end (go-librespot's rule), or a bare list, which has no
    context to name.
- **Another device's autoplay** (2026-10-02).
  - **Taken over from the mirror:** `takeOverState` marks an `autoplay` current track, with the
    autoplay rows ahead of it.
  - **Handed over:** a `TransferState` marks one by its track's `autoplay.is_autoplay` metadata.
  - **Either way,** `continueAutoplay` resolves the context and stands on its last row, then
    plays the autoplay rows from the one playing (`PlaybackQueue.playAutoplay`), as `playQueued`
    takes over a queued track: that row goes into the history, so Previous goes back into the
    album. A handover names no rows, so a station is asked for beside the context's resolve,
    seeded with the track and what the handover sent of the context.
- **Seen on this Mac** (2026-10-02, and again after the review's changes), `SPOTIFLY_DEBUG_AUTOPLAY` on "Teardrop (Bundle)" (2
  tracks) with `SPOTIFLY_DEBUG_NEXT_AFTER=10`:
  - the login read autoplay on;
  - the first Next reached the last track, and the station was asked for at once, answered
    with 50 tracks 0.23 s later; the queue went from 0 to 50 ahead;
  - the second Next played "Heartbeats", the first autoplay track, with both album tracks behind
    it;
  - the Queue section listed the album's two rows as C and the rest as A, under "Wiedergabe von
    'Teardrop (Bundle)'".
- **`/code-review` found five, all fixed:**
  - A repeat wrap after autoplay left the station's rows in the history, past the context's end,
    which the next queue publish would have trapped on.
  - The setting's change published this Mac's queue over the one mirrored from another device.
  - A station answered after playback left this Mac was still lined up.
  - The ask could miss the first track played here, before its state reported; it is asked
    again then.
  - The rewind after autoplay could pick an autoplay row.
- **No UI:** the setting is the account's, switched on any device; this Mac reads it and does
  not change it.
- **Not done:**
  - **Restrictions:** librespot reports shuffle and repeat as disallowed while an autoplay track
    plays; this Mac does not.
  - **Taken over or handed over,** an album's row uids, which `play(uriOrUrl:)` fetches beside
    the resolve, are not fetched: a jump another device names into the album's rows goes by
    track alone.
