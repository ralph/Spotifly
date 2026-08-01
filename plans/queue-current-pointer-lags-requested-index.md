# SetQueue reports the pre-seek position, so the queue's current pointer lags

Status: **planned — one measurement outstanding before it is worth building**
Components: `Spotifly/Store/Services/QueueService.swift`, `Spotifly/Store/AppStore.swift`,
possibly `librespot` upstream
Found: 2026-07-31, noted while fixing relinked-track identity; re-confirmed 2026-08-01

## Symptom

Start an album at any track other than the first. Playback is correct, the Now Playing bar
is correct, but the queue believes the *first* track is current.

Concretely, with track 2 of 18 playing:

- track 1 is not dimmed as already-played, because `isPlayedTrack` is `index < currentIndex`
  and `currentIndex` is `previousTracks.count`, which is 0;
- the header counts 17 unplayed instead of 16;
- `scrollToCurrentTrack` scrolls to row 0 rather than to what is playing.

## What is *not* affected

Worth stating, because it bounds this to presentation:

- **The Now Playing bar.** It resolves `PlaybackViewModel.currentTrackUri`, which comes from
  the bridge's `Loading`/`Playing` events — see
  `plans/relinked-track-now-playing-identity.md`. It never reads the queue pointer.
- **The row highlight.** `TrackRow.isCurrentTrack` compares `currentlyPlayingURI` against the
  track's uri, so the right row is marked playing even while the pointer disagrees.
- **Double-clicking a queue row.** `allQueueItems` is `previous + current + next`, and the
  *ordering* is intact — only the split between them is wrong. Index 0 is still album track
  1, so the row that is clicked is the track that plays.

Nothing plays the wrong audio and nothing writes bad data. This is a display defect.

## Evidence

`verify.log`, 2026-08-01, double-clicking track 2:

```text
08:02:05.951 state::tracks] set track to: …0kIoSy4F… at 0 of 18 tracks
08:02:05.951 spirc]        play track <Some(Index(1))>
08:02:05.951 player]       command=EmitSetQueueEvent(…, 17, 0)      ← emitted here
08:02:05.951 state::tracks] set track to: …3CCyVdpr… at 1 of 18 tracks
08:02:05.951 state]        has 1 prev tracks                        ← no second emit
08:02:05.965 QueueService] Set queue: … prev=0, current=1, next=17
```

librespot resets the context to index 0, emits `SetQueue` from that state, and *then*
applies the requested index. The Swift callback therefore receives `current_track` =
track 1 and `next_tracks` starting at track 2. Nothing emits again, and no later callback in
that run corrects it.

The offset is not always one: it equals the requested index, so starting an album at track
12 leaves the pointer eleven places behind.

## The measurement that decides whether to build this

**Does the pointer self-correct at the next track transition?**

Every captured log so far covers a single context start. If librespot emits `SetQueue` on
auto-advance and on `next`, and those emissions carry the applied index, then this is wrong
only until the current track ends — a bounded blip on one track, on a display detail. That
is comfortably below the bar for new reconciliation logic in the queue path, and the right
outcome is to document it and close this plan.

If instead the pointer stays stale for the whole session, or drifts further with each
transition, it is worth the fix in section 1.

Capture before implementing:

```bash
RUST_LOG=librespot=debug,spotifly_rust=debug <app-binary> 2>&1 | tee queue-index.log
```

1. Double-click track 5 of an album.
2. Let it advance to track 6 on its own.
3. Press next twice.
4. Press previous once.

Then check, for each transition, whether a `SetQueue` was emitted and whether its
`prev`/`current` agree with the track that is actually playing:

```bash
grep -E "EmitSetQueueEvent|play track|set track to|has [0-9]+ prev|Set queue:" queue-index.log
```

## Design, if the measurement says it is worth it

### 1. Re-derive the split from the authoritative URI

The queue's current pointer is redundant information. The app already knows what is playing —
`PlaybackViewModel.currentTrackUri`, fed by the bridge and trusted everywhere else. What
`SetQueue` uniquely provides is the *ordering*.

So do not trust the reported split. Take the full ordered list, find the playing track in
it, and split there. Whatever index librespot had reached when it emitted, the result is
the same.

Two things this has to get right, and they are the reason this is a plan and not a patch:

- **Ordering between the two inputs.** `SetQueue` and the loading notification arrive as
  independent `Task { @MainActor }` hops from separate C callbacks, so at `SetQueue` time
  `currentTrackUri` may still name the *previous* track. Reconciliation therefore has to run
  from both sides: when a queue arrives, and when the logical URI changes. One function,
  two callers.
- **Duplicates.** A context may contain the same track twice, so "find the playing track"
  is ambiguous. Search *forward from the reported position* and take the first match, which
  matches the failure being corrected — librespot is always behind, never ahead. If there is
  no match at or after the reported position, leave the queue exactly as it came; a pointer
  that is one place off is better than one that jumped somewhere unrelated.

### 2. Rejected: refresh the queue from the Web API

`QueueService.scheduleQueueRefresh()` already exists and would paper over this. It costs a
network round trip and an ~800 ms delay to correct a dimming state, and the Web API queue
lags live state — the freshness barrier in `fetchInitialPlaybackState` exists precisely
because of that. Wrong tool for a display detail.

### 3. Rejected as the primary fix: patch librespot

The root cause is upstream: `SetQueue` is emitted between the context reset and the index
application. Emitting after the index is applied — or emitting again — would fix it for
every consumer.

But Spotifly deliberately builds against **official** librespot with no revision pin, and
`AGENTS.md` records that as a property worth keeping. Carrying a local patch to correct a
dimming state trades that away.

Worth filing upstream on its own merits, as
`plans/librespot/upstream-pr-play-status-is-playing.md` and
`plans/librespot/upstream-transient-load-failure.md` were. Note in the draft that a consumer
cannot distinguish "context reset" from "user selected track 1", which is what makes the
current emission point lossy. Spotifly should not wait for it.

## Verification

### Automated

The reconciliation is a pure function over a list, a reported split, and a URI, so it can be
tested directly — this is unlike the two preceding queue bugs, whose triggers lived in
SwiftUI and the C callback boundary.

1. Reported split already correct → unchanged.
2. Reported split behind by one → moves forward by one.
3. Reported split behind by eleven → moves forward by eleven.
4. Playing URI absent from the list → unchanged.
5. Playing URI appears twice, once before and once after the reported position → the match
   at or after it wins.
6. Playing URI is the last entry → all others become previous, next is empty.

Then the usual gates; two `NavigationCoordinator` assertions fail on this branch and are a
known baseline.

### Runtime

Re-run the capture above and confirm, at every transition: track 1 dims once it has played,
the header's unplayed count matches what is left, and scrolling to current lands on the
playing row. The relinked-identity checklist stays the regression suite for the bar itself.

## Acceptance criteria

- The queue's current pointer names the track that is playing, at a context start with any
  index and after every transition.
- Already-played tracks dim; the unplayed count matches; scroll-to-current lands correctly.
- A queue whose playing track is not in the list is left alone rather than rearranged.
- No Web API request is issued to correct the pointer.
- Spotifly still builds against unpatched official librespot.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Out of scope

Shuffle and externally-controlled playback change the queue through the same callback, so
they are covered by the same reconciliation, but neither is a target of this plan and
neither should gain special handling here.
