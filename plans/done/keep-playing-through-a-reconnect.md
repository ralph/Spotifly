# A reconnect restarts the audio it does not need to touch

Status: **Done** 2026-09-27 (#68). Checked with the `SPOTIFLY_DEBUG_DROP_AP_AFTER` hook.
Components: `Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`runRecovery`,
`attachTransport`), `Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift`
Found: in an hour-long run on `swift-librespot`, before #65 merged

## Summary

Spotify resets the accesspoint socket now and then. Recovery threw the audio pipeline away and
reloaded the track, although the track was in memory and needed nothing from the socket: about
0.16 s of silence, then about a second heard twice. Nothing was broken; it was a hiccup that
could be taken out. The pipeline now stays through a reset and asks the session for its socket
each time it needs an audio key.

## Problem

### What happens

In the run, Spotify's accesspoint (`ap-gew4`) reset the connection twice, at 15:37:59 and
15:40:00 CEST, and then held for the remaining 45 minutes. The second reset came two minutes
after the reconnect, when the first keep-alive was due. Our pongs are answered: the "unknown"
packet that arrives every two minutes is, by its timing, the server's acknowledgement of our
pong (librespot's `PongAck`, 0x4a, which `PacketType` does not name). So this looks like the
server's side.

Each time the session was back within about 1.3 s, and playback came back by itself:

```
15:37:59.006 LibrespotSession] Transport lost
15:38:00.359 SpircController] SPIRC ready
15:38:00.359 LibrespotClient] No longer the active device (now: nobody)
15:38:00.359 AudioPipeline] Stopping
15:38:00.411 LibrespotClient] Recovery reloading spotify:track:16DOlkOPWHFjxIaMVqyNAt at 11239ms
15:38:00.526 AudioRenderer] Restarted
15:38:00.526 LibrespotClient] Recovery succeeded
```

The audio did not stop when the socket died: the track was already downloaded and
decrypted, and the renderer went on playing it. It stopped when the recovery threw the
pipeline away. What is heard:

- **about 0.17 s of silence**, from `Stopping` to `Restarted`;
- **a short repeat**, about 0.3 s, because `resumeAt` is read before reconnecting and the
  audio played on while the reconnect ran;
- **other devices see nothing playing for a moment**: `SpircController.shutdown` sends the
  goodbye PutState on transport loss, and the new session's registration answers with no
  active device until the reload reports again.

Until `3164c14` the first track change after a recovery was not gapless either, because the
new pipeline had not been told the next track.

### Why the pipeline is rebuilt

`AudioPipeline` is created with the session's `Accesspoint` and `SPClient` as `let`s, and
`attachTransport` builds a new one after every reconnect: "the old pipeline would keep asking
the corpse for audio keys". The accesspoint is needed only for a track's audio key; the
current track, and the next one once fetched ahead, need nothing from it.

## Solution

### Proposal

Keep the pipeline and swap what it fetches with.

1. `AudioPipeline.reattach(accesspoint:spclient:)`: replaces the two and the
   `AudioKeyProvider`, and drops a fetch-ahead that was in flight on the old socket (it would
   fail anyway) so the tick fetches it again.
2. `attachTransport` calls it when a pipeline exists and builds one only on the first login.
3. `runRecovery` reloads only when the pipeline has nothing loaded, and otherwise just
   reports the state again so the cluster sees this device active. The wake-from-sleep path
   goes through the same recovery
   ([wake-from-sleep-loses-queue-and-resume.md](wake-from-sleep-loses-queue-and-resume.md)),
   so test that too.

Then a reset mid-track is inaudible, and the seconds of fetch-ahead survive it.

The goodbye on transport loss can stay: librespot's Spirc does the same when its session
ends unexpectedly while active (`handle_disconnect`, then `delete_connect_state_request`), and
the reconnect's first report makes this device active again within the second.

To test: a reset cannot be forced from Spotify's side, so drop the accesspoint socket from a
debug hook (`SPOTIFLY_DEBUG_DROP_AP_AFTER=<s>`, alongside the other `SPOTIFLY_DEBUG_*`) and
listen for the gap, then check the log for no `Stopping` and a gapless next boundary.

## Verification

### Result

Implemented as proposed; the hook is `SPOTIFLY_DEBUG_DROP_AP_AFTER`. Before the change it
reproduced the run above: `Stopping`, then a reload at a position read before the reconnect.
After it, three runs:

- **Mid-track, with the fetch-ahead due during the outage.** The fetch started over the dead
  socket and failed; the recovery kept the track playing (`Recovery kept … playing`, no
  `Stopping`), the device was active again 46 ms after the reconnect, the fetch was made again
  over the new socket, and the next track followed without a gap.
- **While paused.** Kept paused at 10004 ms and reported paused; resume played from there
  and took the active role back.
- **A pause pressed during the outage was ignored**, and the seek bar froze until the
  reconnect. That was `PlaybackViewModel`, not the pipeline: it ignored transport controls
  while the session was down (`pause() ignored - session not connected yet`) and pinned the
  position, on the assumption, from librespot's days, that a lost session means stopped audio.
  The Swift pipeline played on through an outage before this change too, until the recovery
  replaced it. Fixed alongside: commands for this device go to the local player whether or
  not the session is up, and only another device's position holds while it is down.

- **A Next pressed during the outage left nothing playing** once the guard above was gone
  (found by Codex, reproduced with the hook). The next track was not in memory yet, its key
  request failed on the dead socket, the load cleared the local state, and the recovery,
  starting a second later, had nothing to restore. So step 1 changed shape: instead of
  `reattach` swapping the key source, `AudioKeyProvider` asks the session for its socket on
  every request and waits out a reconnect, up to 15 s. The Next then played its track 150 ms
  after the reconnect, and a fetch-ahead started during the outage completed with one
  download instead of being fetched twice. The recovery keeps whatever the pipeline has
  loaded or is loading, and reloads only when it was stopped, as after sleep.

One run waited 5 s for `ap-gew4.spotify.com:4070` to time out before the next accesspoint
answered, so an outage lasted 6.5 s where it is usually 1.3 s. Inaudible now.
