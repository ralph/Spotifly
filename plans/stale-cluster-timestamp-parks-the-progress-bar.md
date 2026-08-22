# A stale cluster timestamp can park the progress bar at the end of the track

Status: **fixed 2026-08-03 (`67a6c16`), not confirmed at runtime.** Both paths now share
`positionAnchor(forPosition:takenAt:)`, which discards the compensation as recommended
below. Confirming it needs a remote device playing with a cluster timestamp stale enough to
overshoot the track end, which is not something that can be provoked on demand — the
regression signal is the log line, not a reproduction.
Components: `Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-08-03, reviewing the position code for simplification after
`plans/resume-after-deactivation-restarts-the-track.md`

## Symptom

While Spotifly is **monitoring a remote device** (a phone or speaker is playing, Spotifly
is not the active device), the progress bar can jump to the very end of the track and sit
there, while the track carries on playing normally on the other device. It corrects itself
on the next cluster update carrying a fresher timestamp, or at the next track change.

Not observed in the wild. Found by reading, and by noticing a 735-second-old timestamp in
`../sleep2.log` that was harmless only by luck — see *Reachability*.

## Mechanism

Two paths anchor the position from a snapshot that was true at some earlier moment, and
both run the clock back by the elapsed time so interpolation does not report a stale
position as current. They disagree about one thing.

`applyWebAPIPlaybackState` discards the compensation when it would overshoot:

```swift
let compensated = Int64(progressMs) + elapsedMs
let stale = durationMs > 0 && compensated > Int64(durationMs)
…
anchorPosition(posMs, at: stale ? now : now - Double(elapsedMs) / 1000.0)
```

`handlePlaybackStateUpdate` has no such guard:

```swift
let elapsedSinceTimestamp = max(0, nowMs - state.timestampMs)
let elapsedSeconds = Double(elapsedSinceTimestamp) / 1000.0
anchorPosition(posMs, at: now - elapsedSeconds)
```

When compensation overshoots, the anchor is back-dated so far that
`interpolatedPositionMs` computes a position past the end of the track. `clampedToTrack`
pins it to the track length, so the bar parks at the end rather than showing nonsense —
which is why this is cosmetic rather than alarming.

The reasoning behind the Web API guard applies verbatim to the Mercury path, and its
comment already says so: *"the API timestamp is when Spotify last received a state change —
it can be arbitrarily stale during uninterrupted playback."* That is a statement about
Spotify's timestamp, not about the endpoint that delivered it.

## Why only the remote path

Both callbacks arrive at the same Swift handler, but their timestamps come from different
places in Rust:

| Source | Timestamp | Staleness |
| --- | --- | --- |
| `send_local_playback_state` (`lib.rs:2006`) | `current_timestamp_ms()` | always now — compensation is a no-op |
| `send_playback_state` (`lib.rs:1955`) | `player_state.timestamp`, with `position_as_of_timestamp` | Spotify's; can be minutes old |

So the local path cannot trigger this: it stamps every snapshot at the moment it sends it.
Only cluster updates carry a timestamp that can be old, and Spotifly only consumes those
for playback state when another device is active.

Compensation itself is **correct and necessary** on that path — `position_as_of_timestamp`
plus elapsed time *is* the current position of a healthy remote device. The defect is only
the missing upper bound.

## Reachability

Needs a cluster update where `position_as_of_timestamp + elapsed > duration` **and**
`isPlaying` ends up true. `isPlaying` for a non-active device is
`state.isPlaying && !state.isPaused`, so the remote device must be actively playing.

For a three-minute track at 0:12, that means the cluster timestamp must lag by more than
about 2:48. Plausible given what the Web API comment asserts about the same field, but not
something that happens on every update.

The 735-second-old timestamp in `sleep2.log` did **not** trigger it, and the reason is
worth recording: that update carried `paused: true`, so `isPlaying` came out false and
`interpolatedPositionMs` returned the frozen value instead of interpolating. The bad anchor
time was stored and simply never used. Every path that later resumes playback re-anchors
(`resume()`, `syncPositionAnchor` from the drift check, or the next cluster update), so a
stored-but-unused back-dated anchor does not appear to survive into a playing state.

## Fix sketch

The two blocks are the same computation with one extra condition, so the fix and the
de-duplication are the same change — one helper returning the anchor time:

```swift
/// The moment a snapshot's position was true, for anchoring.
///
/// Compensation is discarded when it would push the position past the end of the track: a
/// snapshot that stale cannot describe what is playing now, and back-dating the anchor by
/// it parks the progress bar at the end.
private func anchorTime(position: Int, takenAt timestampMs: Int64, duration: Int) -> Double
```

Both call sites then become `anchorPosition(posMs, at: anchorTime(…))`. Roughly 15 lines
net, and it removes the duplicated arithmetic flagged as item #4 in the position-code
simplification pass.

### Discard the compensation, do not clamp it

Take the Web API path's existing behaviour — drop the compensation entirely and anchor at
the raw position — rather than capping the elapsed time so the result lands on the track
end. Worked through on a three-minute track whose snapshot reads 0:12 and is five minutes
old, so compensation wants 5:12:

| | Anchors at | On screen |
| --- | --- | --- |
| No guard (today's Mercury path) | 0:12, clock rewound 5:00 | computes 5:12, pinned by `clampedToTrack` — **stuck at the track end** |
| Clamp | 0:12, clock rewound 2:48 | lands exactly on 3:00 — **also stuck at the track end** |
| Discard | 0:12, clock starts now | **0:12, advancing normally** |

Clamping is not really a third option. `clampedToTrack` already bounds the display, so
clamping and no guard look **identical** to the user; it tidies the arithmetic without
changing the symptom. The real choice is between discarding and leaving things as they are.

Both remaining answers are wrong, because a snapshot that stale cannot say what is playing
now — so the question is which wrong is less confusing. Discarding shows a position that is
too *early*, possibly by minutes, but it is a genuinely measured value, it looks plausible,
and it advances until the next update corrects it. Clamping freezes the bar at the end of
the track while the music plays on, which does not read as stale, it reads as broken.

Clamping is truer about *elapsed time* — five minutes really did pass. But the thing on
screen is a position indicator, and "this track is finished" is a worse lie than "this
track is a little behind", especially as the first does not self-correct and the second
does. Discarding also makes both paths behave the same, which is the point of merging them.

One thing to preserve while doing it: **the differing log lines.** The Web API path logs
staleness explicitly and the Mercury path logs the raw elapsed time. Keep both — these logs
are how every position bug on this branch was diagnosed.

## Not worth doing

- Gating compensation on `isActiveDevice`. The local path's timestamp is always fresh, so
  compensation there is already a no-op; gating changes nothing and leaves the remote path,
  the only affected one, unfixed.
- Changing what Rust sends. Both timestamps honestly mean "the moment this position was
  true". The field is fine; only the consumer's missing bound is not.

## To reproduce

Start playback on a phone, leave Spotifly monitoring it without becoming the active device,
and watch for a cluster update whose logged `timestamp was <n>ms ago` exceeds the remaining
track time. The bar jumping to the end while the phone plays on is the symptom.

Since the window cannot be provoked on demand, the practical check is the log rather than
the screen. Both paths now emit the same suffix, so a compensation that was dropped says so:

```text
Position anchor: 12087 -> 12087 (timestamp was 735255ms ago, stale — ignoring compensation)
```

Before the fix that line could only ever appear with the `Web API position anchor:` prefix.
Seeing it with the plain `Position anchor:` prefix is the fix working.

## Related

- `plans/position-interpolation-runs-on-during-outage.md` — established the one-clock rule
  these two paths implement.
- `plans/resume-after-deactivation-restarts-the-track.md` — the position work that led here.
