# Break the connect-state echo loop

Ticket: [`connect-state-put-echoes-itself-into-a-429.md`](connect-state-put-echoes-itself-into-a-429.md)
Status: **Task 1 done, Task 2 not started.** Branch `plan/connect-state-echo`.
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

## Task 2 — the narrow change

Skip `update_state = true` when the **only** changed device is ours. This leaves the workaround
intact for the case it was written for — another device sending an update — and removes only
our own echo.

- [ ] **T4.** Implement in the checked-out librespot. `rust/Cargo.toml` uses path dependencies
      with no revision pin precisely so a local librespot patch is a checkout and a rebuild.
- [ ] **T5.** Keep it narrow. The tempting larger change is to delete the workaround branch
      entirely; the upstream comment is evidence against that, and a de-sync it was hiding
      would be a worse bug than the one being fixed.

**Why the filter cannot swallow a remote command.** Cluster updates and connect-state requests
arrive on **separate select arms** — `spirc.rs:486` and `spirc.rs:493`. A remote transfer,
play, pause or seek is handled by `handle_connect_state_request`, which sets
`update_state = true` at `spirc.rs:1163` on its own; volume has its own arm again. So nothing
another client *asks* of us travels through `handle_cluster_update`, and suppressing our own
echo there cannot drop a response we owed. Note also that in the branch being changed the
cluster's `active_device_id` is already known to be ours — `became_inactive` above it took the
other case — so "the only changed device is ours" is a check against `self.session.device_id()`
and not merely against the active device.

## Task 3 — verify by counting

- [ ] **T6.** Reproduce the original scenario — a context start, the one that produced 80+ PUTs
      — and count PUTs in the log. Success is a small number, not zero: legitimate state changes
      still PUT (track change at `spirc.rs:758`, player events at `:884`, remote requests at
      `:1163`). **Compare PUTs per minute inside a burst window, not raw totals** — the 79 and
      83 in the pre-fix logs are rate-limited floors, so a raw total is not a like-for-like
      baseline.
- [ ] **T7.** Confirm no 429s across a session that previously produced them.
- [ ] **T8. Check the case the workaround exists for.** Have a *second* device send a
      connect-state update while Spotifly is active, and confirm the position does not de-sync.
      This is the regression that matters and the one that is easy to skip, since it needs a
      second device.
- [ ] **T9.** Confirm Spotifly still appears correctly to other clients — the 429s were landing
      on the request that advertises this Mac.

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
- [ ] `cargo check`, `cargo test`, `cargo fmt --check` in `rust/`; `cargo clippy` compared to
      the branch baseline rather than expected to be zero
- [ ] `xcodebuild … build` — BUILD SUCCEEDED
- [ ] `xcodebuild … test -only-testing:SpotiflyTests` — TEST SUCCEEDED (294 on `main`)
- [ ] The PUT count from T6, the 429 check from T7, and the second-device regression from T8

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
- **The one way the narrow fix could bite.** If Spotify ever changes *our* device entry
  server-side without routing a command to us, the filter swallows it and we do not re-PUT.
  Not seen in 449 cluster updates, and the separate-channels argument in Task 2 says remote
  commands do not arrive that way — but it is the residual, and it is what T9 is watching for.
