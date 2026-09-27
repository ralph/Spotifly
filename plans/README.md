# Plans

What each plan is, and whether it is live. Reviewed 2026-08-15; updated 2026-09-27 for the
Swift stack on `swift-librespot`, which removed librespot and the Rust layer. Plans from
before that describe components that no longer exist — `rust/`, librespot's `spirc.rs` —
and say so where it matters below.

**A plan is not deleted when it is finished.** Most of these record a fix, its evidence, and
the reasoning behind a rule the code still follows — several are cited from `CLAUDE.md`, and
the fastest way to understand why the app does something odd is usually the plan that made it
do that. What gets deleted is a plan that would mislead someone reading it today.

**Read the status line first.** Two plans here implemented rules that were later *reversed*,
and both look complete at a glance.

## Live work

Ranked. The first five have implementation plans of their own, each on a branch with a draft
PR; the rest are recorded but not planned.

| # | Plan | Why here |
| --- | --- | --- |
| 1 | [unavailable-tracks-skip-the-rest-of-a-playlist.md](unavailable-tracks-skip-the-rest-of-a-playlist.md) | Playback silently drains a whole playlist in half a second. Observed, never investigated |
| 2 | [free-account-exits-the-process.md](free-account-exits-the-process.md) | librespot called `exit()` for a non-premium account. That went with librespot; the Swift stack gets an accesspoint login error (`premiumAccountRequired`) instead, and what the app then shows is untested |
| 3 | [the-reported-position-is-the-decoder-not-the-playhead.md](the-reported-position-is-the-decoder-not-the-playhead.md) | **Resolved by the Swift stack**: `AudioPipeline` reports the renderer's playhead (`AudioSink.playedFramesSinceStart`), not the decoder |
| 4 | [connect-state-put-echoes-itself-into-a-429.md](connect-state-put-echoes-itself-into-a-429.md) | Written against librespot's spirc. `SpircController` has its own PutState path, and the September live runs saw no 429 |
| 5 | [single-grant-partner-api.md](single-grant-partner-api.md) — **Track B only** | **Done on `swift-librespot`**: playback is Swift, with the vendored libvorbis as decoder, and `rust/` is gone |

### Recorded, not planned

- **Playlist writes Spotifly cannot do** — [playlist-attributes-not-written.md](playlist-attributes-not-written.md).
  Reading is complete; only writing cover art and attributes is missing.
- **Playlist folders** — [playlist-folder-hierarchy.md](playlist-folder-hierarchy.md). Deferred
  deliberately: the flat list shows every playlist and is correct, it is just not a tree.
- **Two upstream librespot candidates**, both drafted and neither filed —
  [librespot/upstream-transient-load-failure.md](librespot/upstream-transient-load-failure.md)
  and [librespot/upstream-pr-play-status-is-playing.md](librespot/upstream-pr-play-status-is-playing.md).
  The first is worth filing on its own merits: it makes *any* load failure delete a track
  from the queue permanently. Spotifly no longer runs librespot, so both are upstream
  contributions only, and the first is no longer a suspect for item 1.
- **The refresh button does nothing in the Queue section.**
  `NavigationCoordinator.canRefreshCurrentSection` returns `true` for `.queue`, so the button
  is drawn, but `LoggedInView.refreshCurrentSection` has no `.queue` case and falls through to
  `default: break`. `.speakers` documents its no-op explicitly; queue does not, so this is
  either a missing case or a missing exclusion. Found 2026-08-15.
- **Every keyboard shortcut is registered twice** — once as a hidden zero-size button in
  `Views/KeyboardShortcuts.swift`, once as a menu command in `SpotiflyApp.swift`. Space, ⌘←,
  ⌘→, ⌘L, ⌘1–4 and ⌘F, same actions, ~90 lines. Which copy wins depends on focus semantics
  (Space in the search field versus Space as a menu key equivalent) that only a running app
  settles, so this needs a manual pass rather than a static read. Found 2026-08-15.
- **`QueueItem` and `Track` are two shapes for one thing.** `QueueItem` is the FFI-facing
  struct in `SpotifyPlayer.swift`, `Track` the store entity, and `QueueService` converts
  between them. This is the surviving question from the old `plans.txt`, which asked it of
  four types — `TrackRowData`, `TrackMetadata`, `APIPlaylist` and `SpotifyDevice` have since
  been deleted, and `APITrack` goes with the Web API cleanup, so only this pair is left. Not
  urgent: the conversion is small. The FFI boundary that justified two types went with the
  Rust layer, though, so the case for keeping both is weaker than it was.

## Finished, kept as records

| Plan | Status |
| --- | --- |
| [single-grant-partner-api.md](single-grant-partner-api.md) | **Track A shipped** 2026-08-14 (#49, #51, #53, #54). One grant, no dashboard app, `api.spotify.com` retired. Track B is open — see above |
| [seek-bar-jumps-between-two-position-clocks.md](seek-bar-jumps-between-two-position-clocks.md) | Fixed 2026-08-14, confirmed at runtime across three logs |
| [navigation-one-location-value.md](navigation-one-location-value.md) | Completed. Fixed two navigation tests that had failed for months and were wrongly treated as a baseline |
| [logged-in-view-init-side-effects.md](logged-in-view-init-side-effects.md) | Completed |
| [now-playing-unknown-track-loader.md](now-playing-unknown-track-loader.md) | Completed 2026-07-31 |
| [queue-current-pointer-lags-requested-index.md](queue-current-pointer-lags-requested-index.md) | Completed 2026-08-01 |
| [wake-from-sleep-loses-queue-and-resume.md](wake-from-sleep-loses-queue-and-resume.md) + [-plan.md](wake-from-sleep-loses-queue-and-resume-plan.md) | Fixed and confirmed 2026-08-03. One regression check remains unexercised: another device playing while Spotifly drives it remotely |
| [audio-renderer-throttle-not-reset-on-rebuild.md](audio-renderer-throttle-not-reset-on-rebuild.md) | Fixed and confirmed 2026-07-30 |
| [position-interpolation-runs-on-during-outage.md](position-interpolation-runs-on-during-outage.md) | Fixed and confirmed 2026-07-30 |
| [section-request-pattern.md](section-request-pattern.md) | Completed. Still the reference for the loading pattern `CLAUDE.md` describes |
| [librespot/official-librespot-migration.md](librespot/official-librespot-migration.md) | Done 2026-07-30. The fork is retired |

### Fixed but never confirmed at runtime

Both are believed good and neither has been seen working, because neither reproduces on
demand. The regression signal is a log line, not a reproduction.

| Plan | What is unconfirmed |
| --- | --- |
| [resume-after-deactivation-restarts-the-track.md](resume-after-deactivation-restarts-the-track.md) | Fixed 2026-08-03 (`258f570`). Resume should now log a non-zero seek |
| [stale-cluster-timestamp-parks-the-progress-bar.md](stale-cluster-timestamp-parks-the-progress-bar.md) | Fixed 2026-08-03 (`67a6c16`). Needs a remote device with a cluster timestamp stale enough to overshoot the track end |

### Superseded — do not implement from these

| Plan | What changed |
| --- | --- |
| [web-api-track-relinking-identity.md](web-api-track-relinking-identity.md) | Implemented normalise-to-the-original-id, **reversed 2026-08-13**. Pathfinder carries no `linked_from`, so reconstruction is impossible. `CLAUDE.md` has the rule in force |
| [relinked-track-now-playing-identity.md](relinked-track-now-playing-identity.md) | Same reversal. Its Rust-side half — `Loading`/`Playing`/`Paused` own the logical URI — carried over: the Swift pipeline reports the URI it was asked to play |
| [streaming-auth-implementation-plan.md](streaming-auth-implementation-plan.md) | Shipped as #49, then superseded the same day. It designs **two** grants; there is now one. Its checkboxes were never ticked, so it reads as open and is not |
| [streaming-auth-needs-a-first-party-client-id.md](streaming-auth-needs-a-first-party-client-id.md) | The 2026-08-11 login5 break. Resolved — the shipped fix skips login5 entirely |

## Deleted in this review

- **`plans.txt`** — a prompt from before the partner-API migration. Four of the six types it
  asked about no longer exist, the `SpotifyAPI.fetchQueue` behaviour it described is gone with
  the Web API, and its remaining question is recorded above.
