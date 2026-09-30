# A play sent to a librespot device may not parse

Status: **Done** 2026-09-29. Read from librespot's code; the new shape checked against Spotify's
backend; not yet seen reaching a librespot device, which needs one signed in to the account;
see Verification.
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

The plan's first step was to see it, by running librespot as a Connect device on the account.
That needs librespot signed in, which takes the account holder's login in a browser, and this
app signed in, which it was not on the day. So the fix went ahead on what librespot's code and
the web player's say, and what Spotify's backend accepts.

### What was checked

- **librespot requires both fields.** `core/src/dealer/protocol/request.rs`: `PlayCommand` has
  `play_origin` (`json_proto`, no default) and `options: PlayOptions` (no default), whose fields
  are all optional, so an empty object satisfies it.
- **The web player sends both.** Its bundle builds every `play` descriptor with a
  `play_origin` (`feature_identifier`, `feature_version`, …) and `options` (`skip_to`,
  `player_options_override`, `license`), and stamps `logging_params.command_id` on every
  command, as this app already does.
- **go-librespot names itself** in the play origin it keeps: `feature_identifier:
  "go-librespot"`, its version as `feature_version`.
- **Spotify's backend accepts the new shape.** From the web player's session, to a device id
  that does not exist: a body without a `command` object and one with an unknown endpoint were
  refused `400 BAD_COMMAND`, so the payload is checked before the device; the new album play,
  with `play_origin` and `options`, and the new inline list, with no `uri` or `url`, both got
  `404 DEVICE_NOT_FOUND`, past that check. Nothing played.
- **Not a problem: `seek_to`.** librespot's `SeekToCommand` requires `position` besides `value`,
  and this app sends only `value`. So does the web player (`_sendPlayerCommand("seek_to", e,
  {value: t})`), and librespot's own comment, "for some reason the position is stored in value",
  says it receives both, so the backend adds `position` on the way. That the backend fills in
  `play_origin` and `options` the same way is not known, so they are sent.

- **Every other command parses there as it is**, checked by the review against `request.rs`:
  pause, resume and `skip_prev` need only `logging_params`, all of whose fields are optional;
  `skip_next`'s `track` is optional; `set_shuffling_context` wants the JSON bool this app sends;
  `add_to_queue`'s track is a `ProvidedTrack` whose fields this app's match. Transfer and volume
  go to their own endpoints and never reach a device as a `Request`.

### What changed

- `ConnectCommand` puts `play_origin` on every `play`: `feature_identifier` `spotifly` and the
  app's version (`DeviceInfo.appVersion`, which the device reports too), as go-librespot names
  itself.
- `options` goes with every `play`, empty where there is no `skip_to`.
- An inline list's context (`Context(trackUris:)`) leaves `uri` and `url` out instead of sending
  them empty, so librespot takes its `PlayContext::Tracks` branch.

## Verification

- [x] Unit tests: every play carries `play_origin` and `options`; an inline list carries no
      `uri` or `url`; the existing play tests pass unchanged.
- [x] Spotify's backend accepts both new shapes, as above.
- [x] Build, 443 unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live, with the app signed in: play an album on the phone from the app, and Play Tracks
      under Search's "Show all tracks" on the phone. Both play as before.
- [ ] Live, with librespot (`cargo run` from its checkout, signed in to the same account) as a
      Connect device: the same two plays start there. librespot's log shows no
      `failed to deserialize` for the `play` command.
