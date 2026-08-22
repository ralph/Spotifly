# Every position Spotifly reports is the decoder's, not the one you can hear

Status: **diagnosed, not fixed.** Split out of
`plans/seek-bar-jumps-between-two-position-clocks.md`, which fixed the one symptom that
was *visible* — the seek bar jittering — and deliberately left these, because they need a
different and much larger change.
Components: `Spotifly/AudioRenderer.swift`, `Spotifly/ViewModels/PlaybackViewModel.swift`,
`rust/src/lib.rs`, `rust/src/proxy_sink.rs`
Found: 2026-08-14

## Symptom

Four things, all the same fact wearing different clothes. None is dramatic; the first is
the one a user could actually notice.

- **Every track after a context's first displays ~2 s ahead of its audio.** Measured, not
  inferred — see below.
- **Pausing steps the bar forward ~2 s**, then back. `PlayerEvent::Paused` carries the
  decoder position and reaches Swift through `send_local_playback_state`
  (`rust/src/lib.rs:2343`), while the Connect snapshot for the same instant carries the
  wall-clock one. In `../seek.log`: `25013` and `23016` for the same moment.
- **Resume after deactivation restarts ~2 s late**, because rehydration seeks to raw
  `POSITION_MS` (`rust/src/lib.rs:1998`, `:2753`) — audio that was decoded but never heard
  is skipped.
- **Freezing on disconnect freezes at the decoder position**
  (`PlaybackViewModel.swift:1084`), so the held value is ~2 s past where the music stopped.

## Cause

`AudioRenderer` deliberately runs a buffer: the writer may get up to
`maxBufferAheadSeconds = 2.0` ahead of real time (`AudioRenderer.swift:64`) so a network
hiccup does not become a dropout. Everything librespot reports as "the position" is
measured at the *decoder*, before that buffer — `packet_position.position_ms`
(`playback/src/player.rs:1470`), sent before the packet even reaches the sink. librespot
says so at `playback/src/player.rs:1489`: *"If we're ahead it's probably due to a buffer of
the backend and we're actually in time."*

Nothing in Spotifly subtracts the buffer, so nothing in Spotifly knows where the music is.

**The gapless case, measured** in `../seek-after2.log`. librespot starts the next track's
clock when the decoder switches — the same millisecond as the previous track's
`EndOfTrack`, with ~2 s of that track still queued:

```
07:27:15.655  PlayerEvent::EndOfTrack: …5aIfLbdgkbH7NbQryd1poB at 168398ms
07:27:15.655  PlayerEvent::Playing:    …3bz5lCYoTVdnhB2rCaMYKz at 0ms
```

Spirc anchors `nominal_start_time` there (`connect/src/spirc.rs:811`), and its positions
are exact wall-clock from it — 370 ms at `07:27:16.025`, 1197 ms at `07:27:16.852`. So for
track two onward the Connect clock and the decoder clock agree *with each other* and are
both ~2 s ahead of the speaker. Agreement is why nothing jitters, and why this is invisible
rather than absent.

Only a context's **first** track escapes: there the sink starts empty and `Playing` lands
within a buffer-fill of the music actually starting, which is what made the two clocks
disagree and produced the visible bug.

## Why the obvious fix does not work

Subtracting the renderer's in-flight audio inside `SpotifyPlayer.positionMs` was the first
plan for the seek-bar bug and was rejected under review. The subtraction is only valid
while audio flows uninterrupted, and the pipeline has several states where it does not:

- **Seek does not flush.** `handle_command_seek` moves the decoder and leaves the sink
  alone (`playback/src/player.rs:2234`); `ProxySink::clear_buffer` is reached only from
  `spotifly_clear_audio_buffer` and `spotifly_disconnect`. After a seek the decoder is at
  the target while the buffer still holds pre-seek audio, so subtracting the buffer's
  duration from the target puts the bar ~2 s *behind* where the user dropped it.
- **`stop()` does not empty the pipeline** (`AudioRenderer.swift:377`); it freezes the
  synchroniser and leaves the ring and `currentPTS` intact. "In flight" means something
  different across pause, resume and route change.
- **The pause path stops the renderer before the position is reported** (`ProxySink: Stop`
  at `29.445`, `Paused … 25013ms` at `29.478`), so a correction applied at that moment has
  nothing left to subtract.
- **It would not reach three of the four symptoms anyway**, since resume, the local
  playback state and the freeze all bypass that getter.

## What a fix needs

An actual playhead: a position that means "the sample leaving the speaker now".

The renderer already has half of it. `AVSampleBufferRenderSynchronizer.currentTime()` is
played-out time, and `currentPTS` is how much has been enqueued, so the audio in flight is
computable at any instant. The missing half is **which track position a given renderer time
corresponds to** — `Sink::write` carries samples and nothing else, so the mapping has to be
built alongside the stream rather than derived from it.

That means an epoch — renderer time ↔ track position — rebased at every point where the
correspondence breaks: seek, flush, pause/resume, route change (which recreates the
renderer entirely, `AudioRenderer.swift:463`) and track transition. Track transition is the
one that needs care: the boundary is exactly where two tracks' audio coexist in the buffer,
which is the case this whole plan is about.

Consumers to move over once it exists, none of which go through the Swift getter today:

| Consumer | Today |
|---|---|
| `send_local_playback_state` | `rust/src/lib.rs:2343` |
| resume rehydration | `rust/src/lib.rs:1998`, `:2753` |
| `freezePositionForDisconnect` | `PlaybackViewModel.swift:1084` |
| `checkDriftAndSync` | via `SpotifyPlayer.positionMs` |

## Worth weighing before doing it

The error is ~2 s on a track of a few minutes, it is consistent rather than jumpy, and the
one place it was *visible* is fixed. Against that, it touches the audio pipeline, which is
the part of this app where a mistake is audible rather than cosmetic. The honest reading is
that this is worth doing when something else already requires touching the renderer's
lifecycle, and hard to justify on its own.

A cheaper partial step, if the pause step is the one that grates: carry a last-known
audible position across `ProxySink::Stop` so `PlayerEvent::Paused` can report it instead of
the decoder's. That fixes one row of the table and none of the others.
