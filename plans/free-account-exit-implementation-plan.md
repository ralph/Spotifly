# Free accounts: stop librespot ending the process, and give the case a screen

Ticket: [`free-account-exits-the-process.md`](free-account-exits-the-process.md)
Status: **not started.** Branch `plan/free-account-exit`.
Priority: **2 of 5.** The app quits. Cheap to fix, catastrophic when hit, and invisible in
any bug report we would receive.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A non-premium account never terminates Spotifly. The app tells the user what is
wrong and offers a way out.

**Why this ranks second despite being unobserved.** The mechanism is not in doubt — it is
`std::process::exit(1)` read straight off the source, in a library linked into the app. What
is unobserved is only what the *user* sees: an immediate quit, a quit after the window draws,
or a hang. That uncertainty affects Task 4's wording, not whether the bug is real.

## The mechanism

`librespot/core/src/session.rs:364`, `check_catalogue`:

```rust
if account_type != "premium" {
    error!("librespot does not support {account_type:?} accounts.");
    // TODO: logout instead of exiting
    exit(1);
}
```

Three call sites, all live in this app:

| Call site | Reached by |
| --- | --- |
| `session.rs:847`, `ProductInfo` mercury handler | every connect — the accesspoint pushes it |
| `session.rs:612` `set_user_attributes` | `connect/src/spirc.rs:947` |
| `session.rs:600` `set_user_attribute` | `connect/src/spirc.rs:965` |

The first fires at sign-in. The other two mean a **mid-session** attribute push carrying
`type` can end the process while the user is doing something unrelated. Only a payload
containing the `type` key triggers it, which is why routine pushes are harmless.

`PremiumRequiredView` used to exist for this case and was deleted in `ff87034` because it
could never run — the process is gone before any screen draws. So the app has no story here,
not a bad one.

## Task 0 — the product question, first

**Settle this before writing code**, because it decides what Task 4 builds and it is not an
engineering call:

> Should Spotifly refuse a free account outright, or let it browse without playback?

Everything except streaming — library, search, playlists, driving *another* Connect device —
runs on the keymaster grant and has nothing to do with the product type. Streaming is
premium-only because Spotify makes it so. Both answers are defensible; the patch below is what
makes either one possible.

- [ ] **Task 0.** Get the answer from the owner. Record it in this file. Do not guess it from
      what is easiest to build.

## Task 1 — check upstream before patching anything

- [ ] **Task 1.** Look at whether `librespot-org/librespot` `dev` has replaced the `exit`
      since our checkout (`v0.8.0-16-g9c7d756`). The `TODO` says the maintainers already
      consider it wrong. If it is fixed upstream, **Task 2 becomes a checkout instead of a
      patch** — the workspace has no revision pin precisely so that is cheap.

      **It does not collapse Tasks 3 and 4.** An upstream fix stops the process dying; it
      cannot add Spotifly's FFI entry point, set any Swift state, or make Task 4's screen
      reachable. A free account would then get a live app that silently cannot play, which is
      a quieter failure than the quit but not an explained one. Tasks 3–5 are required
      wherever the librespot fix comes from.

## Task 2 — make the product type a value, not an exit

- [ ] **Task 2a.** Patch `check_catalogue` to return an error instead of calling `exit`. This
      is a local patch to the checked-out librespot; `rust/Cargo.toml` uses path dependencies
      with no pin, so it builds by checkout. Keep the change as small as the `TODO` implies —
      returning rather than exiting, with the call sites propagating.
- [ ] **Task 2b.** Confirm the three call sites behave sanely when it returns rather than
      exits, particularly the mid-session ones reached from Spirc. An error that unwinds into
      a panic is not an improvement over `exit(1)`.
- [ ] **Task 2c. Classify it as terminal, or the fix is worse than the bug.** A plain error
      here lands in the normal outage-recovery path and gets retried forever against a
      rejection that will never change. The ordering makes this certain rather than likely:
      `build_player_async` stores `SESSION` at `rust/src/lib.rs:2084` and starts
      `spawn_session_health_check` at `:2089`, **before** `create_and_store_spirc` at `:2091`,
      and a failed initialization only cleans up during teardown. So the health check is
      already running when the failure arrives.

      Turning `exit(1)` into an infinite reconnect loop trades a fast, legible death for a
      machine that spins, drains battery and hammers the accesspoint while showing nothing.
      A non-premium account must be a **terminal state**: suppress reconnection, tear the
      unusable session down, and keep the product type so Task 3 can still report it.

## Task 3 — surface it to Swift

- [ ] **Task 3.** The product type already rides on the session as
      `user_data().attributes["type"]` — alongside `country` and `canonical_username` — so this
      costs no request and no new endpoint. Add one FFI entry point in the same shape as the
      existing `spotifly_last_grant_account`, and update `rust/include/spotifly_rust.h` and the
      Swift call site **together**; the header and the Rust surface are one contract, and this
      repo has shipped header declarations with no implementation behind them before.
- [ ] **Task 3b. A getter alone cannot cover the mid-session case.** A value in the shape of
      `spotifly_last_grant_account` is only seen when Swift happens to read it, and this plan's
      own finding is that `set_user_attribute(s)` can deliver a non-premium `type` **while the
      user is doing something else**. Nothing in Swift observes those Rust attributes changing,
      so the screen would simply never appear on that path — the one that is hardest to
      reproduce and easiest to believe fixed.

      Either add a callback in the shape of the existing ones, or route the terminal state
      through an observable the app already watches and re-read the getter on that event. Note
      that a dead callback chain has shipped here before: `queue_changed` was registered and
      never fired, so wire it and then prove it fires.

## Task 4 — the screen `ff87034` deleted

- [ ] **Task 4.** Build it back, to whatever Task 0 decided. Write it only once something can
      actually reach it — that is why it was deleted, and re-adding it before Task 3 lands
      would repeat the mistake exactly.
- [ ] **Task 4b.** Localization keys in all three of `de`, `en` and `fr`. Check rather than
      assume the three are in sync: `speakers.airplay_disabled_hint` is currently missing
      from `de`.

## Task 5 — upstream it

- [ ] **Task 5.** Offer the Task 2a patch to `librespot-org/librespot`. The `TODO` invites this
      change, and returning an error instead of ending the host process is useful to every
      embedder, not just this one. File alongside the two drafts already waiting in
      [`librespot/`](librespot/) — and consider whether filing those two at the same time is
      worth the round trip.
- [ ] **Task 5b. Make the patch reproducible before calling this done.** The no-pin path
      dependency is a convenience for *trying* a librespot change; it is not a way to ship one.
      Until the patch is upstream, a clean checkout or a release machine resolves
      `../../librespot` to whatever is sitting there — which may still be the revision that
      calls `exit(1)`. The bug would then be fixed on one machine and shipped broken from
      another, with nothing in this repo recording the difference.

      So this work is not complete at a locally-patched sibling directory. It needs an upstream
      merge plus a documented known-good commit, or the change carried somewhere versioned — a
      fork, a submodule, or a patch file applied by `rust/build.sh`. Pick one and write it
      down; the release process has to be able to reproduce the fix without oral history.

## Verification

The hard part: **nobody here has a free Spotify account**, which is why this was never
reproduced.

- [ ] **Run librespot's own checks in `../../librespot`, not just ours.** Task 2a patches
      `librespot/core/src/session.rs`, but `rust/` is a single-package workspace whose only
      member is `spotifly-rust`: path dependencies are *compiled* there, while librespot's unit
      tests, formatting and lints never run. Verified — `cargo test --no-run` in `rust/` builds
      one test binary, `spotifly_rust`. The patched package needs `cargo test -p librespot-core`,
      `cargo fmt --check` and `cargo clippy` **from the librespot checkout**. This matters twice
      over for Task 5: an upstream PR is judged by librespot's CI, not ours.
- [ ] `cargo check` and `cargo clippy` in `rust/`, clippy compared against the branch baseline
      rather than expected to be zero
- [ ] `xcodebuild … build` — BUILD SUCCEEDED
- [ ] `xcodebuild … test -only-testing:SpotiflyTests` — TEST SUCCEEDED, no failures (294 on `main`)
- [ ] `swiftformat --swiftversion 6.3 --lint .` bare, exit code checked directly
- [ ] **Prove the path without a free account — and inject the value, not just the branch.**
      Force `check_catalogue` down the non-premium path in a local build and confirm the app
      shows Task 4's screen instead of vanishing. This is the only verification step that
      actually tests the thing, and it needs no account.

      **Hardcoding the comparison alone is not enough.** On a premium test account that runs
      the new error branch while `user_data().attributes["type"]` still reads `premium` — and
      that attribute is exactly what Task 3 exposes and Task 4 reads to choose the screen. So
      the test would exercise the error path and *not* the UI path, and would look like a pass.
      Inject a non-premium attribute value, or add a seam that changes the classification and
      the surfaced value together.
- [ ] **Confirm it does not retry.** With the forced non-premium path, watch for the
      reconnection loop Task 2c exists to prevent: no repeated session rebuilds, no health
      check hammering the accesspoint. A quiet log here is the point.
- [ ] If a free account can be borrowed, run the real case and record what the user sees, which
      is the one detail the ticket admits is inferred.

## Risks

- **Patching librespot cuts against the workspace's stance** that official librespot is used
  with no fork or patch required. That stance is why Task 1 comes first and Task 5 exists: a
  local patch is acceptable as a way station to upstreaming, not as a destination.
- **`exit(1)` may not be the only one.** Check for other `exit` calls on paths this app
  reaches while in there; one fixed exit and one remaining is a worse place to be than today,
  because it looks fixed.
- **Task 4 is not a placeholder.** A screen that says "premium required" and offers no logout
  leaves the user as stuck as the quit did, just slower.
