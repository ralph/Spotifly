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

- [ ] **A1. Ask a source that actually reports availability and alternatives**, for the three
      known-failing ids: `4kVIImqwUPakCujdyQ3YP2`, `4771ccpHnvLwaEacV0dh9E`,
      `2X7Bo34Z1c375Jo6JQaVnL`. Record for each whether it is restricted in the session's
      country and whether an alternative exists.

      **Not spclient, and not `market=from_token`.** The ticket proposed that and it cannot
      decide anything: `CLAUDE.md` records that **spclient is id-faithful — it returns whatever
      id you ask for** and exposes no relationship to a market substitute. So the query comes
      back with the track you named whether or not a substitute exists, and toggling `market`
      changes nothing about that. It cannot produce a "substituted" answer, which means it
      cannot distinguish story 1 from story 2 — the entire point of Phase A.

      Use something that names restrictions and alternatives explicitly: librespot's own track
      metadata carries both (they are what its availability check reads, and the source of the
      `no alternatives found` message), and the extended-metadata endpoint on spclient is the
      other candidate. Confirm the chosen source reports the `country`/restriction pair before
      trusting a negative result.

      **If using `libspot-probe`, note it shares the app's grant** and running it revokes
      Spotifly's refresh token; prefer the web client's DevTools where it can answer.
- [ ] **A2. Read the session country librespot logged** (`librespot_core::session`, `DE` in the
      failing run) and compare it against the market the ids were resolved under. If these
      differ, story 3 is live and the rest of A is moot.
- [ ] **A3. Capture a fresh reproduction with the ids logged on the Swift side.** The existing
      log records only the ids that *failed*, not what the queue held, so it cannot show
      whether the id we sent is the id we resolved.

      **Do not instrument the FFI handoff — there are no track ids there.** Starting a playlist
      passes only the *context* uri: `spotifly_play_uri` (`rust/src/lib.rs:2592`) builds
      `LoadRequest::from_context_uri` (`:2645`) and librespot resolves the individual tracks
      itself. A debug line at that point would print one playlist uri and prove nothing.

      Log the track ids **the store holds** when playback starts, then compare them against the
      Connect queue librespot resolves. If those two sets differ, story 1 is live and the
      difference names the bug. If they match and tracks still fail, the id we sent is the id
      the API gave us and the cause is elsewhere.
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

- [ ] **C1. Surface unavailability across the FFI — but not by forwarding
      `PlayerEvent::Unavailable`.** That event is not the signal it appears to be. This repo's
      own [upstream analysis](librespot/upstream-transient-load-failure.md) records that it
      collapses genuine restrictions and *transport failures* into one value, so a twenty-second
      network blip would arrive as "unavailable". Forwarding it verbatim and then writing it
      into the store means a brief outage permanently labels a perfectly playable track as
      unplayable — a worse bug than the one being fixed, and a stickier one.

      So C1 must carry a reason that means *genuine* unavailability, which requires either
      narrowing librespot's event semantics first (the same change the upstream draft proposes)
      or deriving the reason from the availability check rather than the load failure. Keep it
      to one signal; this is not the place for a general player-event bus.
- [ ] **C2. A field on `Track` is not enough, because the row will not exist.** librespot does
      not flag an unavailable track, it **deletes** it: `mark_unavailable`
      (`librespot/connect/src/state/tracks.rs:384`) loops `next_tracks.remove(pos)` and does the
      same for `prev_tracks`. `QueueService.handleQueueUpdate` then replaces the store's queue
      with that already-shortened snapshot, and `QueueListView` renders only what the queue
      references. The entity stays cached and has nowhere to appear.

      This needs an ordered **tombstone** — the queue retaining the skipped entry in place,
      marked — or an upstream change that stops `mark_unavailable` removing entries. Decide
      which before building C3; a store field alone renders nothing.
- [ ] **C3. Render it**, once C2 gives it a place to live: greyed row with an explanatory
      label, in the queue and in track lists. New localization keys go in all three of `de`,
      `en` and `fr` — note that `speakers.airplay_disabled_hint` is currently missing from
      `de`, so check rather than assume the three are in sync.
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
- **Phase C may need an upstream change to be possible at all.** Both C1 and C2 run into the
  same wall from different sides: librespot conflates the reasons and then deletes the
  evidence. If the tombstone route is rejected, C2 becomes an upstream patch, and Phase C
  inherits the reproducibility question that patching an unpinned sibling checkout always
  carries — it must end upstream or somewhere versioned, not in a local working copy.
- **A fix that makes transient failures sticky.** The single worst outcome here is turning a
  network blip into a permanent "unavailable" label on a playable track. C1 exists to prevent
  exactly that; treat any design that cannot distinguish the two as not ready.
