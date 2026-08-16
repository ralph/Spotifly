# The connect-state PUT echoes back to itself and runs into a 429

Status: **fixed and verified at runtime 2026-08-16**, on `break-connect-state-echo-loop` in
the sibling librespot checkout — 75 PUTs → 1 in the comparable window, no 429s, and a second
device's pause/resume/volume still handled without a position de-sync. Not yet offered
upstream. Detail in
[`connect-state-echo-implementation-plan.md`](connect-state-echo-implementation-plan.md).
Noticed while diagnosing
`plans/seek-bar-jumps-between-two-position-clocks.md`, where this loop is what made that
bug visible; it is not the cause of it.
Components: `librespot/connect/src/spirc.rs` — an upstream `fixme`, so a fix is a patch to
the checked-out librespot rather than to Spotifly
Found: 2026-08-14, in `../seek.log` and `../seek-after3.log`

## Symptom

While a context is starting, Spotifly PUTs its Connect state roughly every 400 ms for
twenty-odd seconds — around 80 requests in `../seek.log` — and then stops. In
`../seek-after3.log` the stop is Spotify saying no:

```
10:23:22.521  update position to 2:50 at 10:23:22.521
10:23:22.521  Requesting https://gew4-spclient.spotify.com:443/connect-state/v1/devices/spotifly_53879?…
10:23:22.537  ERROR librespot_connect::spirc] state update: Resource has been exhausted { Response status code: 429 Too Many Requests }
```

Three 429s in that run against 83 device-state PUTs; `../seek.log` has two against 79. (Both
files carry one further `hobs_`-prefixed registration PUT, which is where the "80 / 84" counts
in the first write-up came from.)

**Rate-limiting is the only thing observed to stop the loop.** Re-checked 2026-08-16: all five
bursts across the two logs end in a 429, and the only PUT gaps not preceded by one are the idle
stretch before playback starts. An earlier version of this note read `../seek.log` as having no
429s and concluded the opposite; that was a miscount. The loop does not run down on its own.

## Mechanism

Each PUT updates the cluster, and Spotify pushes the resulting cluster update back down the
dealer socket — including the one our own PUT just caused. `handle_cluster_update` sets
`update_state = true` whenever we are the active device, without checking whether the
update came from us:

```rust
} else if self.connect_state.is_active() {
    // fixme: workaround fix, because of missing information why it behaves like it does
    //  background: when another device sends a connect-state update, some player's position de-syncs
    //  tried: providing session_id, playback_id, track-metadata "track_player"
    self.update_state = true;
}
```

`connect/src/spirc.rs:1005`. That schedules another `notify()`, which PUTs again, which
echoes again. The period is the round trip, ~400 ms.

The comment says upstream knows: the branch exists to paper over a position de-sync when
*another* device sends an update, and it cannot tell that case apart from its own echo.

## Why it matters

- **It is a self-inflicted request storm** against an endpoint that rate-limits, and the
  429s land on the device-state PUT — the request that tells Spotify this Mac exists and
  what it is playing. Losing those is not free: other clients see a stale Spotifly.
- **It set the visibility of the seek-bar bug.** That bug was two position clocks
  disagreeing; this loop is what delivered the honest one often enough for the disagreement
  to be seen as jitter. With the loop quiet, the same disagreement was silent — which is
  exactly why the bar "settled" after twenty seconds.
- The burst is not constant: it accompanies a context start and dies out, so it costs
  requests rather than degrading steady-state playback.

## Approach

The distinction the code needs is whether a cluster update was caused by us.
`ClusterUpdate.devices_that_changed` carries the device ids, and `spirc` already logs them
— our own id is `self.session.device_id()`. Skipping `update_state = true` when the only
changed device is ours would break the loop while leaving the workaround intact for the
case it was written for.

That is a guess at the shape, not a tested patch, and it is upstream code: the workspace
builds whatever librespot is checked out (`CLAUDE.md`), so it can be tried locally and
offered upstream if it holds. The upstream comment records that session id, playback id and
track metadata were all tried for the underlying de-sync and none of them helped, so the
narrower change — leave the workaround, exclude our own echo — is the one worth testing
first.

**Confirmed 2026-08-16, from logs already on disk** — librespot logs `devices_that_changed`
already (`spirc.rs:990`), so no new run was needed. 449 cluster updates across five logs, none
naming more than one device. Foreign device ids do turn up while Spotifly is active
(`85a8659955…`, `c077d34a96…`), so the case the workaround exists for is reproducible and the
filter has something to distinguish. Detail in
[`connect-state-echo-implementation-plan.md`](connect-state-echo-implementation-plan.md).
