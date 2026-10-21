# AVPlayer as the audio output, streamed, with AirPlay from the shell

Status: **Done**, 2026-10-21, PR #219: the app's only output, the renderer removed. Probed behind
a Debug switch first (below), checked by ear through the Mac's microphone on the Küche HomePod,
not by the user. Two limits stay: the bar's volume does not reach a receiver, and a paused
Spotifly loses its receiver when another app plays. Supersedes #202's handover design
Components: `Spotifly/AudioOutput.swift` (was the probe's `StreamingPlayerSink.swift`),
`Spotifly/AudioRenderer.swift` (removed), `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`,
`Spotifly/SpotifyPlayer.swift`, `Spotifly/Views/AirPlayRoutePickerView.swift`,
`Spotifly/Views/NowPlayingBarView.swift`, `Spotifly/Views/SpeakersView.swift`,
`Spotifly/Views/Components/AudioOutputDevice.swift` (removed), `DEVELOPMENT.md`
Found: 2026-10-21, `plans/open/spotifly-only-airplay.md` on PR #202, and the user: "try AVPlayer
for everything … and get around the whole file needs to be decoded restriction"

## Summary

Only an `AVPlayer` can be sent to AirPlay by itself on macOS (`AVRoutePickerView.player`), so
#202 handed playback over between the renderer and an `AVPlayer` playing one whole decoded song.
Instead, `AVPlayer` is now the only output, fed as one continuous stream: AirPlay is a choice in
the native picker rather than a mode, nothing is decoded ahead of need, and the pipeline, Connect,
the queue and gapless playback are unchanged.

## Problem

- #202's handover was the costly part: two clocks, two volume paths, a one-song limit that
  refused next-track commands, no gapless or queue on AirPlay, and an "AirPlay verwenden" step
  before the picker.
- Its `AVPlayer` played a complete CAF of a decoded song: 74 MB and 0.9 s of preparation for
  3.5 minutes, written before a note plays. Streaming was named and not tried.
- #202 rejected `AVPlayer` for everything "without evidence". The probe measured its own.

## Solution

### The output

`AudioPipeline` pushes Float32 PCM into one output and paces itself on it: `enqueue` suspends
until the output wants more, `restart`, `pause`, `resume`, `stop`, `playedFrames` for the audible
playhead, `setVolume`. It decodes the next track into the same output behind the current one,
which is all its gapless playback is. `AudioOutput` keeps that contract over an `AVPlayer`:

- The player's item is a stream the output writes: a CAF of 44.1 kHz stereo Float32 PCM, served
  through an `AVAssetResourceLoader` delegate under a custom URL scheme, with a data chunk
  declared a week long. **One item serves the session**: a `restart` (a load, a seek) is a held
  seek within it to the end of what is written, where the new audio begins, and plays once the
  seek is done. Between tracks the stream runs on, so a track change is the next sample.
- Pacing: `enqueue` appends to the stream and returns once what is written ahead of the playhead
  is under 10 s, or at once while the player waits or stands still (up to 30 s); asleep, it wakes
  about once a second. The loader answers `AVPlayer`'s requests from what is written, holding a
  request until the bytes exist, and keeps 8 MB behind what the player has read.
- `playedFrames` from the item's timebase: audible time, which accounts for a receiver's latency.
- Volume: `AVPlayer.volume`, this Mac's; a failed item is reported (`.failed`) and replaced at the
  next restart.

Removed with the renderer: the `AudioSink` protocol the probe compared them through, the
pipeline's refill from the playhead after a stalled or changed output (the player follows an
output change itself), and the probe's Debug switch.

### Shell

- `AirPlayRoutePickerView` binds the output's player, so the picker routes Spotifly alone.
- Bar: the AirPlay button is that picker while this Mac plays (the system highlights it while a
  receiver is chosen); with another Connect device playing, it opens Wiedergabe auf.
- Wiedergabe auf: the AirPlay row's picker, bound the same way, without the Mac's output device
  name, which is not where Spotifly plays once routed (nothing reports the player's route); its
  footer says only Spotifly goes there and where the receiver's volume is.
- Volume: the bar's slider is this Mac's player volume. No public macOS API sets a receiver's
  volume, or says a receiver is chosen, so the slider's tooltip says a receiver's volume is set in
  the AirPlay menu, whose own slider sets it.

### Left as it was

- `docs/cpu-benchmark/renderer/` measured `AudioRenderer.swift` alone and no longer runs; the
  benchmark write-up is a record of 2026-09-27.
- #202's plans (`spotifly-only-airplay.md`, `spotifly-airplay-backend.md`) live on its own
  branch; this design replaces them.

## Verification

- Build, unit tests (the stream header).
- Live, on the LG display and the Küche HomePod: play, pause, seek, Next, a gapless live album
  across a track change, a Connect handover out and back, output changes, CPU against the
  renderer, by ear through the Mac's microphone; and again with the renderer gone (below).

### Probe, first round

Measured on 2026-10-21 with the probe's switch on, macOS 27, Green Day's artist context, on the LG
display's speakers and on the Küche HomePod. Each line is from the `PlayerSink` log (now `AudioOutput`) (a line every
5 s: the item's playhead, what it has loaded, its rate).

**Streaming works; nothing is decoded ahead as a file.** `AVPlayer` asks the loader for 2 bytes
at 0, then the stream from 0, and reads the declared end before it plays: with an hour declared,
the last 57 KB (aligned to 64 KB); with a day, at 1,667,301,376 and at the true end, 30.48 GB.
Those are answered with silence (zeros, at most 4 MB, then finished), which is what PCM that far
in would be; unanswered, the item never became ready. Then one sequential range request serves
the whole session, the loader answering it as the pipeline writes. Ready 51–65 ms after a load;
the pipeline feeds 10 s ahead of the playhead (the player loaded up to 30 s ahead locally, 25 s
on the HomePod), and drops bytes 8 MB behind what the player has read. Memory is bounded.

Findings, in the order they were met:

1. **Feeding 3 s ahead starved the player** after a resume: it stood still for 8 s reporting
   "playing". With `automaticallyWaitsToMinimizeStalling` off a starved player does not report
   waiting, so the sink also counts a player that plays and does not move for 300 ms as wanting
   data, and feeds 10 s ahead.
2. **An item started while a receiver is chosen never loads.** After a seek on the HomePod the
   new item asked the loader for nothing, with `allowsExternalPlayback` on or off. An item that
   started locally keeps playing after the switch. Hence one item per session, a restart being a
   seek within it: seeks then took 26–59 ms, locally and on the HomePod, and Next 57 ms.
3. **A stalled player pauses itself** (status paused, rate 1) and stays so; seen once on resuming
   on the HomePod. The output now plays it again when it pauses while meant to play; three
   pause/resume cycles on the HomePod after that were clean.

What held:

- **Gapless**, locally and on the HomePod: "follows without a gap", the playhead running on
  through the boundary (30.0 → 35.1 → 40.1 s; on the HomePod 93.3 → 98.3 → 103.3 s). The track
  change is inside one stream, so there is nothing for the player to join.
- **Output changes** (display speakers ↔ MacBook speakers, by setting the default output): the
  player follows on its own, losing 0.2–0.6 s of playhead around each; no stall workaround.
- **AirPlay from the bar's picker**: "Küche HomePod" ticked, the Mac's default output stayed the
  LG display, so only Spotifly went there; the switch cost about 0.9 s of playhead. Seek, Next,
  pause/resume and a track boundary on the HomePod as above; picking the Mac again went back
  without a stop. The picker keeps the HomePod across seeks, as the route belongs to the player.
- The renderer path, switch off, plays as before, and the bar shows its Wiedergabe-auf button.

### Probe, second round: by ear, CPU, handover

Listened with the MacBook's microphone (`ffmpeg -f avfoundation`), the HomePod beside it, the
level per 50–250 ms window in dBFS; the room is about −76 dB, music −35 to −40.

- **The HomePod plays it**: −39 dB with the Mac's output muted, −76 paused.
- **Gapless, heard**: across a track change on a live album (*Bullet in a Bible*, Longview into
  the next, the crowd never silent) the quietest 50 ms of 25 s was −39.8 dB against a median of
  −35.3; a gap would be the room's −76.
- **Pause and resume** on the HomePod: silent within about 0.5 s, sound back within 0.5 s, three
  times each.
- **The bar's volume does not reach the HomePod**: −34.8 dB at 70 %, −34.9 at 30 %, where the
  curve would take 24 dB off. #202 found the same. macOS 27 has no public API for an
  `AVPlayer`'s route or its receiver's volume (`AVRoutingPlaybackArbiter`, `outputContext` are
  iOS and tvOS only); the picker's own slider sets the receiver's volume.
- **CPU**, A-B-A on the LG display, same Debug build: renderer 3.27 % / 3.17 %, AVPlayer 3.17 %
  of a core; `coreaudiod` 1.47 % either way; idle wakeups 2.6–2.9 / 3.9 a second (11.7 before the
  wait slept to a second under the target); energy 3.2–3.7 / 3.1; memory 183 MB / 258 MB.
- **Connect handover** to the web player and back: Spotifly stopped and took over again, playing
  in 12 ms, but on the Mac: the HomePod route had gone.
- **A paused Spotifly loses its receiver when another app plays**: reproduced with `afplay`
  playing a tone for 10 s while paused; the picker showed the Mac again. A 20 s pause with nothing
  else playing kept the HomePod, and another app playing while Spotifly plays does not take it.
  The app cannot set the route back.

Found and fixed meanwhile:

- **A seek could be dropped**: playing right after `seek` cancelled it now and then, and the
  player played on through 2.4 s of the old position. The output now holds, seeks, and plays when
  the seek is done; four quick seeks after it took 28–37 ms each, the playhead never behind the
  target.
- **The far look-ahead**: finished empty, not with 4 MB of silence, which would have played 79
  minutes in; the player's one range request then runs to the declared end.

Not known:

- Whether another app's audio stays off the HomePod, by ear: the microphone could not tell a
  3150 Hz tone from the music. The Mac's default output never changes, which is the evidence.
- A session past a week of stream (a restart then begins a new stream, which on a receiver would
  not load), sleep and wake, a receiver lost mid-song.

Codex found two, fixed: a failed item was only logged, so the decode waited on it forever and a
restart sought within it (now reported to the pipeline as `.failed`, and replaced on the next
restart); and Wiedergabe auf named the Mac's default output while Spotifly played on the HomePod
(left out in this mode).

### Review round: a leak, a week, cleanup

- **The stream leaked**: trimmed with `Data.removeFirst`, which only re-slices, it kept every
  byte written, 21 MB a minute. It now keeps the pieces the pipeline pushed and drops whole ones
  behind the player. Footprint over a minute of playback after it: 192 MB flat. What still moves
  is `AVPlayer`'s own HTTP cache, which fills to 32 MB and stays there, and large blocks the
  allocator returns late.
- **A day of gapless play ran off the stream's end** (Codex): only a load or a seek begins a new
  stream. Declared a week long now; the player makes the same far read at 0x63610000, reads the
  declared end, and is ready in 140 ms.
- Cleanup: volume set on the player alone, one locked state for what the actor reads of it, no
  run counters (the pipeline retires a decode before it starts another, and asserts it), no
  log-only timing, a resume that does not count as a stall.

Checked through a Connect handover from the web player, the Mac's screen locked (so on the LG
display, and not by ear: its volume was at 6 %), against the item's clock: a gapless track change
due at 20:14:38.66 came at 38.81 (one 250 ms tick); after a seek, 16.02 s of audio in 16.10 s;
after a resume, 10.09 s in 10.08 s.

Then on the Küche HomePod, by ear through the Mac's microphone (the room at −68 to −82 dB),
its volume turned down from 52 % to 35 % in the picker's slider:

- Playing: −35.7 dB at 52 %, −41.8 dB at 35 %, no dropouts.
- Pause and resume: silent and back within about half a second, five times. One resume, at the
  very end of a track with the next decoded behind it, went silent for about 1.3 s: the player
  paused itself 1.3 s in, and the output's restart 100 ms later brought it back.
- Seeks: eleven of twelve done in 4–263 ms with the music running on. **One took 18 s**: the
  player said paused, yet the HomePod played on through the 9 s written ahead and into the new
  run, a gapless continuation was taken over, and the late seek then moved the playhead back
  8 s. The pipeline trapped converting that negative position, and the app crashed; it now
  clamps it to the track, as every other reader did. The 8 s heard twice in that case remain.
- Gapless across two track changes, no window under −50 dB; Next twice, playing within 15 ms.
- Footprint over two minutes of playback: 284 MB, flat.
