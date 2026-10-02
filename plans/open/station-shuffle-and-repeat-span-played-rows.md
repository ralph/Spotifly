# Shuffle and repeat on a station go over the rows it played

Status: **Open**, not planned. Left from `plans/done/station-pages-fetched-up-front.md`
(2026-10-02).
Components: `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`setShuffle`, `setRepeat`,
`rewind`), `Spotifly/SwiftLibrespot/Connect/SpircController.swift` (the reported restrictions)
Found: 2026-10-02, in `/simplify` of the station paging

## Summary

A station's rows grow a page at a time as it plays. Shuffle switched on mixes every row loaded so
far back in, tracks played hours ago included, and repeat or the rewind at its end plays them all
again. Spotify's clients restrict shuffle and repeat for a radio; this Mac reports no
restrictions.

## Problem

- **Shuffle:** `reshuffleKeepingCurrent` shuffles all of the context's own rows; a station's are
  every page loaded since it started.
- **Repeat and the rewind:** a round of the context is its own rows, so a station's repeat or its
  end plays everything loaded again.
- **Restrictions:** the web player wrote a radio's restrictions in its handover (`.3.2.4`, fields 8
  and 10 "radio", 2026-10-02). What they disallow, and whether a phone greys out shuffle and
  repeat for this Mac's station, is not measured.
- **Also unmeasured:** whether a station page url's `prev_tracks` grows with every page until it
  reaches a url length limit in a long session; and the `radio-router` → `radio-apollo` alias,
  inferred from the answers rather than from a Spotify client's own request (the web player's
  fetches, once its station passes its second page, would show it).

## Solution

Not planned. Options:
- Treat a context that names a next page as endless: shuffle only the rows ahead, and allow no
  repeat of the context.
- Report a radio's restrictions to other devices, as the web player writes them, once measured.

## Verification

Not defined yet.
