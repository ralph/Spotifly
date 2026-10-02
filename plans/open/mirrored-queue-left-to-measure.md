# What the mirrored queue takes on trust: librespot's rows, a refused Next

Status: **Open**, not planned: nothing here is seen to go wrong, and both need a device not at
hand. What is left of `plans/done/mirrored-queue-beyond-the-web-player.md` once the web player's
and a phone's rows were measured (2026-10-02).
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`mirroredQueue`,
`takeOverState`), `Spotifly/SwiftLibrespot/Proto/Connect.swift`
(`PlayerState.disallowsSkippingNext`), `Spotifly/ViewModels/PlaybackViewModel.swift` (`hasNext`)
Found: 2026-09-30, in the review of the fix for the mirrored queue

## Summary

The mirror of another device's queue, and Play taking it over, are built from the web player's and
a phone's rows. A librespot device (spotifyd, raspotify) lays its rows out differently after a
context's end, and no device yet seen refuses Next. Both are read as the code expects and neither
has been watched.

## Problem

- **librespot's rows after a context's end.** With autoplay on and repeat off, librespot puts a
  hidden `spotify:delimiter` row with provider `context` after the context's last row, "to only
  display the current context", and the autoplay rows after it (`fill_up_next_tracks` in
  `connect/src/state/tracks.rs`). A phone puts its autoplay rows straight after the context's
  last row. `mirroredQueue` keeps rows after the first delimiter that are not the context's, so
  librespot's autoplay rows would be listed; whether librespot marks them hidden, and what Play
  takes over from them, is not seen.
- **A device that refuses Next.** `PlayerState.disallowsSkippingNext` reads a
  `disallow_skipping_next_reason` (restrictions' field 7) and greys the bar's Next. The web player
  named none, on a context's last track either; a phone did not refuse Next with autoplay on.
  librespot never sets one (`connect/src/state/restrictions.rs`). So the greyed Next has not been
  seen.

## Solution

Not planned. Measure first, with a throwaway build that logs the mirrored rows and restrictions
(as in the done plan's Progress):
- librespot as the other device, on a context's last track with autoplay on. Running it needs an
  account signed in to it, which is the user's to do.
- Next refused: no device known to refuse it.

## Verification

Not defined yet.
