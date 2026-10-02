# Shuffle and repeat on a station go over the rows it played

Status: **Done** 2026-10-02. A station follows the restrictions Spotify's resolver names: it
starts unshuffled and without repeat, refuses both, and reports them, as the web player does. Its
page urls name the last 350 tracks played, where the eleventh page's url was refused. Seen in the
running app with the web player; see Verification. A phone's controls for this Mac's station
weren't seen. Left from `plans/done/station-pages-fetched-up-front.md`.
Components: `Spotifly/SwiftLibrespot/Proto/Connect.swift` (`Restrictions`, `PlayerState`),
`Spotifly/SwiftLibrespot/Network/SPClient.swift` (`ResolvedContext.restrictions`,
`nextPagePath`), `Spotifly/SwiftLibrespot/Public/PlaybackQueue.swift` (`setContext`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`setShuffle`, `setRepeat`, `play`),
`Spotifly/SwiftLibrespot/Connect/SpircController.swift` (the report),
`Spotifly/Views/NowPlayingBarView.swift` (the Shuffle button)
Found: 2026-10-02, in `/simplify` of the station paging

## Summary

A station's rows grow a page at a time as it plays. Shuffle switched on mixed every row loaded so
far back in, tracks played hours ago included, and repeat or the rewind at its end would play them
all again. Spotify's clients restrict shuffle and repeat for a radio; this Mac reported no
restrictions, and refused nothing.

## Problem

- **Shuffle:** `reshuffleKeepingCurrent` shuffles all of the context's own rows, and a station's
  are every page loaded since it started.
- **Repeat:** a round of the context is its own rows, so a station's repeat would play everything
  loaded again.
- **What Spotify says**, measured 2026-10-02 with a throwaway build:
  - The resolver's answer for Song Radio carries `restrictions` beside its pages:
    `disallow_toggling_shuffle_reasons` and `disallow_toggling_repeat_context_reasons`, both
    `["radio"]`. Nothing for repeat-one.
  - The web player playing that station reported them as its `context_restrictions` (field 4),
    and in its `restrictions` (field 17) added `endless_context` for shuffle, repeat and
    repeat-one. It greyed its Shuffle and Repeat.
  - Handed the station with shuffle on (Spotifly had taken a remote shuffle on it), the web
    player reported shuffle off.
  - Controlling Spotifly on the same station, the web player offered both, since Spotifly
    reported no restrictions, and Spotifly took the shuffle.
- **The page urls grow without end**, measured 2026-10-02 by walking a station's pages:
  - Each page's url names every track played before it in `prev_tracks`, the latest page's
    first: 1,306 characters for the second page, 1,150 more with each page.
  - The eleventh page's url, 500 tracks and 11,657 characters, was refused with 431. The
    station would end there, after about 500 tracks.
  - A station holds about 400 tracks: with all of them named, its eighth page already brought
    back tracks it had played.
- **Not measurable with the web player:** the `radio-router` → `radio-apollo` alias. The web
  player resolves nothing itself: Spotify's `track-playback` service plays for it, and 80 skips
  through its station showed no page fetch in the page.

## Solution

Keep to the restrictions the resolver names, as librespot and go-librespot do:
- **Read them:** `Restrictions` models fields 7 to 10 of `player.proto`'s message (Next,
  repeat, repeat-one, shuffle), from the resolver's JSON by field name and from the wire.
  `PlayerState` reads and writes `restrictions` and `context_restrictions`;
  `disallowsSkippingNext` reads from them.
- **Start without what they refuse:** `PlaybackQueue.setContext` takes the context's
  restrictions and turns shuffle and repeat off where they refuse them, as go-librespot's
  `loadContext` does. The client's options are the queue's now, so the two can't disagree. A
  handover sets the sender's options before the context, and the context then turns off what it
  refuses.
- **Refuse them:** `LibrespotClient.setShuffle` and `setRepeat` refuse shuffle or a repeat mode
  the context refuses, from the bar or from another device, as librespot does. The report each
  remote command is answered with tells the sender nothing changed.
- **Report them** as both `context_restrictions` and `restrictions`, as go-librespot does, so
  other devices grey their controls. `endless_context` is not added: it's the web player's own,
  and the resolver allows repeat-one.
- **Show them:** `PlaybackState.canShuffle`, for this Mac from the context and for another
  device from its `restrictions`, greys the bar's Shuffle. The app has no Repeat control.
- **Page urls:** `SPClient.nextPagePath` cuts `prev_tracks` to the first 350
  (`stationPageMemory`), the tracks played last. That stays under the refused length (8.2 KB
  sent) and near the station's own ~400 tracks, so it comes round about when it would anyway.

## Verification

- **Unit tests:**
  - restrictions read from the resolver, and written to and read from the wire;
  - a station starting unshuffled and without repeat, repeat-one kept, and another context
    keeping the options;
  - a rewind keeping the restrictions;
  - the page url's cut.
- **Live, 2026-10-02:** Debug build, Song Radio (`spotify:station:track:5TORlzrrvDGBMAM10QsiSy`),
  the web player as the other device.
  - The bar's Shuffle was greyed, and pressing it sent nothing.
  - The web player controlling the Mac greyed its Shuffle, and offered repeat-one only. It sent
    repeat-one, which the Mac took, and repeat off.
  - An album with shuffle on, then the station started by a throwaway launch hook: the station
    started unshuffled, on its first track.
  - Handed to the web player and back: the Mac resolved the station again at 0:50, unshuffled,
    and the web player kept Shuffle greyed for it.
  - An album started from the web player on the Mac: Shuffle and Repeat came back in both.
  - Pages, walked by a throwaway hook: with the cut, 20 pages answered, the url sent stayed at
    8.2 KB, and from the eighth page on the station came round to tracks it had played. Without
    the cut, the eleventh failed with 431.
- **Not seen:** a phone's controls for this Mac's station, and a remote shuffle actually refused.
  The web player sends no command for a greyed control, so the refusal is reached only by a
  device that ignores the restrictions.
