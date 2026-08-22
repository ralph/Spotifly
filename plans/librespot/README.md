# librespot plans

Everything concerning the `librespot` dependency: the two upstream patch candidates, and the
migration away from the fork, which is **done**.

## Upstream candidates

Two independent findings, unrelated to each other, both to be filed separately against
`librespot-org/librespot`.

| File | What | Status |
| --- | --- | --- |
| [upstream-pr-play-status-is-playing.md](upstream-pr-play-status-is-playing.md) | `handle_next`/`handle_prev` use remote-facing `connect_state` instead of local play intent; plus `play_request_id` adoption for embedders that outlive a Spirc | Draft written, **not filed**. No longer carried anywhere — the fork retired on 2026-07-30 and neither patch is applied |
| [upstream-transient-load-failure.md](upstream-transient-load-failure.md) | A transient network error during (pre)load is reported as `PlayerEvent::Unavailable`, which permanently deletes the track from the queue | Draft written, **not filed**. Affects stock librespot identically — carrying the fork does not avoid it |
| [evidence-track-skip-2026-07-30.log](evidence-track-skip-2026-07-30.log) | Trimmed log capturing the track-skip, from unplugging ethernet mid-playback | Evidence for the above |

## Migration

| File | What | Status |
| --- | --- | --- |
| [official-librespot-migration.md](official-librespot-migration.md) | Moving Spotifly off the fork onto unmodified upstream | **Done, 2026-07-30.** Kept as the record of how it was settled |
| [plan-librespot-removal.txt](plan-librespot-removal.txt) | The original prompt: dropping the Rust layer entirely in favour of HTTPS/CDN playback | Superseded in approach — CDN playback stays, the Web API control path does not — but it is where Track B started |
| [swift-librespot.txt](swift-librespot.txt) | The original prompt: a Swift-native Spirc/Connect implementation | **Still live.** Produced the `origin/swift-librespot` branch, which has the AP handshake, dealer, connect state, spclient and chunked CDN download working |

These two are prompts rather than plans, and they are not dead ends: they are the origin of
**Track B** in [`../single-grant-partner-api.md`](../single-grant-partner-api.md), which is
the live plan for Swift-native playback. Track B is gated on one task — a standalone Vorbis
decoder spike — and if that fails, librespot keeps playing music and `rust/` stays.

## Current dependency state

**The fork is retired.** Spotifly builds against official librespot as of 2026-07-30.

- `rust/Cargo.toml` uses **path** dependencies into `../../librespot`, and there is
  deliberately **no pin**: the build compiles whatever is checked out there, so trying a
  local librespot patch is just a checkout and a rebuild. `rust/build.sh` only checks that
  the directory exists.
- Known-good: official `dev` @ `9c7d756`. When a new librespot release lands, move to that
  release rather than tracking a branch.
- The trade-off of no pin is that the build follows the sibling checkout silently. When
  behavior looks odd, check `git -C ../librespot log --oneline -1` first.

### How the fork question was settled

Verified on 2026-07-30 against unpatched `dev` @ `9c7d756`: a real outage
(`Connection to server closed`), a full session rebuild, position-accurate resume, and an
**unattended** track transition that loaded the next track with `start_playing = true`.
That is precisely what the `play_status.is_playing()` patch was carried for.

Both patches were artifacts of the old soft reconnect, which kept the Player alive across
sessions: `play_request_id` adoption by definition, `play_status.is_playing()` empirically —
a full rebuild syncs `connect_state` from the load intent, so the window where the two
disagreed no longer exists.

Caveat: that is **one** run. Not yet covered — an outage while Spotifly is *inactive*
(playback on another device), where the rehydration path stays passive by design.
