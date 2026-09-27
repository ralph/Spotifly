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

## Setup

- Apple M4, macOS 27.0, Release builds only.
- **Before:** Spotifly 1.2.7 from `/Applications` — the notarized release of
  2026-08-14, identical to the latest GitHub release; librespot in Rust, symphonia
  decoding Vorbis. It sends PCM to the same Swift `AudioRenderer`
  (`AVSampleBufferAudioRenderer`) the branch uses.
- **After:** `swift-librespot` built locally in Release: `ac4faaf` (gapless and
  Spatial Audio in), then the same plus the fixes below (`283fde8`).
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

## Results

### Playing

| Build (time) | App CPU | `coreaudiod` | Threads | RSS | Idle wakeups/s | Energy impact |
|---|---|---|---|---|---|---|
| 1.2.7 (10:26) | 2.37% | 4.50% | 32 | 148 MB | 17.7 | 3.5 |
| `ac4faaf` (10:09) | 1.92% | 6.83% | 13 | 168 MB | — | — |
| with fixes (10:41) | 3.22% | 5.00% | 12 | 196 MB | 19.3 | 4.3 |
| with fixes, track 1 from 0:15 (10:54) | 2.08% | 3.33% | 12 | 212 MB | 25.5 | 4.0 |

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

## Findings

- **The seek bar ran a timeline while nothing played.** `NowPlayingBarView`'s
  `TimelineView(.animation(minimumInterval: 1))` redrew once a second regardless, at
  about 5 ms of main-thread SwiftUI work per tick — the entire idle CPU of both
  builds. It is now paused while not playing (`e4342d2`).
- **Spatial Audio costs nothing measurable here.** On one output, playing, back to
  back: the build with the opt-in 3.23% app and 5.17% `coreaudiod`, the same build
  with that one line removed 3.27% and 5.17%. The display's speakers are not a device macOS
  spatializes for, so this says nothing about AirPods.
- **More wakeups while playing on the branch** (19–26/s against 17.7/s). The branch's
  `AudioRenderer` feeds the renderer from a 25 ms timer, 40 wakeups a second; 1.2.7
  used the renderer's own `requestMediaDataWhenReady` callback. A longer interval, or
  batching the decode thread's writes, would cut them. Not changed yet.
- **Memory:** the branch holds the decrypted file of the current track and of the
  next one, a few MB each. The RSS figures above differ by more than that and move
  with whatever the UI has loaded, so they do not compare the stacks.

## Open

- **Interleaved comparison.** Run 1.2.7 and the branch back to back on the same
  output device and the same stretch of track, then the branch again to see how much
  it drifts. Each switch between the two needs the container alert answered.
- The wakeup reduction above.
