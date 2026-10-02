# What the mirrored queue took on trust: librespot's rows, a refused Next

Status: **Done** 2026-10-02, measured with a librespot device; nothing in the code needed to
change. What was left of `plans/done/mirrored-queue-beyond-the-web-player.md` once the web
player's and a phone's rows were measured.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirroredQueue`,
`takeOverState`), `Spotifly/SwiftLibrespot/Proto/Connect.swift`
(`PlayerState.disallowsSkippingNext`), `Spotifly/ViewModels/PlaybackViewModel.swift` (`hasNext`)
Found: 2026-09-30, in the review of the fix for the mirrored queue

## Summary

The mirror of another device's queue, and Play taking it over, were built from the web player's
and a phone's rows. A librespot device (spotifyd, raspotify) lays its rows out differently after
a context's end, and no device seen refused Next. Both are now measured against a librespot
device, and the code reads them as it expected.

## Problem

- **librespot's rows after a context's end.** With autoplay on and repeat off, librespot puts a
  `spotify:delimiter` row after the context's last row, "to only display the current context",
  and the autoplay rows after it (`fill_up_next_tracks` in `connect/src/state/tracks.rs`). A
  phone puts its autoplay rows straight after the context's last row. `mirroredQueue` keeps rows
  after the first delimiter that are not the context's. Whether librespot hides them, and what
  Play takes over from them, was not seen.
- **A device that refuses Next.** `PlayerState.disallowsSkippingNext` reads a
  `disallow_skipping_next_reason` (restrictions' field 7) and greys the bar's Next. No device
  seen names one, librespot included (`connect/src/state/restrictions.rs`).

## Solution

Measure, with no change expected unless a measurement disagreed. None did.

- **The device:** `librespot/examples/connect_measure.rs`, a copy of `play_connect.rs`.
  - It shows up as "Spotifly measure (librespot)" and plays at volume 0.
  - It turns autoplay on for itself (`SessionConfig::autoplay`), whatever the account says.
  - It plays the context it is given. It skips and shuts down after `MEASURE_NEXT_AFTER` and
    `MEASURE_QUIT_AFTER` seconds.
  - The first run signs in through the browser, which is the user's to do; the credentials are
    cached in librespot's `.cache`.
- **The measurement build of Spotifly** (never committed) logged, in `mirror`, the raw rows with
  their provider, uid, `hidden` and metadata, the restrictions, and the mirrored queue.
- **The context:** a playlist of one track, so the device starts on the context's last track.

## Verification

Measured 2026-10-02:

- **librespot's rows on a context's last track:**
  - after the current row: a `spotify:delimiter`, provider `context`, hidden, uid `delimiter0`,
    metadata `iteration=0`;
  - then 50 autoplay rows, **not hidden**, provider `autoplay`, with `autoplay.is_autoplay`,
    `context_uri` and `entity_uri` naming `spotify:station:playlist:<id>`.
  - **The mirror** listed the current row and the 50 autoplay rows. The Queue section showed them
    with the context's and autoplay's badges, under "Wiedergabe von „<playlist>“ auf Spotifly
    measure (librespot)".
- **librespot playing an autoplay row:**
  - the context stays the playlist. The previous rows are its last track and the hidden
    delimiter.
  - Its restrictions refuse shuffle and repeat with the reason `autoplay`, and Spotifly greyed
    Shuffle. Spotifly has no Repeat control of its own.
- **Play taking over, with librespot shut down:**
  - **from an autoplay row:** the Mac played that track from where librespot stopped. The
    previous row was the playlist's track, and the 49 autoplay rows were ahead. It fetched the
    next of them ahead of time.
  - **from the context's last track:** the Mac played the track and lined up its own autoplay,
    50 tracks from the same station. These were picked afresh, so not librespot's rows.
- **A refused Next:** librespot changed for one run (reverted) to name a reason,
  `disallow_skipping_next_reasons = ["measure"]`. Spotifly mirrored it, on the context's
  track and on an autoplay row. Next was greyed, seen once the device had gone, in the last
  state it had reported.
