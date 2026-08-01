# SetQueue reports the pre-seek position, so the queue's current pointer lags

Status: **implemented — runtime verification outstanding** (2026-08-01)
Components: `Spotifly/Store/Services/QueueService.swift`, `Spotifly/Store/AppStore.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`, `SpotiflyTests/QueueReconciliationTests.swift`
Found: 2026-07-31, noted while fixing relinked-track identity; re-confirmed 2026-08-01

## Implemented solution

- `Queue.reconciled(currentTrackId:)` preserves the flattened ordering and returns a new
  split at the matching track occurrence nearest the reported current index. It searches
  backward and forward, leaves absent tracks untouched, and is idempotent.
- `AppStore.reconcileQueueCurrentTrack(with:)` applies that value only when it differs,
  avoiding observation updates for an already-correct split.
- `PlaybackViewModel.currentTrackUri` reconciles on every logical URI change. QueueService
  also reconciles after `SetQueue`, Mercury queue, and Web API bootstrap responses, so the
  independent main-actor callback hops may arrive in either order.
- The store is reconciled when it is first attached to the shared playback view model too,
  covering a URI that arrived before the surviving `AppStore` was activated.
- Nine focused tests cover correct, forward, deep-forward, backward, absent, duplicate,
  last-entry, and idempotent cases. The focused suite and full Debug build pass.
- No network refresh or librespot patch was added; the official sibling checkout remains
  the build dependency. Shuffle ordering remains explicitly out of scope.

**Outstanding: the runtime check below has not been run.** The unit tests exercise
`reconciled(currentTrackId:)` directly, which is the algorithm — but not the wiring: that
the URI actually changes on every transition, that the two callbacks repair each other
whichever lands second, and above all that **previous** works. Previous is the one direction
no `SetQueue` covers and the one this design had to be corrected for; it is verifiable only
against a running player. Until that run, this is unit-tested rather than demonstrated.

## Symptom

Start an album at any track other than the first. Playback is correct, the Now Playing bar
is correct, but the queue believes the *first* track is current.

Concretely, with track 2 of 18 playing:

- **the Now Playing bar reads `1/18`.** `NowPlayingBarView.queuePosition` renders
  `store.currentIndex + 1`, and `currentIndex` is `previousTracks.count`, which is 0. This
  is the original screenshot symptom recorded in
  `plans/relinked-track-now-playing-identity.md`;
- track 1 is not dimmed as already-played, because `isPlayedTrack` is `index < currentIndex`;
- the queue header counts 17 unplayed instead of 16;
- `scrollToCurrentTrack` scrolls to row 0 rather than to what is playing.

## What is *not* affected

Worth stating, because it bounds this to presentation:

- **Now Playing metadata.** Title, artist, artwork and duration resolve
  `PlaybackViewModel.currentTrackUri`, which comes from the bridge's `Loading`/`Playing`
  events — see `plans/relinked-track-now-playing-identity.md`. Only the bar's *position
  indicator* reads the queue.
- **The row highlight.** `TrackRow.isCurrentTrack` compares `currentlyPlayingURI` against the
  track's uri, so the right row is marked playing even while the pointer disagrees.
- **Double-clicking a queue row.** `allQueueItems` is `previous + current + next`, and the
  *ordering* is intact — only the split between them is wrong. Index 0 is still album track
  1, so the row that is clicked is the track that plays.

Nothing plays the wrong audio and nothing writes bad data. This is a display defect — but a
permanent one on the main player surface, not a transient blip.

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

## It does not self-correct — it drifts

The obvious hope is that the next transition emits a corrected `SetQueue`. It does not.
`emit_set_queue_event()` has exactly five call sites in `connect/src/spirc.rs`:

| Caller | When |
| --- | --- |
| `handle_next_context` | a context finished resolving — the case above |
| `handle_user_attributes_mutation` (×2) | account attributes changed |
| `load_context_from_tracks` | a track-list context was loaded |
| `handle_repeat_track` | repeat-one toggled |

`handle_next`, `handle_prev` and `handle_shuffle` are **not** among them. No transition
emits a queue.

So the pointer does not lag by a fixed amount and recover — it is frozen where context
resolution left it while playback walks away from it. Start at track 5 and the bar reads
`1/18`; let it advance to track 6 and it still reads `1/18`, now five places behind, for as
long as the context lasts.

That settles the cost/benefit: this is a wrong number displayed permanently in the main
player UI, and it gets worse the longer the app is used. Worth fixing.

It also constrains the design. Reconciliation cannot be driven by `SetQueue` arriving,
because at a transition nothing arrives. The only signal that a transition happened is the
logical URI changing.

## Design

### 1. Re-derive the split from the authoritative URI

The queue's current pointer is redundant information. The app already knows what is
playing — `PlaybackViewModel.currentTrackUri`, fed by the bridge and trusted everywhere
else. What the queue callback uniquely provides is the *ordering*.

So do not trust the reported split. Keep the ordering, find the playing track in it, and
split there.

Three things this has to get right, and they are why this is a plan and not a patch:

- **The trigger is the URI, not the queue.** Since no transition emits a queue,
  reconciliation must run whenever the logical URI changes. It must *also* run when a queue
  does arrive, because the two are independent `Task { @MainActor }` hops from separate C
  callbacks and either can be second — at `SetQueue` time `currentTrackUri` may still name
  the previous track. One function, two callers, and it must be safe to run repeatedly.
- **Search in both directions.** Previous moves playback *backwards* through a queue whose
  split has already been reconciled forwards, and emits nothing. A forward-only search would
  never find the track again and would leave the pointer stuck ahead of playback — worse
  than the bug being fixed, because it would now be wrong in a direction the user caused.
- **Duplicates.** A context may hold the same track twice, so the match is ambiguous. Take
  the occurrence **nearest the current split**, in either direction. That is the minimal
  interpretation of what happened, it degrades gracefully when the guess is wrong (one
  duplicate off, not a jump across the context), and it makes the rule directional-agnostic.
  If the URI is absent from the list entirely, leave the queue exactly as it came.

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
`plans/librespot/upstream-transient-load-failure.md` were. The report is stronger than the
symptom here suggests: it is not only that `handle_next_context` emits before applying the
index, but that `handle_next`, `handle_prev` and `handle_shuffle` emit nothing at all, so a
consumer of `emit_set_queue_events` has no way to track the queue after the first
resolution. Spotifly should not wait for it.

## Verification

### Automated

The reconciliation is a pure function over a list, a reported split, and a URI, so it can be
tested directly — this is unlike the two preceding queue bugs, whose triggers lived in
SwiftUI and the C callback boundary.

1. Reported split already correct → unchanged.
2. Split behind by one → moves forward by one.
3. Split behind by eleven → moves forward by eleven, the case of starting an album deep in.
4. Split *ahead* of the URI → moves backward, the case of pressing previous.
5. Playing URI absent from the list → unchanged.
6. URI appears twice, nearer occurrence behind the split → moves backward to it.
7. URI appears twice, nearer occurrence ahead of the split → moves forward to it.
8. URI is the last entry → everything else becomes previous, next is empty.
9. Running it twice in a row changes nothing the second time.

Then the usual gates; two `NavigationCoordinator` assertions fail on this branch and are a
known baseline.

### Runtime

Start an album at track 5, let it advance on its own, press next twice, then previous once.
At every step:

- the bar's position indicator names the track that is playing — `5/18`, then `6/18`, and
  back down again on previous;
- played tracks are dimmed and unplayed ones are not;
- the header's unplayed count matches what is left;
- scroll-to-current lands on the playing row.

Previous is the step that matters most: it is the one direction no emission covers, and the
one a forward-only reconciler would get wrong.

The relinked-identity checklist stays the regression suite for the bar's metadata.

## Acceptance criteria

- The queue's current pointer names the track that is playing, at a context start with any
  index and after every transition.
- Already-played tracks dim; the unplayed count matches; scroll-to-current lands correctly.
- A queue whose playing track is not in the list is left alone rather than rearranged.
- No Web API request is issued to correct the pointer.
- Spotifly still builds against unpatched official librespot.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Out of scope: shuffle is a different, larger defect

An earlier draft claimed shuffle rides along on this reconciliation. It does not, and the
reason is worth recording rather than deleting.

`handle_shuffle` emits the shuffle flag and updates librespot's own state — it does not call
`emit_set_queue_event()`. Spotifly therefore keeps the **pre-shuffle ordering** after
shuffle is switched on. That is not a split that has slipped; it is a list in the wrong
order, and no amount of re-splitting reconstructs it. Reconciliation would faithfully point
at the playing track inside a sequence that no longer describes what will play next.

So shuffle needs its own answer — a queue refresh, or an upstream emission — and it needs
its own evidence first. Not this plan.

Externally-controlled playback is genuinely covered: it moves the logical URI through the
same bridge callbacks, which is the trigger this design keys on.
