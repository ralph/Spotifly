# A play sent to a librespot device may not parse

Status: **Open.** Recorded, not planned. Read from librespot's code, not observed.
Components: `Spotifly/PartnerAPI/ConnectState.swift` (`ConnectCommand`, `Context`)
Found: 2026-09-29, while fixing `plans/done/remote-track-list-play-starts-at-the-top.md`

## Summary

librespot, the engine behind raspotify, spotifyd and many speakers, deserializes a `play`
command strictly. Two fields it requires are ones this app never sends, and a bare list of
tracks goes out with an empty uri that librespot reads as a context to resolve. If Spotify
relays the command as sent, Play from this app on such a device fails there.

## Problem

In librespot's `core/src/dealer/protocol/request.rs`:

- **`play_origin` is required.** `PlayCommand.play_origin` has `deserialize_with = "json_proto"`
  and no `default`. `ConnectCommand` sends no `play_origin`.
- **`options` is required.** `PlayCommand.options: PlayOptions`, no `default`.
  `ConnectCommand.Context` sends `options` only when there is a `skip_to`, so "play this album
  from the top" has none.
- **An empty uri is a uri.** The context is proto2, `optional string uri`, so `"uri": ""`
  parses as `Some("")`, and `spirc.rs` matches `Some(s) => PlayContext::Uri(s)`. Only a
  missing uri takes the `PlayContext::Tracks` branch, for inline tracks. `Context(trackUris:)`
  sends `uri: ""`, `url: ""`.

Not known: whether Spotify's backend fills in `play_origin` or `options`, or drops empty
strings, on the way from `player/command` to the device. The web player sends both fields
always.

## Solution

Not planned yet. First see it: run librespot from its checkout as a Connect device on the same
account, and from this app play an album on it, then Search's Play All. If either fails:

1. Send `play_origin` (the web player sends `feature_identifier` and `feature_version`) and an
   `options` object on every play, as the web player does.
2. Leave `uri` and `url` out of an inline context instead of sending them empty.

## Verification

Not defined yet.
