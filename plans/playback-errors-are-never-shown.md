# Playback errors are never shown

Status: **planned** 2026-09-28, on `playback-errors`, with a draft PR.

Component: `Spotifly/ViewModels/PlaybackViewModel.swift` (`errorMessage`),
`Spotifly/Views/NowPlayingBarView.swift`, and the views that write the view model's error:
`TrackRow.swift` and `Components/TrackContextMenu.swift`.

## What happens

`PlaybackViewModel.errorMessage` is set in sixteen places and read in none:

- in the view model: a play or `playTracks` that fails, locally or on a remote device; a radio
  start; `addToQueue` with no player; an initialization that throws or never becomes ready;
  toggling the playing track's favorite; and every command that fails in
  `sendTransportCommand`: next, previous, seek, pause, resume, shuffle and add to queue.
  Skip, seek and radio have been `async throws` since #71, so their failures reach it now
  as well;
- in the views: a favorite toggled from a track row, its context menu or the now-playing bar,
  and adding to, removing from or creating a playlist from a track's menu.

The last place it was on screen was the start page, as red caption text. The start-page
overhaul (`9b905ad`, 2026-01-09) dropped it, and nothing has shown it since. The only
`errorMessage` on screen now is `AuthViewModel`'s, on the sign-in screen. So a play that
fails, a Next that times out or a favorite that did not save looks like a button that does
nothing. The reason is only in the Debug log.

What stays out, as now:

- **Declined commands** (`SpclientError.isDeclined`): Spotify refusing on its own terms, such
  as Previous with nothing behind it, or a remote volume change an iPhone will not take. The
  user pressed a control and nothing is broken, so these stay log-only, and Previous goes on
  answering `no_prev_track` with the seek it stood for.
- **`CancellationError`**: a newer load took over. It reports for itself.

## Where the error appears

**In the now-playing bar, in place of the track's title and artist, for five seconds.** A red
caption with a warning glyph, two lines at most, and the full text as a tooltip. Then the
title comes back.

Why there:

- **It is where the user is looking.** Most of these follow a press on the bar itself, and
  the rest come from a track's menu, with the bar in view below it.
- **It works in the mini player.** The bar *is* the mini player, a 600 × 96 window, and it
  has no room above it. A banner above the bar, the obvious alternative, needs a second
  placement there or silently shows nothing.
- **No new layout.** The title and artist take about 30 of the row's 34 points, the cover's
  height, and two caption lines fit in the same space. Nothing moves, nothing covers the
  content, and nothing can be clicked by mistake while it shows.

The cost is that the track's name is hidden while the error shows. Five seconds is enough to
read a sentence, and short enough that a stale error does not stand in for the song.

**How it clears.** The bar clears it five seconds after it appears, with a `.task(id:)` on the
message. The bar is mounted whenever the user is logged in, in the window and in the mini
player alike, so the timer always runs. Switching between the two restarts the five seconds,
which is harmless. The view model's existing clears stay: a new play, a new remote start,
`addToQueue`, and an initialization that succeeds each clear the error when they start.

Successful transport commands deliberately do **not** clear it. A Next that works would also
wipe a favorite that failed a second earlier, and the timer ends the error soon enough anyway.
The timer is keyed on the text, so a second failure with the same message does not restart it.
The error then clears five seconds after the first failure. That is fine.

VoiceOver users get the same message as an announcement, since a caption changing in place
is not announced by itself.

## Messages

The view model passes on `error.localizedDescription`, which is English and sometimes
technical ("Spotify rejected the request (HTTP 502)"). Translating the errors the stack throws
is out of scope here. The app's own prefixes are not, though, because they become visible
with this change: "Failed to update favorite: %@" (three sites), "Failed to add to playlist:
%@", "Failed to remove from playlist: %@", "Failed to create playlist: %@", "Player did not
become ready", "Player not initialized" and "No tracks to play". They get `error.*` keys in
the three `Localizable.strings`, in the form `error.remove_album %@` already uses. The three
favorite sites share one key.

## Steps

One commit each.

1. **Show the error in the bar.** `NowPlayingBarView.trackInfo` shows `errorMessage` when it is
   set and the track otherwise, with the five-second clear and the announcement. About twenty
   lines, all in the bar.
2. **Localize the app's own messages** (see [Messages](#messages)).
3. **Changelog** under Unreleased, Fixed, and this plan's status, here and in `README.md`.

Nothing changes in `sendTransportCommand`, the declined check or the cancellation filter.

## Verification

- Build and the unit suite (374 tests on `main`). There is no new unit test. The logic is a
  view's `if` and a timer, and the view model's writes are unchanged.
- Live, a play that fails: `SPOTIFLY_DEBUG_AUTOPLAY` with a well-formed album uri that does
  not exist. The context resolve fails, and `startLocally` sets the error. The bar should show
  it and give the title back after five seconds.
- Manual, by Ralph: with Wi-Fi off, the heart in the bar and in a track row; Next while
  another device plays; the same in the mini player; and Previous at the first track of a
  remote device, which must stay silent (declined).
