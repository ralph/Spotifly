# Break the connect-state echo loop

Ticket: [`connect-state-put-echoes-itself-into-a-429.md`](connect-state-put-echoes-itself-into-a-429.md)
Status: **not started.** Branch `plan/connect-state-echo`.
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

That schedules another `notify()`, which PUTs, which echoes. The period is the round trip,
~400 ms. In `../seek-after3.log`: 84 PUTs and three 429s. In `../seek.log`: 80 PUTs and no 429
at all — so being rate-limited is one way the burst ends, not the only one.

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

## Task 1 — confirm the premise before writing anything

The whole approach rests on one unverified assumption: **that the echoed update carries only
our own device id.** If echoes arrive carrying several changed devices, the filter below does
not work and the design has to change.

- [ ] **T1.** Log `ClusterUpdate.devices_that_changed` on every cluster update, alongside
      `self.session.device_id()`, and capture one context start. One run answers it.
- [ ] **T2.** From that log, confirm the loop's shape: PUT → cluster update naming only us →
      `update_state = true` → PUT. Count the round-trip period and check it matches the ~400 ms
      observed.
- [ ] **T3. If the premise is false, stop and re-plan.** Record what the updates actually
      carry. Do not proceed to Task 2 with a filter that cannot distinguish the cases.

## Task 2 — the narrow change

Skip `update_state = true` when the **only** changed device is ours. This leaves the workaround
intact for the case it was written for — another device sending an update — and removes only
our own echo.

- [ ] **T4.** Implement in the checked-out librespot. `rust/Cargo.toml` uses path dependencies
      with no revision pin precisely so a local librespot patch is a checkout and a rebuild.
- [ ] **T5.** Keep it narrow. The tempting larger change is to delete the workaround branch
      entirely; the upstream comment is evidence against that, and a de-sync it was hiding
      would be a worse bug than the one being fixed.

## Task 3 — verify by counting

- [ ] **T6.** Reproduce the original scenario — a context start, the one that produced 80+ PUTs
      — and count PUTs in the log. Success is a small number, not zero: legitimate state changes
      still PUT.
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
      `spotifly_rust`. So the patched package needs `cargo test -p librespot-connect`,
      `cargo fmt --check` and `cargo clippy` **from the librespot checkout**, or this
      checklist can pass green while the package we changed fails its own validation. That
      also matters for Task 4: an upstream PR is judged by librespot's CI, not ours.
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
