# A real playhead: report the position you can hear

Ticket: [`the-reported-position-is-the-decoder-not-the-playhead.md`](the-reported-position-is-the-decoder-not-the-playhead.md)
Status: **not started.** Branch `plan/playhead-position`.
Priority: **3 of 5.** Every position the app reports is ~2 s ahead of the audio.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** A position that means *the sample leaving the speaker now*, and four consumers moved
onto it.

## Read this before starting

**The ticket argues against doing this now, and it is right.** Its closing judgment:

> The error is ~2 s on a track of a few minutes, it is consistent rather than jumpy, and the
> one place it was *visible* is fixed. Against that, it touches the audio pipeline, which is
> the part of this app where a mistake is audible rather than cosmetic. The honest reading is
> that this is worth doing when something else already requires touching the renderer's
> lifecycle, and hard to justify on its own.

So this plan is staged deliberately, and **Stage 1 is the recommended stopping point** unless
something else brings you into the renderer anyway. Stage 2 is the real fix and is written
down so that it is ready when that day comes — not as an invitation to start today.

Do not treat "the plan exists" as "the plan should be executed". The decision to go past
Stage 1 belongs to the owner.

## Why the obvious fix does not work

Subtracting the renderer's in-flight audio inside `SpotifyPlayer.positionMs` was the first
plan for the seek-bar bug and was **rejected under review**. Do not re-propose it:

- **Seek does not flush.** `handle_command_seek` moves the decoder and leaves the sink alone
  (`playback/src/player.rs:2234`). After a seek the decoder is at the target while the buffer
  still holds pre-seek audio, so subtracting the buffer duration puts the bar ~2 s *behind*
  where the user dropped it.
- **`stop()` does not empty the pipeline** (`AudioRenderer.swift:377`) — it freezes the
  synchroniser and leaves the ring and `currentPTS` intact.
- **The pause path stops the renderer before the position is reported** (`ProxySink: Stop` at
  `29.445`, `Paused … 25013ms` at `29.478`), so a correction applied then has nothing to
  subtract.
- **It would miss three of the four symptoms anyway**, since resume, the local playback state
  and the freeze all bypass that getter.

## Stage 1 — the cheap partial fix (recommended)

Fixes one row of the table: pausing steps the bar forward ~2 s, then back. This is the symptom
most likely to be noticed, and Stage 1 does not touch the renderer's lifecycle.

- [ ] **S1a.** Carry a last-known audible position across `ProxySink::Stop`, so
      `PlayerEvent::Paused` can report it instead of the decoder's. The gap is small and
      measured: `25013` from the player event against `23016` from Connect, for a configured
      2.0 s of buffer.
- [ ] **S1b.** Confirm against a log that the pause step is gone and that nothing else moved —
      in particular that resume still seeks where it did.
- [ ] **S1c.** Stop here and reassess. Record in the ticket that one row of four is fixed and
      three remain, so the next reader is not misled into thinking the position is now honest.

## Stage 2 — an actual playhead

**Only start this when something else already requires touching the renderer's lifecycle.**

The renderer already has half of it: `AVSampleBufferRenderSynchronizer.currentTime()` is
played-out time and `currentPTS` is how much has been enqueued, so audio in flight is
computable at any instant. The missing half is *which track position a given renderer time
corresponds to* — `Sink::write` carries samples and nothing else, so the mapping must be built
alongside the stream rather than derived from it.

- [ ] **S2a. An epoch type**: renderer time ↔ track position, owned by `AudioRenderer`.
- [ ] **S2b. Rebase it at every point the correspondence breaks**: seek, flush, pause/resume,
      route change (which recreates the renderer entirely, `AudioRenderer.swift:463`), and
      track transition.
- [ ] **S2c. Track transition is the hard one**, and observing the events is not enough to
      solve it. The boundary is exactly where two tracks' audio coexist in the buffer, which is
      the case this whole plan is about. librespot starts the next track's clock when the
      decoder switches — the same millisecond as the previous track's `EndOfTrack`, with ~2 s
      of that track still queued.

      **Do not rebase the epoch when `EndOfTrack`/`Playing` is observed.** Doing so switches to
      track n+1 while two seconds of track n are still waiting to be heard, so the playhead
      reports a position for the wrong track around *every* boundary — replacing a uniform 2 s
      error with a wrong-track error, which is worse. The events are also delivered
      asynchronously from `ProxySink::write`, so new-track samples may already be written by
      the time the event is observed; observation order is not sample order.

      The boundary has to travel **with the PCM**: send an ordered boundary marker or sample
      offset alongside the samples, keep *both* track epochs (URI and position) alive, and
      switch only when `currentTime()` actually crosses the boundary.
- [ ] **S2d. Move the four consumers over**, none of which go through the Swift getter today:

      | Consumer | Today |
      |---|---|
      | `send_local_playback_state` | `rust/src/lib.rs:2346` |
      | **`send_playback_state`, the cluster path** | `rust/src/lib.rs:2287`, forwarding `position_as_of_timestamp` at `:2320` |
      | resume rehydration | `rust/src/lib.rs:1998`, `:2753` |
      | `freezePositionForDisconnect` | `PlaybackViewModel.swift:1084` |
      | `checkDriftAndSync` | via `SpotifyPlayer.positionMs` |

      **The cluster path is the one the ticket's table missed, and it would have undone the
      work.** `send_playback_state` is a separate function from `send_local_playback_state`:
      when the local device is active and a Mercury cluster update arrives, `apply_cluster`
      (`:1325`) routes through it, forwarding a value that stays decoder-anchored across
      gapless transitions — and Swift reanchors on every callback. Move only the original four
      and the very next self-echo restores the ~2 s lead, after either stage. That would look
      like the fix silently not working.

- [ ] **S2e. Re-check the seek-bar fix still holds.** `seek-bar-jumps-between-two-position-clocks.md`
      was fixed by treating the decoder position as an *upper bound* rather than a rival
      measurement. A real playhead changes that relationship, so its drift check and its
      command-scoped abandoned-command detection both need re-reasoning, not just re-running.

## Verification

The hardware timing needs a runtime check, but **"timing bugs do not show up in unit tests" is
too broad an excuse and does not apply to most of this.** The epoch conversion, the rebasing
rules and the boundary arithmetic are deterministic core logic: given a synthetic renderer time
and a sample offset, the answer is fixed. `AGENTS-twostraws.md` asks for unit tests on core
application logic, and seek, route-change and gapless math are exactly that.

- [ ] **Unit-test the epoch math directly**, with synthetic renderer times and sample offsets:
      conversion, rebase-on-seek, rebase-on-route-change, and the two-epoch gapless boundary
      from S2c — including the case where the boundary marker arrives before `currentTime()`
      reaches it, which is the whole point of keeping both epochs. These run in
      `SpotiflyTests` and cost nothing per run.

- [ ] `cargo check`, `cargo test`, `cargo fmt --check` in `rust/`
- [ ] `xcodebuild … build` — BUILD SUCCEEDED
- [ ] `xcodebuild … test -only-testing:SpotiflyTests` — TEST SUCCEEDED (294 on `main`)
- [ ] `swiftformat --swiftversion 6.3 --lint .` bare, exit code checked directly
- [ ] **Listen to it.** Play a context past its first track and check the bar against the
      audio; scrub backwards and forwards; pause and resume; deactivate and resume.
- [ ] **Compare snapshot chains in a log**, the method that confirmed the seek-bar fix: dense
      runs of Connect snapshots should chain exactly, with no `Drift correction:` lines except
      where a command moved the position.
- [ ] Re-run the three scenarios from `seek-after.log`, `seek-after2.log` and `seek-after3.log`.

## Risks

- **This is the part of the app where a mistake is audible.** A wrong epoch is a stutter or a
  jump, not a cosmetic error.
- **Gapless is where it will break.** Two tracks' audio in the buffer at once is the whole
  difficulty; anything that works only for a context's first track has not been tested.
- **Route changes recreate the renderer.** Any epoch must not survive that silently.
- **Stage 2 can regress a fix that is confirmed working.** The seek-bar fix has three logs
  behind it; do not spend that lightly.
