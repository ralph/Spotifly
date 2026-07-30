# librespot upstream PR: use local play_status for track transition decisions

Status: draft, not yet filed
Target: `librespot-org/librespot`, branch `dev` @ `9c7d756`
Carried on `spotifly-dev` @ `2efe5b6` until 2026-07-30; Spotifly has since moved to official librespot and no longer applies either patch.

This is the **first** of two independent upstream candidates found while building Spotifly.
The second is [`upstream-transient-load-failure.md`](upstream-transient-load-failure.md);
they are unrelated and should be filed separately.

## Title

Use local play_status for track transition decisions

## Summary

- **`handle_next` / `handle_prev`**: Use `play_status.is_playing()` instead of
  `connect_state.is_playing()` to decide whether the next/previous track should auto-play.
  `play_status` is the authoritative local source of truth, while `connect_state` reflects
  the remote-facing status which is synced on a deferred timer and can lag behind during
  loading transitions.
- **`play_request_id` filtering**: When `self.play_request_id` is `None` (Spirc hasn't
  loaded a track yet), adopt the id from the first player event. This prevents events from
  an already-playing Player being silently dropped — relevant for embedders that create a
  new Spirc while the Player is still active (e.g. session reconnection without destroying
  the Player).
- Adds `SpircPlayStatus::is_playing()` as the local counterpart to
  `ConnectState::is_playing()`.

## Motivation

I'm building a Spotify Connect client that keeps the Player alive across session reconnects
(to avoid audio interruption). After reconnecting, a new Spirc is created with the existing
Player. Two issues surfaced:

1. `handle_next` used `connect_state.is_playing()` which could return `false` during
   loading/buffering transitions even though local playback intent was active — causing the
   next track to load paused.
2. The new Spirc had `play_request_id: None`, so all player events (including `EndOfTrack`)
   were filtered out by the `is_current_track` check, preventing track transitions entirely.

Both fixes are small and backwards-compatible. In standard librespot usage (single Spirc
lifetime matching the Player), the behavior is unchanged — `play_status` and `connect_state`
agree, and `play_request_id` is set immediately on first load.

## Changes

- `connect/src/model.rs`: Add `SpircPlayStatus::is_playing()` helper
- `connect/src/spirc.rs`: Use `play_status.is_playing()` in `handle_next`/`handle_prev`,
  adopt `play_request_id` from first event when `None`

## Status notes for Spotifly (not part of the PR body)

The two changes have **different lifetimes** now that Spotifly no longer keeps the Player
alive across sessions:

- **`play_request_id` adoption** existed only to support that pattern. Spotifly's reconnect
  now rebuilds Session, Player, Mixer and Spirc as one generation, so nothing needs it any
  more. It remains a legitimate upstream contribution for other embedders doing what
  Spotifly used to do, but Spotifly no longer depends on it.
- **`play_status.is_playing()`** is an upstream correctness fix independent of any
  embedder's lifecycle: `connect_state` lags during rapid playback transitions, so
  next/previous can load the following track with the wrong play intent even with no
  reconnect involved. Whether Spotifly still *needs* it is the open question below.

**Resolved 2026-07-30: Spotifly no longer needs either change.** Tested against unpatched
`dev` @ `9c7d756` — a real outage, a full session rebuild, and an unattended track
transition that loaded the next track with `start_playing = true`. Spotifly now builds
against official librespot with no patch and no pin.

That does not make the `play_status.is_playing()` change less valid upstream: the window
where `connect_state` lags local play intent still exists in librespot, Spotifly just
stopped walking into it once the Player no longer outlives its Session. Worth filing on its
own merits; `play_request_id` adoption is the weaker of the two now, since its motivating
use case is one Spotifly abandoned.

Consider splitting this into two commits before filing, so the two changes can be reviewed
and accepted independently.
