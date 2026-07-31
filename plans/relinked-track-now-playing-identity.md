# Relinked tracks lose their logical identity and blank the Now Playing bar

Status: **planned**
Components: `rust/src/lib.rs`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`Spotifly/Views/NowPlayingBarView.swift`
Found: 2026-07-31, while playing *At Night, Alone.* by Mike Posner

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

## Design

### 1. Centralize logical-track publication in the Rust bridge

Add a small helper in `rust/src/lib.rs` that updates `CURRENT_TRACK_URI` and reports
whether the value changed. Keep callback delivery outside the URI mutex, matching the
existing rule that callbacks may re-enter Swift and must never run while a Rust lock is
held.

Keep a separate helper for emitting `LoadingNotification`. The distinction matters:

- a real `Loading` event must continue emitting even when the URI did not change, because
  its non-zero `position_ms` is used during resume/reconnect;
- `Playing`/`Paused` should synthesize the notification only when their logical URI differs
  from `CURRENT_TRACK_URI`, avoiding duplicate notifications after an ordinary load.

### 2. Make each player event own only the data it can authoritatively supply

Change the event listener as follows:

| Event | Logical URI | Duration | Loading notification |
| --- | --- | --- | --- |
| `Loading { track_id, position_ms }` | Set from `track_id` | unchanged | Always, preserving `position_ms` |
| `TrackChanged { audio_item }` | **Do not change** | Set from `audio_item.duration_ms` | Never |
| `Playing { track_id, position_ms }` | Set from `track_id` | unchanged | Only if the logical URI changed |
| `Paused { track_id, position_ms }` | Set from `track_id` | unchanged | Only if the logical URI changed |

Update the URI before `send_local_playback_state` in the `Playing` and `Paused` arms. The
playback-state payload will then carry the logical ID instead of repeating the relinked ID
into Swift.

Keep `TrackChanged` as the duration source. Its debug line should label the ID as the
playable audio item and, when useful, include the currently known logical ID; it must no
longer claim it is triggering a track callback.

This is a Spotifly bridge correction, not an upstream librespot patch. Official librespot
is correctly exposing both the requested track and the audio item it selected.

### 3. Leave the Swift lookup strict

No fallback should be added to `NowPlayingBarView.currentTrack`. Once the bridge publishes
the correct logical ID, the current exact lookup is the desirable invariant: a Now Playing
URI should resolve to the same normalized entity used by the queue and library.

Do not fetch the playable alternative into `AppStore` as a second track. That would create
two entities for one context item, make favorites operate on the wrong ID, and conceal the
identity error rather than fix it.

No functional Swift changes are expected. `PlaybackViewModel` should continue treating the
loading/playback callbacks as authoritative after the bridge makes them internally
consistent.

### 4. Add regression tests around identity updates

Extract the state replacement decision into a pure Rust helper so it can be tested without
callbacks or global-state serialization. Cover:

1. An empty current URI adopts the first logical ID and reports a change.
2. Repeating the same logical ID reports no change.
3. A different logical ID replaces the old one and reports a change.
4. A normal load (`Loading A` then `Playing A`) produces one identity change.
5. A gapless transition with no `Loading` (`TrackChanged` for playable `D`, then
   `Playing C`) leaves the old identity untouched until `Playing C`, then changes to `C`.
6. A relinked `TrackChanged` never changes logical identity.

The last three may be expressed through a tiny pure reducer used by the listener, or by
testing the extracted decisions separately if introducing an event model solely for tests
would make the production code less clear.

## Verification

### Automated

From `spotifly-code/rust`:

```text
cargo fmt --check
cargo test
cargo check
```

Then build the macOS app to verify the Rust library and Swift bridge still integrate.
There should be no Swift formatting delta if the implementation remains Rust-only.

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
3. Let track 1 auto-advance into track 2.
   - This exercises the preloaded/gapless path where `Loading` may be absent.
   - `Playing.track_id` changes the logical URI exactly once and the bar updates to track 2.
4. Pause and resume.
   - The logical URI remains stable and no extra metadata/favorite request is caused by an
     identity flip.

### Runtime: controls

- Play a track that does not relink; Now Playing behavior must be unchanged.
- Seek, previous, next, and reconnect at a non-zero position; loading notifications must
  still carry the position needed by `PlaybackViewModel`.
- Start playback paused or restore paused playback, covering the `Paused.track_id` path.
- Confirm lock-screen/menu-bar Now Playing metadata and the in-app bar agree.

## Acceptance criteria

- The in-app Now Playing bar never adopts a playable-alternative ID as its track identity.
- Relinked tracks show cover, title, artist, favorite state, and context actions normally.
- Ordinary and gapless transitions publish one logical track change, not two identities for
  the same track.
- `CURRENT_DURATION_MS` still comes from the loaded audio item.
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
