# librespot upstream: a transient network error permanently deletes a track from the queue

Status: draft, ready to file as an issue (and follow with a PR)
Target: `librespot-org/librespot`, branch `dev` @ `9c7d756`
Found: 2026-07-30, while testing Spotifly's reconnect behavior

## Summary

Any failure to load or preload a track is reported to Spirc as `PlayerEvent::Unavailable`,
which removes that track from the queue permanently. There is no distinction between "this
track is genuinely unavailable" (region-blocked, embargoed, blacklisted) and "the network
was down for twenty seconds". A brief connectivity loss therefore silently and permanently
deletes the next track from the user's queue — it is skipped on playback and cannot be
reached by going back either.

The information needed to tell the two apart exists, but is discarded before it reaches the
decision: the load pipeline collapses every failure mode into `Option::None` and then into
`Result<_, ()>`.

## Observed behavior

Reproduced while playing a 47-track playlist over ethernet:

1. Track 1 playing. librespot begins preloading track 2 as usual.
2. Ethernet unplugged.
3. Preload of track 2 fails with a network error.
4. **Track 2 is marked unavailable and removed from the queue.** librespot moves on and
   preloads track 3 instead.
5. Track 1 finishes; playback continues with **track 3**. Track 2 is gone for the rest of
   the session.

Relevant log lines (timestamps as recorded, comments added):

```text
16:21:13.598 command=Preload(SpotifyUri("spotify:track:5eAH6VrfdDTO2qnZ26nhBC"))   # track 2
16:21:31.541 ERROR Unable to load audio item: Error { kind: Unknown,
               error: hyper_util::client::legacy::Error(SendRequest,
               hyper::Error(IncompleteMessage)) }                                  # network, not availability
16:21:31.554 Unable to preload SpotifyUri("spotify:track:5eAH6VrfdDTO2qnZ26nhBC")
16:21:31.554 marking spotify:track:5eAH6VrfdDTO2qnZ26nhBC as unavailable           # <-- the bug
16:21:31.554 finished filling up next_tracks (45)                                  # was 46
16:21:31.577 command=Preload(SpotifyUri("spotify:track:1Ued8E71QMvjTdbMvNAqZC"))   # track 3
...
16:21:49.861 command=Load(SpotifyUri("spotify:track:1Ued8E71QMvjTdbMvNAqZC"), true, 0)
```

Note the error kind: `Unknown`, wrapping a hyper `IncompleteMessage`. This is plainly a
transport failure, and it is classified exactly the same as a track that does not exist.

Importantly, the session itself never died in this run — the dealer reconnected on its own
and `SpircTask` stayed alive throughout. So this is not a reconnect-path problem and no
embedder-side recovery can compensate for it: by the time anything reconnects, the track is
already gone from `ConnectState`.

## Root cause

The failure information is destroyed in three steps, none of which is individually wrong,
but which together make the final decision unable to be correct.

**1. `PlayerTrackLoader::load_track` returns `Option`** — `playback/src/player.rs:992`

`find_available_alternative` (`playback/src/player.rs:941`) does know the difference: it
inspects `audio_item.availability`, which is an `AudioItemAvailability =
Result<(), UnavailabilityReason>`. On a genuine restriction it logs
`"Track is unavailable: {e}"` and returns `None`. On a metadata fetch failure it also ends
up returning `None`. The reason is logged and dropped.

**2. `PlayerInternal::load_track` returns `Result<_, ()>`** — `playback/src/player.rs:2426`

```rust
fn load_track(
    &mut self,
    spotify_uri: SpotifyUri,
    position_ms: u32,
) -> impl FusedFuture<Output = Result<PlayerLoadedTrackData, ()>> + Send + 'static
```

The error type is the unit type. The mechanism is at `playback/src/player.rs:2450`: the
loader thread only sends on the oneshot channel when it got `Some(data)`; on `None` the
sender is dropped, and the receiver resolves to `Err(RecvError)`, mapped to `Err(())`.

**3. Both poll sites treat any `Err` as unavailability**

Main load, `playback/src/player.rs:1404-1412` — the error is at least in scope here, and is
logged, but not consulted:

```rust
Poll::Ready(Err(e)) => {
    error!("Skipping to next track, unable to load track <{track_id:?}>: {e:?}");
    self.send_event(PlayerEvent::Unavailable { track_id, play_request_id })
}
```

Preload, `playback/src/player.rs:1435-1450` — the error is discarded outright:

```rust
Poll::Ready(Err(_)) => {
    debug!("Unable to preload {track_id:?}");
    self.preload = PlayerPreload::None;
    // Let Spirc know that the track was unavailable.
    if let PlayerState::Playing { play_request_id, .. }
     | PlayerState::Paused  { play_request_id, .. } = self.state
    {
        self.send_event(PlayerEvent::Unavailable { track_id, play_request_id });
    }
}
```

**Consequence** — `connect/src/spirc.rs:879`:

```rust
PlayerEvent::Unavailable { track_id, .. } => {
    self.handle_unavailable(&track_id)?;
    if self.connect_state.current_track(|t| &t.uri) == &track_id.to_uri() {
        self.handle_next(None)?
    }
}
```

`mark_unavailable` (`connect/src/state/tracks.rs:384`) removes every matching entry from
**both** `next_tracks` and `prev_tracks`, and marks matching entries unavailable. The
removal is not reverted when connectivity returns, so the track stays gone for the lifetime
of that context — the user cannot skip forward to it or back to it.

## Why this is worth fixing

- It triggers on ordinary, short connectivity loss — WiFi handover, a sleeping router, a
  train tunnel — not on an exotic edge case. Any outage long enough to span one preload
  attempt costs the user exactly one track, silently.
- It is silent and permanent. There is no error surfaced to the user and no recovery path;
  the queue simply has a hole in it.
- It defeats retry logic elsewhere. `AudioFileFetch` and the HTTP client retry at their own
  levels, but once the loader gives up, the track is deleted rather than left to be
  retried on its next turn.
- Embedders cannot work around it. The queue lives inside `SpircTask`/`ConnectState`; by
  the time an embedder notices anything, the track is already removed.

## Proposed fix

The minimal correct change is to stop reporting non-availability failures as
`Unavailable`. Two levels, and I would propose them as one PR:

**Level 1 — preserve the reason (required).** Change `PlayerTrackLoader::load_track` to
return a `Result` with an error type that at least distinguishes:

- `Unavailable(UnavailabilityReason)` — from `audio_item.availability`, plus "no
  alternatives found"
- everything else (metadata fetch, audio key, CDN, decode) — transient / unknown

Then propagate that through `PlayerInternal::load_track` in place of `Result<_, ()>`.

**Level 2 — act on it.** At both poll sites, emit `PlayerEvent::Unavailable` only for the
genuine-unavailability variant. For transient failures, the conservative behavior is:

- *Preload path*: do nothing beyond clearing `self.preload`. A failed preload is only an
  optimization; the track will be loaded normally when its turn comes. This alone fixes the
  reported symptom.
- *Main load path*: this one does need to do something, since playback is stuck. Options,
  in increasing ambition: (a) emit a distinct `PlayerEvent::LoadFailed` and let Spirc
  decide; (b) retry once after a short delay before giving up; (c) keep the current
  skip-to-next behavior but without removing the track from the queue. Option (c) is the
  smallest change that preserves current behavior for users while fixing the data loss.

An even smaller stopgap, if the maintainers prefer minimal surface: **change only the
preload site to not emit `Unavailable`**. That fixes the observed bug with a handful of
lines and no API change, since a failed preload is never a reason to conclude anything
about availability. The main-load path would remain over-eager, but it is far rarer — it
requires the outage to coincide with an actual track transition rather than a preload.

## Risks and compatibility

- `PlayerEvent::Unavailable` semantics become *narrower* (only genuine unavailability).
  Consumers that used it as a general "load failed" signal would see fewer events; adding a
  distinct event for the transient case keeps them able to observe both.
- Changing `PlayerInternal::load_track`'s error type from `()` is internal to
  `playback`; `PlayerTrackLoader::load_track` is likewise not public API.
- Genuinely unavailable tracks must keep being skipped, or playback stalls on a track that
  can never load. The `find_available_alternative` path already computes this correctly, so
  behavior there should be unchanged.

## Reproduction

1. Start playback of a playlist with several tracks, on a wired or otherwise
   quickly-severable connection.
2. Wait until the log shows `command=Preload(...)` for the *next* track.
3. Sever the connection before that preload completes.
4. Observe `Unable to preload ...` followed by `marking ... as unavailable` and
   `finished filling up next_tracks (N-1)`.
5. Restore the connection and let the current track finish. Playback continues with the
   track *after* the one that was preloading.

Expected after the fix: step 4 logs the failed preload but does not mark anything
unavailable, `next_tracks` keeps its length, and step 5 continues with the correct track.

## Verification notes

- Present in official `dev` @ `9c7d756`, which is byte-identical to `upstream/dev`.
- `git diff dev spotifly-dev -- playback/src/player.rs connect/src/state/tracks.rs` is
  empty, so this is not an artifact of the local `spotifly-dev` patches.
- Reproduced against `spotifly-dev` @ `2efe5b6`; the two patches on that branch
  (`play_status.is_playing()` and `play_request_id` adoption) touch `connect/src/spirc.rs`
  and `connect/src/model.rs` only, and are unrelated.

## Relation to Spotifly

Nothing in the Spotifly integration layer can fix this, and no local workaround is
proposed. Two indirect notes:

- Spotifly's reconnect rebuilds the session and issues a fresh context load
  (`resume_via_load`), which re-fetches the track list from the server and would repair the
  hole. That only helps when the session actually dies; in the reproduction above the
  session survived, so the hole persisted.
- This is the **second** independent upstream candidate found in this work, alongside
  `play_status.is_playing()` (see `librespot/pr.txt`). They are unrelated and should be
  filed separately. Neither is a blocker for migrating Spotifly to unmodified librespot —
  this one affects stock librespot identically, so carrying the fork does not avoid it.
