# Unavailable tracks: find out why, and stop draining the queue silently

Ticket: [`unavailable-tracks-skip-the-rest-of-a-playlist.md`](unavailable-tracks-skip-the-rest-of-a-playlist.md)
Status: **not started.** Branch `plan/unavailable-tracks`.
Priority: **1 of 5.** Playback stops working mid-playlist and the UI says nothing.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Establish why a playlist skipped through every track after the first, fix it if it
is ours to fix, and — regardless of the answer — stop an unplayable track from presenting as
playback that quietly stopped.

**This plan is deliberately split in two.** Phase A is a measurement that decides what Phase B
is. Do not skip A: three different causes fit the log equally well, and two of them make the
obvious fix wrong. Phase C is worth doing whatever A finds, and can proceed in parallel.

## What is known

From `../seek-after.log`, 2026-08-14: eight `is not available` and six `Track should be
available, but no alternatives found`, each track skipped in a fraction of a second, playback
effectively dead while the UI still showed playing. A later run on a different playlist had
two of the same warnings and played through fine — so this is neither every playlist nor every
unavailable track.

Both messages come from librespot's availability check, before loading. That matters, because
it rules *out* the other known path to the same outcome:

> **Not the same bug as [`librespot/upstream-transient-load-failure.md`](librespot/upstream-transient-load-failure.md).**
> That one turns a *network* error into `PlayerEvent::Unavailable` and permanently deletes the
> track. Same destructive outcome, different trigger — the logged messages there are
> `Unable to load audio item` and `marking … as unavailable`, neither of which appears in our
> run. Do not let the two merge into one theory. They should, however, be fixed by the same
> instinct: a track leaving the queue should require a reason worth trusting.

## Phase A — decide which of three stories is true

Three fit the log, and nothing so far separates them:

1. **We send ids the account's market resolved, librespot checks availability through its own
   session, and the two disagree.** Would make this ours, and identity-shaped.
2. **The tracks are genuinely unplayable in DE with no substitute.** Would make this a UI
   problem only — the app's job is to say so.
3. **The market librespot checks against is not the one the ids were resolved under.** Ours,
   but configuration-shaped rather than identity-shaped.

- [ ] **A1. Ask spclient about the three known-failing ids**, both with `market=from_token`
      and without: `4kVIImqwUPakCujdyQ3YP2`, `4771ccpHnvLwaEacV0dh9E`, `2X7Bo34Z1c375Jo6JQaVnL`.
      Record for each whether it comes back playable, substituted, or neither. This single step
      separates "genuinely unavailable" from "we sent the wrong id".
      **Use the web client's DevTools rather than `libspot-probe`** — the probe shares the
      app's grant and running it revokes Spotifly's refresh token.
- [ ] **A2. Read the session country librespot logged** (`librespot_core::session`, `DE` in the
      failing run) and compare it against the market the ids were resolved under. If these
      differ, story 3 is live and the rest of A is moot.
- [ ] **A3. Capture a fresh reproduction with the queue's ids logged.** The existing log records
      only the ids that *failed*, not what the queue held, so it cannot show whether the id we
      sent is the id we resolved. Add a temporary debug line where the queue is handed to
      librespot (`rust/src/lib.rs`) and reproduce with the same playlist.
- [ ] **A4. Write the answer into the ticket** and pick the Phase B branch below. If A says
      story 2, Phase B is empty and Phase C is the whole fix — record that plainly rather than
      inventing work.

**Success criterion for A:** one sentence naming which story is true, with the evidence
attached. Not a fix.

## Phase B — fix it, if it is ours

Only one of these runs, chosen by A.

- [ ] **B-story-1 (identity).** The ids reaching librespot disagree with what its session can
      play. `CLAUDE.md`'s rule is that the app keys on the id the API returned and never
      rewrites it — so the fix is *not* to start rewriting ids. It is to find where the id
      handed to librespot stops being the one the API returned, which is a bug against the rule
      rather than a reason to change it.
- [ ] **B-story-3 (market).** Align the market librespot checks against with the one the ids
      were resolved under. Likely a session configuration passed from `rust/src/lib.rs`.
- [ ] **B-story-2 (genuinely unavailable).** Nothing to fix here. Skip to C.

## Phase C — an unplayable track must be visible

**Do this regardless of what A finds.** From the ticket: *"Even if every one of those tracks is
genuinely unplayable, skipping silently through a whole playlist in half a second is the wrong
behaviour."* Today nothing in the UI says anything and the queue simply drains.

- [ ] **C1. Surface unavailability across the FFI.** librespot already knows; Spotifly does not.
      An entry point in the shape of the existing callbacks carries "this track id was skipped
      as unavailable" up to Swift. Keep it to one signal — this is not the place for a general
      player-event bus.
- [ ] **C2. Mark the track in the store**, so the queue and track lists can render it. A single
      field on the entity, set by the callback; no new state machine.
- [ ] **C3. Render it.** Greyed row with an explanatory label, in the queue and in track lists.
      New localization keys go in all three of `de`, `en` and `fr` — note that
      `speakers.airplay_disabled_hint` is currently missing from `de`, so check rather than
      assume the three are in sync.
- [ ] **C4. Do not let a cascade look like playback.** If every remaining track is skipped, the
      app should stop and say so rather than sit on a playing UI with a drained queue. Decide
      the wording with the owner; the failure to avoid is the current one, where nothing at all
      happens.

## Verification

- [ ] `xcodebuild -scheme Spotifly -configuration Debug build` — BUILD SUCCEEDED
- [ ] `xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES` — TEST SUCCEEDED, no failures. Baseline is 294 on `main`
- [ ] `cargo check` in `rust/` if C1 lands; `cargo clippy` count compared against the branch
      baseline rather than expected to be zero
- [ ] `swiftformat --swiftversion 6.3 --lint .` run **bare**, exit code checked directly — not
      piped, which has swallowed a failure here before
- [ ] Replay the failing playlist from the ticket and confirm the new behaviour with a log

## Risks

- **The reproduction is not reliable.** One playlist failed, another did not. Budget for the
  possibility that A3 cannot reproduce on demand, and fall back to reasoning from A1's answer.
- **Phase C touches the FFI surface**, where `#[no_mangle] pub extern "C"` entry points are a
  contract with Swift: an added or renamed entry point means updating
  `rust/include/spotifly_rust.h` and every Swift call site together.
- **Scope creep into a player-event bus.** C1 wants one signal. The moment it grows a general
  event type, stop and re-scope.
