# Break the connect-state echo loop

Ticket: [`connect-state-put-echoes-itself-into-a-429.md`](connect-state-put-echoes-itself-into-a-429.md)
Status: **fixed and verified at runtime 2026-08-16; Task 4 (upstream) open.** Branch
`plan/connect-state-echo` for this plan; the patch itself is
`break-connect-state-echo-loop` in `../../librespot` (local only, not pushed).
**75 PUTs → 1** in the comparable window, and no 429s.
Priority: **4 of 5.** ~80 Connect PUTs in twenty seconds, answered with a 429.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Spotifly stops answering its own cluster echo with another PUT, without losing the
workaround that branch was written for.

## The loop

Each PUT updates the cluster; Spotify pushes the resulting cluster update back down the dealer
socket — **including the one our own PUT just caused**. `handle_cluster_update` sets
`update_state = true` whenever we are the active device, without checking where the update came
from (`librespot/connect/src/spirc.rs:1005`):

```rust
} else if self.connect_state.is_active() {
    // fixme: workaround fix, because of missing information why it behaves like it does
    //  background: when another device sends a connect-state update, some player's position de-syncs
    //  tried: providing session_id, playback_id, track-metadata "track_player"
    self.update_state = true;
}
```

That schedules another `notify()` after `UPDATE_STATE_DELAY` (200 ms, `spirc.rs:146`), which
PUTs, which echoes. Measured in `../seek-after3.log`: cluster update → PUT ~280 ms, PUT →
cluster update ~140 ms, **median period 418 ms**.

`notify()` (`spirc.rs:1896`) reaches the wire through `connect_state.send_state()` →
`state.rs:499` → `put_connect_state_request` → `PUT /connect-state/v1/devices/{device_id}`.
Its error is logged as `state update: {why}`, which is exactly the 429 line — so the 429 does
land on the device-state PUT, the request that advertises this Mac.

**The loop has no self-limit; the server is the only brake.** Every burst in both logs ends in
a 429 — five of five. `../seek-after3.log` has 83 device-state PUTs and three 429s;
`../seek.log` has 79 and **two** (05:48:22.522Z and 05:48:38.833Z). The only gaps not preceded
by a 429 are the idle stretch before playback starts, in both runs. (Both files also carry one
`hobs_`-prefixed registration PUT, which is where the "80 / 84" counts came from.)

> An earlier draft of this plan read `../seek.log` as having no 429s and concluded that
> rate-limiting was "one way the burst ends, not the only one". That was a miscount. The
> correction matters for T6: 79 and 83 are **rate-limited floors**, not the burst's natural
> length, so the post-fix comparison has to be PUTs per minute inside a burst window rather
> than a raw total against those numbers.

**The upstream comment is doing real work here.** It records that session id, playback id and
track metadata were all tried against the underlying de-sync and none helped. So the branch is
not obviously deletable, and a fix that removes it is a fix that re-opens whatever it was
papering over.

## Why it matters

- A self-inflicted request storm against an endpoint that rate-limits, and the 429s land on
  the **device-state PUT** — the request that tells Spotify this Mac exists and what it is
  playing. Other clients then see a stale Spotifly.
- It set the visibility of the seek-bar bug: the loop delivered the honest clock often enough
  for the two-clock disagreement to read as jitter. With the loop quiet, the same disagreement
  was silent, which is why the bar appeared to "settle" after twenty seconds. **Fixing this
  will make that class of bug quieter, not absent** — worth remembering before reading a
  future calm log as proof of correctness.
- The burst accompanies a context start and dies out, so it costs requests rather than
  degrading steady-state playback. That is why this is fourth and not first.

## Task 1 — confirm the premise ✅ done, 2026-08-16

The whole approach rested on one unverified assumption: **that the echoed update carries only
our own device id.** It holds.

**No new run was needed.** librespot already logs the field (`spirc.rs:990`), so the logs
captured on 2026-08-14 already carry the answer:

```
cluster update: Ok(DEVICE_STATE_CHANGED) from spotifly_53879, active device: spotifly_53879
```

- [x] **T1.** Across all five logs on disk: **449 cluster updates, zero naming more than one
      device.** `devices_that_changed` is `repeated string` (`protocol/proto/connect.proto:18`),
      so a multi-device list would join as `a, b` — none appears. 442 name exactly the active
      device, which in those runs is us; 7 name a foreign device.
- [x] **T2.** Loop shape confirmed in `../seek-after3.log`: PUT → cluster update naming only us
      → `update_state = true` → PUT, at a median period of 418 ms. 83 PUTs against 80 cluster
      updates — close to 1:1, as a self-sustaining loop should be.
- [x] **T3.** Premise true; proceeding to Task 2.

**The case the workaround exists for is real and reproducible.** Foreign device ids do arrive
in `devices_that_changed` while Spotifly is active — `85a8659955…` twice in
`../seek-after3.log`, `c077d34a96…` in `../playlist2.log`. T8 therefore has a known repro
rather than a hypothetical one, and the filter has something to distinguish.

## Task 2 — the narrow change ✅ done, 2026-08-16

Skip `update_state = true` when the **only** changed device is ours. This leaves the workaround
intact for the case it was written for — another device sending an update — and removes only
our own echo.

- [x] **T4.** Implemented in the checked-out librespot as
      `break-connect-state-echo-loop` (branched from `dev`), one commit touching
      `connect/src/spirc.rs` only. `rust/Cargo.toml` uses path dependencies with no revision
      pin precisely so a local librespot patch is a checkout and a rebuild.
- [x] **T5.** Kept narrow — and narrower than this plan first proposed. The guard is
      `DEVICE_STATE_CHANGED` **and** `devices_that_changed == [our device id]` exactly.
      Adding the reason gate costs one condition and buys the claim being made honestly:
      "named only us" implies "caused by us" for a *state change*, not for a device
      appearing, disappearing, or changing volume. An empty list and a list naming us
      alongside another device both fall through to the workaround.

**The skip is logged** (`debug!("ignoring cluster update caused by our own state update")`),
so T6 can count suppressions directly rather than inferring them from a lower PUT total.

The tempting larger change was to delete the workaround branch entirely; the upstream comment
is evidence against that, and a de-sync it was hiding would be a worse bug than the one being
fixed. It stays.

**Why the filter cannot swallow a remote command.** Cluster updates and connect-state requests
arrive on **separate select arms** — `spirc.rs:486` and `spirc.rs:493`. A remote transfer,
play, pause or seek is handled by `handle_connect_state_request`, which sets
`update_state = true` at `spirc.rs:1163` on its own; volume has its own arm again. So nothing
another client *asks* of us travels through `handle_cluster_update`, and suppressing our own
echo there cannot drop a response we owed. Note also that in the branch being changed the
cluster's `active_device_id` is already known to be ours — `became_inactive` above it took the
other case — so "the only changed device is ours" is a check against `self.session.device_id()`
and not merely against the active device.

## Task 3 — verify by counting ✅ done, 2026-08-16

Captured in `../echo-fix.log`: login, a context start, ~90 s of untouched playback, then a
second device (`c077d34a96…`) pausing, resuming and changing the volume.

**Like-for-like, PUTs in the 60 s after `PlayerEvent::Playing`:**

| run | PUTs in first 60 s | 429s |
| --- | --- | --- |
| `../seek.log` (before) | **75** | 2 |
| `../seek-after3.log` (before) | 24 — *floor, the burst was cut by a 429 at 11 s* | 3 |
| `../echo-fix.log` (after) | **1** | **0** |

Whole session after the fix: **17 device-state PUTs in 2m38s, 11 echoes suppressed, no 429.**
The loop is broken rather than slowed — each suppression is the end of its chain, and the
longest stretch without a PUT is 88 s of steady playback that previously would have been the
densest part of the burst.

- [x] **T6.** 75 → 1 in the comparable window; 17 across the whole session. Not zero, as
      wanted: the survivors are the legitimate paths — track change (`spirc.rs:758`), player
      events (`:884`), remote requests (`:1163`).
- [x] **T7.** **Zero 429s**, in a scenario that produced them every previous run.
- [x] **T8. The case the workaround exists for still works.** The second device paused,
      resumed and changed the volume, and **the position did not de-sync**:

      05:18:35.799  handling: 'endpoint: pause' from c077d34a96…
      05:18:35.848  PlayerEvent::Paused  at 112197ms
      05:18:41.212  handling: 'endpoint: resume' from c077d34a96…
      05:18:41.213  PlayerEvent::Playing at 112197ms

      Paused and resumed on the same millisecond, held flat across four state updates in
      between, and tracked real time correctly afterwards. Volume propagated too
      (65535 → 38911 in four steps, and again later).
- [x] **T9.** Spotifly stayed visible and addressable throughout — the second device found it
      in the device list and successfully commanded it three times, which is the property the
      429s were destroying.

**The reason gate paid for itself immediately.** At 05:18:36.958 a `DEVICE_VOLUME_CHANGED`
arrived naming only us — the echo of our own delayed volume PUT. The gate let it through to
the workaround, costing exactly one PUT of the seventeen. Filtering on "names only us" alone,
as this plan originally proposed, would have swallowed it.

The only warnings in the run are two `context is not available` at startup; both pre-fix logs
carry the same two, so they are unrelated.

## Task 4 — upstream it

- [ ] **T10.** Offer the patch to `librespot-org/librespot`. The `fixme` invites it, and every
      embedder that is an active Connect device has this loop. Two other drafts are already
      waiting in [`librespot/`](librespot/); consider filing together.

## Verification

- [ ] **Run librespot's own checks in `../../librespot`, not just ours.** `rust/` is a
      single-package workspace whose only member is `spotifly-rust`: path dependencies are
      *compiled* by `cargo check` there, but librespot's unit tests, formatting and lints never
      run. Verified — `cargo test --no-run` in `rust/` builds one test binary,
      `spotifly_rust` — and `cargo metadata --no-deps` lists exactly one package. So the
      patched package needs `cargo test -p librespot-connect`, `cargo fmt --check` and
      `cargo clippy` **from the librespot checkout**, or this checklist can pass green while
      the package we changed fails its own validation. That also matters for Task 4: an
      upstream PR is judged by librespot's CI, not ours.
      **But do not read those tests as covering this change** — the only test-carrying file in
      `connect/` is `shuffle_vec.rs`, nowhere near `spirc.rs`. They are a
      did-not-break-anything gate and a prerequisite for upstreaming; T6–T9 are the actual
      verification.
Run against the patch, 2026-08-16 — all green:

- [x] From `../../librespot`: `cargo fmt --check -p librespot-connect` exit 0,
      `cargo check -p librespot-connect` exit 0, `cargo clippy -p librespot-connect
      --all-targets` exit 0 with **zero** warnings, `cargo test -p librespot-connect`
      3 passed / 0 failed
- [x] `cargo fmt --check`, `cargo check`, `cargo test` in `rust/` — all exit 0, 33 passed
- [x] `xcodebuild … test -only-testing:SpotiflyTests` — **TEST SUCCEEDED, 294 passed /
      0 failed**, matching the `main` baseline exactly
- [x] The PUT count from T6, the 429 check from T7, and the second-device regression from T8 —
      all in Task 3 above, from `../echo-fix.log`

**None of the static checks exercises the change** — they are a build-and-don't-regress gate.
Task 3 is the verification.

## Risks

- **This is a patch to a dependency the workspace deliberately keeps unpatched.** The
  workspace `CLAUDE.md` says official librespot is used and no fork or patch is required.
  A local patch is acceptable as a way station to upstreaming (Task 4), not as a destination —
  and while it is carried, the sibling checkout silently decides what the app builds, so
  `git -C ../librespot log --oneline -1` is the first thing to check when behaviour looks odd.
- **The workaround exists for a real de-sync**, tried against three other approaches that
  failed. T8 is not optional.
- **A quieter log is not proof of correctness** — see the seek-bar note above. Judge by the
  PUT count and the second-device check, not by the absence of noise.
- **The seek-bar warning above came true, exactly as written.** With the loop gone, the
  honest clock arrives far less often: `../echo-fix.log` has one stretch of **88 seconds**
  where the position anchor was never refreshed, and when the correction finally landed it
  moved 581 ms (local extrapolation 88 730 ms, server 89 311 ms). That gap is not a
  regression from this fix — it is the same two-clock disagreement, now free-running for
  longer between corrections instead of being papered over by a request storm. It is the
  reason a calm log must not be read as proof the seek bar is correct.
- **The one way the narrow fix could bite.** If Spotify ever changes *our* device entry
  server-side without routing a command to us, the filter swallows it and we do not re-PUT.
  Not seen in 449 cluster updates, and the separate-channels argument in Task 2 says remote
  commands do not arrive that way — but it is the residual, and it is what T9 is watching for.
