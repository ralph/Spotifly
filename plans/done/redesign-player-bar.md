# Redesign: the player bar

Status: **Done**, 2026-10-21, PR #206. Second of the stacked redesign PRs. Repeat on a mirrored
track with nothing active joins `plans/open/shuffle-and-queue-on-a-mirrored-track.md`
Components: `Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`Spotifly/SpotifyPlayer.swift`, `Spotifly/PartnerAPI/ConnectState.swift`, `Spotifly/SpotiflyApp.swift`,
`Spotifly/*.lproj/Localizable.strings`
Found: 2026-10-21, `design_handoff_spotifly_macos/README.md` ("Player bar")

## Summary

The bar becomes the handoff's: transport with repeat on the left, the track with its time and a
thin seek slider in the middle, and heart, track menu, AirPlay and an inline volume slider on the
right, in a 64 pt capsule up to 780 pt wide. Repeat is new to the app's controls; the player
already supports it.

## Problem

The bar today is a 700 × 60 pt capsule laid out differently from the handoff:

- no repeat button, though `LibrespotClient.setRepeat` and remote `set_repeating_*` /
  `set_options` commands are all handled — nothing in the app sends one;
- the time shows only while the pointer is over the seek bar; the handoff shows "m:ss / m:ss"
  beside the title at all times;
- volume is a button that opens a popover; the handoff has the icon and a 72 pt slider inline;
- it has a queue-position counter ("24/57") and a mini-player toggle, which the handoff does
  not, and no AirPlay button, which it does;
- the cover opens a popover of go-to links, which the track menu already offers.

## Solution

### API

- **Repeat, this Mac:** `LibrespotClient.setRepeat(_:)` exists and refuses a mode the context's
  restrictions forbid (a station). It gets a `SpotifyPlayer.setRepeat` facade like `setShuffle`.
  The state comes back as `PlaybackState.repeatContext` / `repeatTrack`, already in every
  snapshot.
- **Repeat, another device:** the web player's repeat button sends `set_options` with
  `repeating_context` and `repeating_track` (`DealerConnection` reads exactly that, from a
  capture). `ConnectCommand` gains that endpoint, sent with both flags, so a device ends up in
  the one mode asked for.
- Volume, seek, heart, track menu: the existing `PlaybackViewModel` calls.

### Layout (`NowPlayingBarView`)

Left to right, standard controls only:

1. Shuffle as a `Toggle(.button)`, Previous, Play/Pause at 38 pt, Next, Repeat cycling
   off → all → one with `repeat` / `repeat.1`, the accent while on. All `.borderless`.
2. Cover 40 pt with 6 pt corners; title semibold over artist secondary; "m:ss / m:ss" at
   caption size, monospaced digits; a thin (`.mini`) seek `Slider` under them. The error
   message keeps taking the title's place while it is set.
3. Heart (red when liked), the track `Menu`, an AirPlay button that opens Wiedergabe auf, the
   volume icon and a 72 pt `Slider`, greyed with its explanation as tooltip when the device
   refuses volume.

The capsule is `min(780, container − 40)` wide and 64 pt high, centred, with `.glassEffect`.
The bar reads its own width: under 680 pt the volume goes, under 640 pt the time label.
The queue counter and the cover's popover go; the sidebar's badge and the track menu cover
them. The mini player stays a feature, moved from the bar to the View menu (⌥⌘M, as in Music),
and lays out the same bar.

Previous keeps restarting the track past **3 s**, not the handoff's 4 s: 3 s is what Spotify's
clients do, measured in `plans/done/previous-restarts-past-three-seconds.md`.

The inspector toggle the handoff puts last is the next PR's, with the inspector.

### Kept from the current bar

The overlay with `contentMargins` rather than `.safeAreaInset`: `LoggedInView` explains why the
bar overlays the content region, and the result is the same floating capsule.

## Verification

- Unit test: `ConnectCommand` encodes `set_options` with both repeat flags.
- Build, unit tests.
- Run the Debug build: screenshot the bar at full width and narrow the window past 680 and
  640 pt. Cycle repeat while this Mac plays and read the `PlaybackState` flags back; with the
  web player in Chrome active, cycle repeat from the bar and see the web player's own repeat
  button follow. Drag the inline volume. The AirPlay button opens Wiedergabe auf.

### Result

- The web player's repeat button, captured in Chrome while Spotifly played: all is
  `{repeating_context: true, repeating_track: false}`, one is **both true**, off both false.
  Those three bodies are the test's fixture (`repeat is the set_options the web player sends`).
- Live: on this Mac the bar cycles all → one → off and follows the player's state; with the
  web player active, the bar's repeat moved the web player's own button (it then offered
  "1 wiederholen aktivieren", i.e. it was on all). The volume drops out under 680 pt, the mini
  player (View → Mini-Player) lays out the whole bar.
- Reviews: `/simplify` moved the time and seek slider onto one timeline in a view of their own,
  made the volume its own view and the width a tier, and put repeat's two-flag rule and its
  order in `RepeatMode`. `/code-review` found the repeat button enabled on a radio, which
  refuses it; it now greys from `canRepeat`, read from the same restrictions as `canShuffle`.
  Codex then found that this also greyed repeat-one carried into a radio, whose next step, off,
  is allowed: only a step from off is greyed now. Its second finding, repeat on a mirrored
  track, is shuffle's open gap and is recorded there.
- Not seen live: a radio's greyed repeat button, which follows the same restrictions shuffle
  does.
