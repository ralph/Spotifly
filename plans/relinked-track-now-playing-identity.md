# Relinked tracks lose their logical identity and blank the Now Playing bar

Status: **completed**
Components: `rust/src/lib.rs`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-07-31, while playing *At Night, Alone.* by Mike Posner

## Implemented solution

Completed on 2026-07-31 in three independently verified implementation commits:

- `987d35f` makes `Loading`, `Playing`, and `Paused` the only owners of the logical
  track URI in the Rust bridge. `TrackChanged` now contributes only the playable audio
  item's duration and no longer emits a synthetic loading callback.
- `51c399f` resets cached stream duration whenever the logical URI changes and makes the
  in-app bar prefer a non-zero stream duration over provisional store metadata.
- `1808012` resolves macOS Now Playing metadata from the logical playback URI, clears
  stale metadata/artwork, uses the same effective-duration rule as the bar, and refreshes
  on both early loading identity and the first authoritative stream duration.

The implementation follows the identity split described below without modifying
librespot. Because `CURRENT_TRACK_URI` is now logical, the existing reconnect resume hint
and radio same-track comparison are repaired by the same bridge change.

Automated verification completed:

- `cargo fmt --check`
- `cargo test` — 23 tests passed
- `cargo check`
- `swiftformat --swiftversion 6.3 .` — no remaining changes
- full Debug macOS app build, including the Rust library — succeeded after each Swift
  implementation step

The live Spotify scenarios in the Runtime sections remain the manual release-smoke
checklist; they require an authenticated playback session and the market-specific
relinked album.

## Symptom

Playback and the queue are healthy, but the Now Playing bar shows only the music-note
placeholder: no cover, title, or artist. Starting the album at a different track does not
help. The failure is album/version-specific and therefore appears intermittent.

The queue still renders complete metadata because it is populated from the album's
logical track IDs. The Now Playing bar independently resolves
`PlaybackViewModel.currentTrackUri` in `AppStore.tracks`; that lookup fails after the URI
has been replaced with a different, playable track ID.

## Evidence

Double-clicking track 2 produces two identities for the same playback:

```text
Loading event: spotify:track:3CCyVdprlcXui4ZwMw1hNS at 0ms
Loading notification: spotify:track:3CCyVdprlcXui4ZwMw1hNS at 0ms
Loading <I Took A Pill In Ibiza> with Spotify URI <spotify:track:7zzoxJbgjme3366mOp5UnH>
TrackChanged event: spotify:track:7zzoxJbgjme3366mOp5UnH (280800ms)
Loading notification: spotify:track:7zzoxJbgjme3366mOp5UnH at 0ms
Playback state update: ... uri=spotify:track:7zzoxJbgjme3366mOp5UnH
```

Starting from track 1 repeats the same pattern:

```text
Loading event: spotify:track:0kIoSy4Fl8Y6qlSJYSD2s8 at 0ms
Loading <At Night, Alone.> with Spotify URI <spotify:track:5Aa7RD4Pdp14vII8SVsrSS>
TrackChanged event: spotify:track:5Aa7RD4Pdp14vII8SVsrSS (10386ms)
```

The first ID in each pair is the logical track selected from the album context. The
second is an alternative audio item chosen by librespot's relinking path because the
logical item has no directly usable audio file for this user/market.

`QueueService` caches the original IDs (`3CCy…`, `0kIo…`), while the Rust bridge currently
overwrites `CURRENT_TRACK_URI` with `TrackChanged.audio_item.track_id` (`7zzo…`, `5Aa7…`).
`NowPlayingBarView.currentTrack` then performs an exact dictionary lookup using the latter
and gets `nil`.

## Identity rule

Spotifly must distinguish two concepts:

- **Logical track identity:** the URI selected by the context/queue. This owns UI state,
  favorites, queue position, media-key metadata, and Web API lookups.
- **Playable audio identity:** the relinked `AudioItem` librespot actually decodes. This is
  an implementation detail of playback and may supply duration and stream metadata, but it
  must not replace the logical identity.

The bridge already receives the correct logical ID:

- `PlayerEvent::Loading.track_id` for ordinary loads;
- `PlayerEvent::Playing.track_id` or `PlayerEvent::Paused.track_id` when a preloaded or
  gapless transition skips `Loading`.

Librespot's `start_playback` emits `TrackChanged` first and then `Playing`/`Paused`. The
`track_id` on the latter is the requested ID; the `audio_item.track_id` on the former may
be the relinked alternative.

This was verified against the checked-out librespot, not inferred from the log:

- `PlayerTrackLoader::find_available_alternative` (`playback/src/player.rs`) replaces the
  `AudioItem` when its `files` are empty, which is where the alternative ID enters.
- `PlayerInternal::start_playback(track_id, …)` receives the logical ID as a separate
  argument — from `PlayerState::Loading.track_id` on an ordinary load, or from
  `PlayerPreload::Ready.track_id` on a preloaded transition — and passes exactly that into
  `Playing`/`Paused`, while `TrackChanged` carries the loaded `audio_item`.
- Both branches of `start_playback` emit exactly one of `Playing` or `Paused`. No load path
  ends with only a `TrackChanged`, so dropping the notification from `TrackChanged` cannot
  lose a notification.

`TrackChanged` lands the new duration *before* the logical URI changes. Once it stops
emitting a callback, that intermediate state is not published through the playback
subjects; `Playing`/`Paused` publishes the logical URI together with that duration.

## Design

### 1. Centralize logical-track publication in the Rust bridge

Add a small helper in `rust/src/lib.rs` that updates `CURRENT_TRACK_URI`. Keep callback
delivery outside the URI mutex, matching the existing rule that callbacks may re-enter
Swift and must never run while a Rust lock is held.

A real `Loading` event must continue emitting `LoadingNotification` even when the URI did
not change, because its non-zero `position_ms` is used during resume/reconnect. A
preloaded transition that skips `Loading` does not need a synthetic copy: the following
`Playing`/`Paused` playback-state callback already carries logical URI, authoritative
duration, and position together.

### 2. Make each player event own only the data it can authoritatively supply

Change the event listener as follows:

| Event | Logical URI | Duration | Loading notification |
| --- | --- | --- | --- |
| `Loading { track_id, position_ms }` | Set from `track_id` | unchanged | Always, preserving `position_ms` |
| `TrackChanged { audio_item }` | **Do not change** | Set from `audio_item.duration_ms` | Never |
| `Playing { track_id, position_ms }` | Set from `track_id` | unchanged | Never; playback state carries the transition |
| `Paused { track_id, position_ms }` | Set from `track_id` | unchanged | Never; playback state carries the transition |

Update the URI before `send_local_playback_state` in the `Playing` and `Paused` arms. The
playback-state payload will then carry the logical ID instead of repeating the relinked ID
into Swift.

Do not synthesize `LoadingNotification` from `Playing`/`Paused`. The two Swift bridge
callbacks each create a separate unstructured `Task { @MainActor … }`, whose relative
execution order is not guaranteed. Publishing one complete playback-state payload avoids
introducing a cross-subject ordering dependency in the gapless/preloaded path.

Keep `TrackChanged` as the duration source. Its debug line should label the ID as the
playable audio item and, when useful, include the currently known logical ID; it must no
longer claim it is triggering a track callback.

This is a Spotifly bridge correction, not an upstream librespot patch. Official librespot
is correctly exposing both the requested track and the audio item it selected.

`CURRENT_TRACK_URI` has exactly two writers, both in the event listener, so the change is
fully contained in `rust/src/lib.rs`.

### 2a. Two further readers are repaired by the same change

The blank Now Playing bar is the visible symptom, but the relinked ID also leaks into two
places that compare or replay the URI. Both are silently wrong today and become correct
without extra work:

- `resume_via_load` passes the current URI back to Spirc as `PlayingTrack::Uri`. A context
  contains logical IDs, so a relinked hint never matches and the resume silently loses its
  track position hint.
- The radio path compares `CURRENT_TRACK_URI` against the URI Swift passed in to decide
  whether to carry the current position over. On a relinked track the comparison fails and
  `seek_to` falls back to 0.

Neither needs its own fix, but both belong in the changelog entry: this is an identity
correction, not only a Now Playing bar fix.

### 2b. Duration deliberately stays with the playable item

After this change the two identities own different data, and duration is the one field
that comes from the playable item rather than the logical one. `CURRENT_DURATION_MS` must
keep coming from `TrackChanged`, because it describes the stream actually being decoded —
that is what the seek bar and position interpolation have to agree with.

### 3. Keep the lookup strict and align both Now Playing surfaces

No fallback should be added to `NowPlayingBarView.currentTrack`. Once the bridge publishes
the correct logical ID, the current exact lookup is the desirable invariant: a Now Playing
URI should resolve to the same normalized entity used by the queue and library.

Do not fetch the playable alternative into `AppStore` as a second track. That would create
two entities for one context item, make favorites operate on the wrong ID, and conceal the
identity error rather than fix it.

The bridge fix makes the callbacks internally consistent, but the Swift side still needs
to bind duration and metadata to that logical identity. Three changes belong in this fix:

- invalidate the cached stream duration whenever the logical URI changes;
- use the logical track's stored duration provisionally until the stream duration arrives;
- resolve the macOS Now Playing panel from the same logical URI as the in-app bar, not from
  the queue's independently timed current pointer.

### 3a. Bind duration to the current logical track

`NowPlayingBarView.currentDurationMs` prefers `currentTrack.durationMs` from the store and
falls back to `playbackViewModel.trackDurationMs`. That precedence is backwards, and today
it is *hidden by the very bug being fixed*: on a relinked track `currentTrack` is `nil`,
so the fallback runs and the seek bar happens to use the real stream duration.

Making the lookup succeed removes that accident. The bar would start using the logical
track's duration while playback follows the relinked stream, so a duration difference would
show up as a seek bar that ends early or never reaches the end.

Invert the bar's precedence: `playbackViewModel.trackDurationMs` wins whenever it is
non-zero, and `currentTrack.durationMs` is the fallback before the first playback state.
That is safe only if a non-zero `trackDurationMs` always belongs to the current logical
track.

Enforce that invariant at the source. Give `currentTrackUri` a `didSet` guarded by
`oldValue != currentTrackUri` that resets `trackDurationMs` to zero. This covers every URI
writer — app-initiated playback, loading callbacks, direct playback-state changes, Web API
bootstrap, and stop — rather than relying on selected call sites to remember the reset.
Both `handlePlaybackStateUpdate` and `applyWebAPIPlaybackState` assign the URI before the
new duration, so the reset cannot erase a fresh duration from the same update.

The transition is then:

1. `Loading` adopts the new logical URI and clears the previous stream duration.
2. The in-app bar and system panel use the new logical track's stored duration.
3. `TrackChanged` records the playable stream duration in Rust.
4. `Playing`/`Paused` publishes it to Swift, replacing the provisional duration.

`ShuffleChanged` or `RepeatChanged` can publish the previous Rust duration between steps 1
and 3. That briefly re-arms the old value, but the following `Playing`/`Paused` callback
self-corrects it; expanding the Rust state machine to eliminate this narrow window is not
worth the extra scope.

### 3b. Make macOS Now Playing follow the same identity

`PlaybackViewModel.updateNowPlayingInfo()` currently reads `store.currentTrackEntity`,
which follows `queue.currentTrack`. The log shows that pointer can still name track 1 after
the user selected track 2 because librespot emits `SetQueue` before applying the requested
index. The in-app bar correctly rejects that source, so the system panel must reject it too.

Resolve metadata by parsing `currentTrackUri` and reading `store.tracks[trackId]`. Use one
effective-duration rule in both `updateNowPlayingInfo()` and
`updateNowPlayingPosition()`:

- non-zero `trackDurationMs` is the authoritative playable-stream duration;
- otherwise use the resolved logical track's stored duration;
- if neither exists, omit duration-dependent fields rather than carrying values from the
  previous track.

Refresh points must cover every ordering:

- At the end of the loading subscription — after applying `position_ms`, so a reconnect
  never publishes the previous track's elapsed time — refresh when the logical URI changed.
- In `handlePlaybackStateUpdate`, refresh when the logical track changed **or** when a new
  non-zero stream duration replaced the provisional value. The duration-change condition
  depends on the URI `didSet` reset: it guarantees a new track passes through zero even when
  two consecutive tracks have identical durations. This also repairs `playTracks`, whose
  optimistic `handlePlaybackStarted` sets `lastHandledTrackUri` early and therefore makes
  the later playback callback report `trackChanged == false`.
- `applyWebAPIPlaybackState` keeps its full refresh after assigning URI and duration.
- `QueueService.updateNowPlayingMetadata` remains the late-metadata refresh path.

When the logical URI is not a track or its entity is not in the store, explicitly remove
the old title, artist, and artwork from `MPNowPlayingInfoCenter` rather than pairing the
previous track's metadata with the current duration. Reset `lastAlbumArtURL` at the same
time, otherwise the same artwork URL cannot be installed when metadata later arrives.

Update the initialization comment around `updateNowPlayingPosition()` and
`trackDurationMs = 0`; it currently documents the old duration-only guard and becomes
incorrect once both Now Playing methods use the effective duration.

### 3c. Known gap: unknown track metadata (closed by the follow-up)

A logical track URI with no entity in `AppStore` leaves the in-app bar on its placeholder
and the system panel without a title. `QueueService` already fetches the current track on
SetQueue, live queue updates, and Web API bootstrap, so this is not the normal relinking
path. Adding an *independent* loader in `TrackService` would have raced that existing fetch
and could not honestly promise one request per ID, which is why it was deferred out of this
change rather than bolted on.

It was closed the same day by `plans/now-playing-unknown-track-loader.md`, which routes
queue hydration and single-track recovery through one shared per-ID registry in
`TrackService`. Two later corrections belong to that gap and are recorded here so this
section is not read as still-open work:

- while no track resolves, the system panel publishes the app name rather than removing the
  title, so the media-control claim made at init survives the wait for metadata;
- an ID a successful response came back without is remembered as absent, so the shared
  loader is not asked for it again on every queue update.

### 4. Verify event routing at runtime

The important contract is which `PlayerEvent` arm may update logical identity, not the
assignment of one `Option<String>`. A unit test for that assignment would not catch the
regression, while a reducer over real events would require constructing librespot
`AudioItem` values and couple the tests to an unpinned path dependency solely for this
case. Keep the Rust helper small and cover ordinary, relinked, and gapless event routing in
the runtime verification below. If a production event reducer later earns its place, add
sequence tests against it then.

## Verification

### Automated

From `spotifly-code/rust`:

```text
cargo fmt --check
cargo test
cargo check
```

Then build the macOS app to verify the Rust library and Swift bridge still integrate. The
Swift side changes too, so run `swiftformat --swiftversion 6.3 .` and commit whatever it
produces rather than assuming there is no delta.

### Runtime: relinked album

Use the same *At Night, Alone.* album and capture the same debug logging.

1. Double-click track 2.
   - Audio starts on track 2.
   - The bar immediately shows *I Took A Pill In Ibiza*, Mike Posner, and the album art.
   - `PlaybackViewModel.currentTrackUri` remains `3CCy…`.
   - The log may show playable audio item `7zzo…`, but no Swift loading or playback-state
     callback carries `7zzo…`.
   - Favorite-status lookup uses `3CCy…`, not `7zzo…`.
2. Start the album from track 1.
   - The bar shows *At Night, Alone.* using `0kIo…`, even though audio comes from `5Aa7…`.
   - The seek bar length matches the audio that is actually playing, and the position
     reaches the end without clipping or stalling early.
3. Let track 1 auto-advance into track 2.
   - This exercises the preloaded/gapless path where `Loading` may be absent.
   - `Playing.track_id` changes the logical URI exactly once and the bar updates to track 2.
4. Pause and resume.
   - The logical URI remains stable and no extra metadata/favorite request is caused by an
     identity flip.

### Runtime: controls

- Resume after a reconnect on a relinked track; the track hint passed back to Spirc is now
  a context ID, so the resume should land on the same track rather than the context start.
- Start radio from a relinked track that is currently playing; the position should carry
  over instead of restarting at 0.
- Play a track that does not relink; Now Playing behavior must be unchanged.
- Start from an album context and confirm the system panel does not briefly publish the
  previous queue track before the real `Loading` URI arrives.
- Play a track already present in the store and confirm the system panel shows its logical
  title with provisional store duration, then adopts stream duration without changing the
  title.
- Seek, previous, next, and reconnect at a non-zero position; loading notifications must
  still carry the position needed by `PlaybackViewModel`.
- Start playback paused or restore paused playback, covering the `Paused.track_id` path.
- Confirm lock-screen/menu-bar Now Playing metadata and the in-app bar resolve the same
  logical track.

## Acceptance criteria

- The in-app Now Playing bar never adopts a playable-alternative ID as its track identity.
- Relinked tracks show cover, title, artist, favorite state, and context actions normally.
- Ordinary and gapless transitions publish one logical track change, not two identities for
  the same track.
- `CURRENT_DURATION_MS` still comes from the loaded audio item, and the seek bar follows it
  rather than the logical track's stored duration.
- Resume-with-track-hint and radio-with-position work on relinked tracks.
- Double-clicking a relinked track and gapless auto-advance both keep the logical URI; no
  playable-alternative URI reaches either Swift playback subject.
- The system Now Playing panel and in-app bar resolve the same logical track and never pair
  one track's title or artwork with another track's duration.
- Resume/reconnect preserves non-zero loading positions.
- The Rust test suite, Rust compile check, and macOS app build pass.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.

## Related queue-position observation

The first screenshot shows `1/18` while track 2 is playing. The log explains this too:
librespot emits `SetQueue` while track 1 is still current, then applies
`playing_track=Index(1)` immediately afterwards without emitting a second `SetQueue`.

This is separate from the blank metadata. A UI fallback to `store.currentTrackEntity`
would therefore show track 1 and is explicitly rejected above. The logical-URI fix makes
the title/artist/art resolve correctly without relying on that stale queue pointer.

Correcting the queue index should be a follow-up with its own invariants, particularly for
duplicate tracks, previous navigation, shuffle, and externally controlled playback. It is
not required to fix the reported missing track information and should not broaden this
change unless runtime verification shows it blocks the acceptance criteria.
