# This Mac has no autoplay

Status: **Open**, not planned. Measured with a phone on 2026-10-02; see Problem.
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

Not defined yet.
