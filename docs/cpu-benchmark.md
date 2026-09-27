# CPU benchmark: librespot (1.2.7) and the Swift stack

Measured on 2026-09-27, to see where Spotifly's CPU goes on the `swift-librespot`
branch and how that compares with the last release built on librespot. Nothing like
this had been recorded before: the only earlier figure is the changelog's relative
"~94% fewer active CPU samples than 1.2.2" for 1.2.3.

**Short version:** decoding costs the same with symphonia (librespot) and libvorbis
(Swift), and neither is where the CPU goes. Most of the playback cost is Core Audio's
output work inside the process, and that varied between runs of the *same* build by
more than the builds differ from each other. What the migration does change for
certain: 31 threads become 12, and, with the seek-bar fix found here, a paused app
drops from 0.30% to 0.12% of a core. A back-to-back comparison of the two builds on
the same output is still to be done — see [Open](#open).

**Later the same day:** idle wakeups while playing, where the branch started out worse
than 1.2.7 (19–26 a second against 17.7), are down to 2 a second, and energy impact
from about 4 to 2.5 against 1.2.7's 3.5, by feeding the renderer from its own callback
again and decoding in half-second bursts. The same work found that a pause dropped up
to 46 ms of audio. Moving to macOS 27's renderer receiver then took the renderer's own
cost down by another third, to no idle wakeups at all. See
[Feeding the renderer](#feeding-the-renderer).

## Setup

- Apple M4, macOS 27.0, Release builds only.
- **Before:** Spotifly 1.2.7 from `/Applications` — the notarized release of
  2026-08-14, identical to the latest GitHub release; librespot in Rust, symphonia
  decoding Vorbis. It sends PCM to the same Swift `AudioRenderer`
  (`AVSampleBufferAudioRenderer`) the branch uses.
- **After:** `swift-librespot` built locally in Release: `ac4faaf` (gapless and
  Spatial Audio in), then the same plus the fixes below (`283fde8`), and at 12:07 with
  the renderer fed by its callback (`5c00231`).
- The same album throughout (Brian Fallon, *Not Bad for New Jersey*) at the default
  Normal quality (160 kbps), started on Spotifly from the web player over Connect.
- Output device: the LG UltraFine display's USB audio at 48 kHz, checked at 10:42;
  not recorded before that. Times below are when each run's CPU window ended.

## Method

[`cpu-benchmark/measure.sh`](cpu-benchmark/measure.sh) `<label>`, once playback or the
pause has settled:

1. **CPU:** 60 s of CPU time from `ps`, for the app and for `coreaudiod`. This is the
   headline number.
2. **Wakeups and energy:** two `top` samples 30 s apart. `IDLEW` counts since launch,
   so the rate is their difference over 30 s.
3. **Where it goes:** a 30 s Time Profiler trace attached with `xctrace`, exported
   and summed by thread, binary and function by
   [`cpu-benchmark/aggregate.py`](cpu-benchmark/aggregate.py) (`THREAD=<name>`
   narrows it to one thread). The trace's totals came out anywhere from 30% below to 80%
   above the `ps` figure for the same run, so use it for the split, not the level.

[`cpu-benchmark/micro/run.sh`](cpu-benchmark/micro/run.sh) times the decoder and the
decryption on their own.

Things that bit:

- `pgrep -f` also matches the shell that launched the app. Use `pgrep -x Spotifly`.
- The release is signed with a Developer ID and local builds with a development
  certificate, so whichever one runs second makes macOS ask whether it may use the
  other's data container, and it waits on that alert with no CPU at all.
- Spotify resumes playback on a device that registers under the id of the one that
  was playing. A 1.2.7 run meant to be idle was playing, and was discarded.
- `top` counts only wakeups *from idle*, so the count falls when something else keeps
  the cores awake. The same renderer build measured 28–32 a second on a quiet Mac and
  15 while the Mac was in use. Compare runs made back to back, and alternate them.

## Results

### Playing

| Build (time) | App CPU | `coreaudiod` | Threads | RSS | Idle wakeups/s | Energy impact |
|---|---|---|---|---|---|---|
| 1.2.7 (10:26) | 2.37% | 4.50% | 32 | 148 MB | 17.7 | 3.5 |
| `ac4faaf` (10:09) | 1.92% | 6.83% | 13 | 168 MB | — | — |
| with fixes (10:41) | 3.22% | 5.00% | 12 | 196 MB | 19.3 | 4.3 |
| with fixes, track 1 from 0:15 (10:54) | 2.08% | 3.33% | 12 | 212 MB | 25.5 | 4.0 |
| renderer fed by its callback, track 1 from 0:47 (12:07) | 2.63% | 4.83% | 13 | 208 MB | **2.1** | **2.5** |
| receiver, MacBook Air speakers, "Fading on Me" from 1:08 (13:20) | 2.27% | 7.83% | 11 | 203 MB | 1.0 | 2.3 |

CPU is the percentage of one core over 60 s. The 1.2.7 wakeup and energy figures come
from a separate 60 s `top` window during the same playback.

Split from the Time Profiler, in ms on CPU per 30 s:

| | 1.2.7 | `ac4faaf` | with fixes (10:54) |
|---|---|---|---|
| Decoding | 184 (symphonia, librespot's player thread) | 184 (libvorbis, `spotifly.decode`) | 244 |
| Core Audio output, in process (HAL I/O, AudioQueue, converter threads) | 477 | 290 | 435 |
| Main thread (SwiftUI) | 124 | 156 | 176 |
| Everything else | 167 | 26 | 190 |
| Trace total | 952 (3.17%) | 656 (2.19%) | 1045 (3.48%) |

Core Audio does not always do its output work on the same threads: in the 10:41 run
the HAL I/O thread did 8 ms and GCD worker threads did the AudioQueue callbacks
instead. Its share is the biggest one either way, and it is the part that moves
between runs, so no Spotifly code change is behind the spread in the first table.

### Paused

| Build | App CPU | `coreaudiod` | Threads | RSS | Idle wakeups/s | Energy impact |
|---|---|---|---|---|---|---|
| 1.2.7, paused | 0.30% | 3.33% | 31 | 148 MB | 0.6 | 0.4 |
| `ac4faaf`, idle, never played since launch | 0.78% | 3.67% | 7 | 203 MB | — | — |
| with fixes, paused | **0.12%** | 3.33% | 6 | 207 MB | 0.2 | 0.1 |
| renderer fed by its callback, paused mid-track (12:10) | 0.20% | 3.67% | 11 | 168 MB | 0.1 | 0.3 |
| receiver, MacBook Air speakers, paused mid-track (13:24) | 0.18% | 6.83% | 8 | 175 MB | 0.2 | 0.1 |

The `ac4faaf` idle run started 20 s after launch and probably still includes the home
page loading; its trace (0.56%) is the better figure. Nearly all of it, as in 1.2.7,
is the main thread: 158 ms per 30 s for `ac4faaf` and 128 ms for 1.2.7, against 47 ms
with the fix.

`coreaudiod` sits at 3.3–3.7% with Spotifly paused, so that much comes from other
clients; playback adds 0–3.5 points on top.

### Decoding and decryption on their own

`micro/run.sh`, four minutes of ffmpeg-encoded Vorbis at about 250 kbps:

| Flags for the vendored libvorbis | Decode time | Real-time factor |
|---|---|---|
| `-Os` (Xcode's Release default) | 293 ms | 820× |
| `-O2` | 277 ms | 867× |
| `-O3` | 279 ms | 859× |
| `-O3 -mcpu=apple-m1` | 278 ms | 864× |
| `-Ofast -mcpu=apple-m1` | 281 ms | 853× |
| `-O3 -flto -mcpu=apple-m1` | 277 ms | 866× |

About 0.12% of one core whatever the flags, and the differences between flag sets
were within run-to-run noise (a second run ordered them differently). Inside the app, decoding Spotify's own
streams on the decode thread comes to 0.6–0.8% of a core, so the test file, from
ffmpeg's experimental encoder, understates the work; either way the flags make no
difference worth having.

AES-128-CTR through CommonCrypto: 18–21 GB/s, which is the ARMv8 AES instructions (a
software implementation manages a few hundred MB/s). A whole track decrypts in about 0.5 ms.

### Feeding the renderer

[`renderer/run.sh`](cpu-benchmark/renderer/run.sh) `[<git revision>] [pause]` builds the
app's `AudioRenderer.swift`, from the working tree or from a revision, into a small
program that plays -120 dB noise through it, fed the way the pipeline feeds it
(`legacy.swift` drives revisions from before the receiver), and reports the 60 s after a
10 s settle. With no Spotify,
UI or login involved, it separates the renderer's own cost from everything else.

What `AVSampleBufferAudioRenderer` needs, measured through it on macOS 27: it holds
about 1.25 s of audio, and asks for more through `requestMediaDataWhenReady` when down
to about 0.72 s, then takes about 0.53 s: roughly two callbacks a second.

The branch had been doing far more than that. It fed the renderer from a 25 ms timer,
and the decode thread slept after every 2048-frame chunk (46 ms) once it was 2 s ahead:
about 60 timers a second. The timer had replaced the callback in `a6b9e12`, which said
the callback re-invoked itself back to back. It does, but only while it returns with the
renderer still wanting data, and an empty ring has to stop it rather than return. The
code before `a6b9e12` did that. The same commit moved decoding off the cooperative pool,
and that is what freed the transport controls.

So the callback fed the renderer again, and the decode thread slept until half a second
under its limit, then decoded half a second at once (`3bdc11e`). Its sleep was a semaphore
wait that `stop()` cut short, so a seek or a skip, which joined the thread, did not wait
it out. On the renderer alone, three runs each, alternating, same output:

| Renderer | Idle wakeups/s | CPU | Energy impact |
|---|---|---|---|
| timer (`8f8aab3`) | 28.3–31.7 | 1.42–1.47% | 2.8–2.9 |
| callback and burst writes | 0.7–0.9 | 1.15–1.20% | 1.1–1.2 |

The callback alone took it to 10.1 wakeups a second; the burst writes did the rest.
In the app the rest of the process adds to that, but not much: 2.1 a second while
playing, against 19–26 before (see [Playing](#playing)).

**A pause dropped audio.** The write throttle measured wall-clock time since playback
started, pauses included. During a pause the decode thread went on filling the ring
until it was full, then dropped the rest of its chunk: 0, 43 and 46 ms missing after
three 4 s pauses in the harness, counted with a counter added to the drop path.
Afterwards it had "fallen behind" and ran ahead of the throttle for the rest of the
track, held back only by the full ring. The throttle's clock now stands still while
playout is stopped, and the paused decode loop waits on a condition instead of polling
every 50 ms (`7b83a26`). A 50 ms poll on its own measures 8 idle wakeups a second.

**Then the receiver.** macOS 27 deprecates every call above in favour of
`AVSampleBufferAudioRenderer.Receiver`, from `sampleBufferReceiver(adding:)` on the
synchronizer. Its `enqueue(_:) async` suspends until the renderer wants more, so the app
now requires macOS 27 and decodes in a task that awaits each 4096-frame chunk: no ring
buffer, throttle, callback or decode thread. Probed on the renderer alone, the receiver
behaves like this:

- It holds 1–1.9 s and resumes a waiting enqueue about every 0.55 s, taking six chunks.
- While paused (rate 0) the waiting enqueue waits the whole pause, with no wakeups.
  After a flush with the clock held, it still takes about a second, so a paused track
  pre-rolls.
- A flush returns a waiting enqueue at once as `cancelledDueToFlush`. So does cancelling
  the task that waits, paused or not, and the next enqueue then throws
  `CancellationError`.
- Setting the renderer's own `audioOutputDeviceUniqueID` makes the waiting (or the next)
  enqueue return `enqueuedWithSuggestedFlush(wasFlushedAutomatically)`, with an invalid
  flush time. `renderingEventsAfterFinishedEnqueuing` delivered nothing in any test.
- **Changing the system's default output reports nothing.** The deprecated
  `WasFlushedAutomatically` notification still arrives, 130–160 ms after the switch, but
  the waiting enqueue never returns, and the clock runs on over silence (−20 s of lead
  and falling). Flushing and restarting the clock on the same receiver revives it; no
  rebuild is needed. The app detects the stall from the enqueue's side (see the
  changelog) and reloads from the playhead.

Three runs each, alternating, same output (the LG display):

| Renderer | Idle wakeups/s | CPU | Energy impact |
|---|---|---|---|
| callback (`1b169ba`) | 0.9–1.0 | 1.12–1.17% | 1.1 |
| receiver | 0.0 | 0.72–0.73% | 0.7 |

In the app it was measured on the MacBook Air's speakers, which is where the output
happened to be; their Core Audio work is heavier (728 ms per 30 s on the in-process I/O
thread, and `coreaudiod` at 6.8–7.8% even paused), so those rows do not compare with the
LG ones above them. Decoding, now on the cooperative pool, came to 143 ms per 30 s.

## Findings

- **The seek bar ran a timeline while nothing played.** `NowPlayingBarView`'s
  `TimelineView(.animation(minimumInterval: 1))` redrew once a second regardless, at
  about 5 ms of main-thread SwiftUI work per tick — the entire idle CPU of both
  builds. It is now paused while not playing (`e4342d2`).
- **Spatial Audio costs nothing measurable here.** On one output, playing, back to
  back: the build with the opt-in 3.23% app and 5.17% `coreaudiod`, the same build
  with that one line removed 3.27% and 5.17%. The display's speakers are not a device macOS
  spatializes for, so this says nothing about AirPods.
- **More wakeups while playing on the branch** (19–26/s against 17.7/s), from feeding
  the renderer on a 25 ms timer and waking the decode thread for every chunk. Down to
  2.1/s; see [Feeding the renderer](#feeding-the-renderer).
- **Memory:** the branch holds the decrypted file of the current track and of the
  next one, a few MB each. The RSS figures above differ by more than that and move
  with whatever the UI has loaded, so they do not compare the stacks.

## Open

- **Interleaved comparison.** Run 1.2.7 and the branch back to back on the same
  output device and the same stretch of track, then the branch again to see how much
  it drifts. Each switch between the two needs the container alert answered.
- The main thread is now the largest single consumer while playing: 187 ms per 30 s at
  12:07, nearly all of it SwiftUI's and AttributeGraph's own update work, with little
  of the app's code on the stack. What triggers those updates is not yet known.
- An in-app run of the receiver on the LG display, to put beside the 12:07 one.
