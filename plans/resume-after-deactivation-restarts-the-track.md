# Resuming after a deactivation restarts the track instead of continuing it

Status: **fixed 2026-08-03 by Option B, not yet confirmed at runtime** (`258f570`). The
one-line deletion held: all five readers were checked, none regress, three improve. The
outstanding check is the reproduction below — resume should now log a non-zero seek.
Components: `rust/src/lib.rs`
Found: 2026-08-03, in `../sleep2.log`, the run confirming
`plans/wake-from-sleep-loses-queue-and-resume.md`

## Symptom

Playback is paused, the device stops being the active one, and some time later the user
presses play. Playback comes back — but from **0:00 instead of where it was paused**.

```text
11:52:30.288  PlaybackState: playing=true, paused=true, pos=12087ms, dur=131638ms
11:52:30.515  command=Stop                                    # ← during deactivation
…
12:07:48.469  Resume fallback: loading context spotify:album:3Neq… at 0ms   # ← should be 12087
12:07:49.069  PlayerEvent::Playing: … at 0ms
```

12 seconds were lost in the observed run. The amount lost is however far into the track the
user was, so it can be most of a track.

## Mechanism

`resume_via_load` takes its seek target straight from `POSITION_MS`
(`lib.rs:2355`). That global is the *live* Player position, and two events zero it:

```rust
Some(PlayerEvent::Stopped { .. }) => {
    IS_PLAYING.store(false, Ordering::SeqCst);
    update_position(0);              // lib.rs:1517
}
Some(PlayerEvent::EndOfTrack { .. }) => {
    IS_PLAYING.store(false, Ordering::SeqCst);
    update_position(0);              // lib.rs:1531
}
```

Zeroing on `EndOfTrack` is right — the track finished, and the next one starts at 0.
Zeroing on `Stopped` is where the resume point dies: librespot's `handle_disconnect` sends
`command=Stop` to the Player whenever the device is deactivated (visible at 11:52:30.515,
immediately after `EmitSessionDisconnectedEvent`). So the position is destroyed at
deactivation, fifteen minutes before anybody asks to resume.

One value is serving two jobs that disagree here: **where the Player is now**, for which 0
is correct once it has stopped, and **where playback should pick up**, which must survive a
stop. Swift is not a fallback source — it held the correct 12087 ms until Rust's own
callback overwrote its anchor (`Position anchor: 12087 -> 0`, 12:07:47.962).

## Scope

Small, and worth being precise about before spending anything on it.

**Does not bite:**

- Ordinary pause → play while Spotifly stays the active device. `spirc.play()` succeeds
  against a Player that still has the track loaded, the load fallback never runs, and
  `POSITION_MS` was never zeroed. This is the overwhelmingly common case.
- Track transitions, `EndOfTrack`, starting new content — all unaffected.

**Bites only on the load-fallback path**, i.e. resume after the device stopped being
active: the wake-from-sleep case, and the "nobody is active" case that
`plans/wake-from-sleep-loses-queue-and-resume.md` made reachable.

**Not a regression.** Before that fix this path could not resume at all, so the choice this
defect makes is between "resumes at the wrong position" and the previous "does not resume".

## Is there an easy fix?

Yes — probably a one-line deletion. `POSITION_MS` has only five readers, so the blast
radius is knowable in full:

| Reader | Purpose | Affected by not zeroing on `Stopped`? |
| --- | --- | --- |
| `lib.rs:2355` `resume_via_load` | resume anchor | **yes — this is the fix** |
| `lib.rs:2664` `current_position_ms` → `spotifly_get_position_ms` | Swift drift check | possibly, see below |
| `lib.rs:1558`, `1570` `ShuffleChanged` / `RepeatChanged` | position in the published state | possibly |
| `lib.rs:1528` `EndOfTrack` | debug log only | no |

### Option B — stop zeroing on `Stopped` (1 line) — **taken**

Checked before committing, since this was the whole question:

| Reader | Before | After |
| --- | --- | --- |
| `freezePositionForDisconnect` | saw 0, fell back to its own displayed value | gets the real stopped position — what the workaround was reaching for |
| `syncPositionAnchor` | saw 0, skipped by its "don't adopt 0 over a valid anchor" guard | adopts the real position; the guard stays correct, just less often needed |
| `ShuffleChanged` / `RepeatChanged` publish | sent 0 to Swift, overwriting its anchor | sends the real position — this is what clobbered a correct 12087 ms in `sleep2.log` |
| `checkDriftAndSync` comparison | unreachable while stopped (`guard isPlaying`) | unchanged |
| `EndOfTrack` debug log | — | unchanged |

None regress, three improve. The end-of-queue case is untouched because `EndOfTrack` still
zeroes. One comment on `freezePositionForDisconnect` was corrected: a teardown no longer
produces the zero it names, though `EndOfTrack` and the logout reset still do, so its guard
stays.


Delete `update_position(0)` from the `Stopped` arm. `EndOfTrack` keeps its zeroing, so a
finished track still starts the next one at 0; a *stopped* one remembers where it stopped.

There is real evidence this removes a wart rather than adding one.
`PlaybackViewModel.freezePositionForDisconnect` already carries an explicit workaround for
this exact zero:

> The `rustPosition > 0` clause guards the gap between the two: Rust reports 0 both for "at
> the start" and for "nothing loaded". Snapping a running progress bar to zero because a
> rebuild cleared the position would be worse than holding the last shown value.

Swift is, in other words, already compensating for Rust zeroing a position it should have
kept. Two things to check before believing the one-liner:

- **The three drift-check sites** (`PlaybackViewModel.swift:925`, `:1209`, `:1255`). All are
  gated on `isPlaying` / `isConnectionReady`, and `Stopped` clears `IS_PLAYING`, so a stale
  non-zero value should be inert — confirm rather than assume.
- **Genuine end-of-queue stop.** The bar would hold the last position instead of snapping to
  0. Arguably more honest, but it is a visible change and should be looked at.

### Option A — separate the two meanings (~6 lines)

If B's display effects turn out to matter, keep `POSITION_MS` exactly as it is and have
`update_position` also maintain a resume anchor that `Stopped` does not clear:

```rust
fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
    if position_ms > 0 {
        RESUME_POSITION_MS.store(position_ms, Ordering::SeqCst);
    }
}
```

`resume_via_load` then reads `RESUME_POSITION_MS`, and `EndOfTrack` clears it explicitly.
Costs a second global, which runs against the recent consolidation work (the
`ConnectionState` change removed five), and makes "resume anchor" a real concept rather
than a side effect — the honest version of what the code already means. Prefer B; fall back
to A only if B is shown to break the display.

### Rejected

- **Swift supplies the position to `spotifly_resume`.** Swift's anchor is clobbered by the
  same Rust callback, so it would need its own guard too — a two-sided change to fix a
  one-sided problem.
- **Read the position back from librespot's `connect_state`.** More coupling to librespot
  internals than the defect is worth.

## To reproduce

Play locally, pause part-way into a track, cause the device to stop being active (sleep, or
anything that reaches `handle_disconnect`), then press play. The log line to watch is
`Resume fallback: loading context … at <n>ms` — a regression reads `0ms` where the paused
position was non-zero.

## Related

- `plans/wake-from-sleep-loses-queue-and-resume.md` — made this path reachable; the run that
  confirmed it is where this was found.
- `plans/position-interpolation-runs-on-during-outage.md` — established the one-clock rule
  and wrote the `freezePositionForDisconnect` comment quoted above, which is the strongest
  evidence for Option B.
