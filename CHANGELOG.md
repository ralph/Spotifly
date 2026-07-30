# Changelog

All notable changes to Spotifly will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Simplified the code this branch had grown over ~20 incremental commits, with no behavior change: **949 lines removed, 503 added**. In Rust, two helpers replace a callback-invocation dance repeated 13 times (`registered_callback` copies the pointer out and drops the slot lock before returning — a callback must never run holding it, since it re-enters Swift; `send_json` folds serialize-and-hand-over), a `spirc_command` helper collapses six near-identical command wrappers, `c_string_arg` folds the null-and-UTF-8 check at seven FFI entry points, and the two mirror-image queue loops become one `collect_queue_items`. Comments left stale by the soft-reconnect removal were rewritten rather than deleted, and `create_new_player` no longer returns a `Result` it could never fail with. In Swift, `decodeJSONObject` absorbs the nil/UTF-8/parse preamble repeated across six JSON callbacks, and `sendTransportCommand` replaces the active-device-versus-remote branch duplicated across six transport methods — returning `Bool` so the optimistic UI updates that follow still run only when the command was actually issued. Deliberately untouched: the publish-once ordering in `init_player_async`, the generation predicates, every main-actor hop in the bridge callbacks, and `AudioRenderer.start()`'s re-anchor path. The crate now also compiles warning-free
- Replaced soft reconnect with a single recovery strategy: tear everything down and rebuild Session, Player, Mixer and Spirc as one generation, then restore the captured intent (re-activate if Spotifly was the active device, auto-resume if it was playing). Soft reconnect kept the Player alive across sessions to avoid an audible gap, but a Player outliving the Session it was built for is what forced most of the surrounding complexity: the librespot patch making Spirc adopt an orphaned `play_request_id`, a context reload after every reconnect (with its seek-to-position blip), and a watchdog that re-issued play commands when the audio key fetch on the dead session silently timed out. A brief gap during a network outage is the better trade. This removes `soft_reconnect_async`, `do_soft_reconnect_cleanup`, the `Player::set_session` path, the pending-play watchdog and the whole `PendingPlay` bookkeeping that existed only to feed it — **194 lines deleted, 11 added**. The rebuild path is not new code: it was already the fallback whenever soft reconnect failed
- Extracted the reconnect and active-device decisions in the Rust layer into pure functions (`should_recover_after_deactivation`, `should_recover_after_cluster_end`, `is_active_in_cluster`, `teardown_in_progress`) and added the first unit tests the crate has ever had. The rules that decide whether a disconnect is a real outage or an ordinary Connect handoff were previously inline conditions inside a 3000-line event loop, reachable only by running the app against a live Spotify session — so the distinction that caused the reconnect-on-handoff bug could not be verified at all. Eight tests now cover it, including that deactivation alone does not reconnect, that a dead session does, that sleep and shutdown always suppress recovery, that only the current session generation's cluster listener may act, and that an empty active-device ID clears activity. Run with `cargo test` in `rust/`
- Consolidated the Rust connection snapshot behind a single lock. `session_connected`, `session_connection_id`, `spirc_ready`, `device_id`, `reconnect_attempt`, `last_error`, and `connected_since_ms` previously lived in six independent globals (three mutexes and three atomics), and `build_connection_state_info` assembled a snapshot by locking them one at a time — so a published snapshot could mix values from different transitions (ready from one, connection metadata from another). They now live in one `Mutex<ConnectionState>` reached through a `with_connection` helper, which makes every snapshot internally consistent by construction and removes five globals
- Unified the Swift-side connection-state decoding. The payload was parsed twice with duplicated permissive dictionary code — once in the push callback, once in `getConnectionState()` — where a renamed or missing field silently became `false`, `0`, or `""` and was indistinguishable from a genuinely disconnected session. Both paths now share one `Decodable` decode with required fields non-optional, so schema drift is logged as a decode failure instead of manufacturing plausible state. `LibrespotConnectionState` is declared `nonisolated` at the type level (not just per-property) because the project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise give it a main-actor-isolated conformance the C callbacks can't use — this is what the previous hand-rolled parsing was working around
- Removed the dead `StateUpdateCallback` FFI surface. Rust registered and fired it on track changes, but the Swift handler only wrote a debug log, so it was pure indirection: `STATE_UPDATE_CALLBACK`, `spotifly_register_state_update_callback`, the emission site, the `typedef` in `spotifly_rust.h`, and the Swift registration and handler are all gone
- **Spotifly now builds against official librespot — the patched fork is retired.** The queue APIs the fork originally added (`PlayerEvent::SetQueue`, `QueueTrack`, `ConnectConfig::emit_set_queue_events`, `Spirc::add_to_queue`, `Player::set_session`) had all been upstreamed, and the two behavioral patches that remained turned out to be artifacts of the old soft reconnect, which kept the Player alive across sessions: `play_request_id` adoption by definition, and `play_status.is_playing()` empirically — a full rebuild syncs `connect_state` from the load intent, so the window where the two could disagree no longer exists. Verified against unpatched `dev` @ `9c7d756`: a real outage (`Connection to server closed`), a full session rebuild, a position-accurate resume, and an unattended track transition that loaded the next track with `start_playing = true`. `rust/Cargo.toml` keeps its `path` dependencies with **no revision pin**, deliberately — the build compiles whatever is checked out in `../librespot`, so trying a local librespot patch is a checkout and a rebuild. The trade-off is that the build follows that checkout silently, so `git -C ../librespot log --oneline -1` is the first thing to check when behavior looks odd. `rust/build.sh` now only verifies the checkout exists, so a missing sibling repo reports itself instead of surfacing as a confusing Cargo resolution error
- Sidebar refresh toward the Claude redesign: the brand block now shows the real app icon (instead of an SF Symbol), the Queue and Albums entries use updated glyphs (`text.line.first.and.arrowtriangle.forward` and a disc), a Settings entry that opens the native macOS Preferences window sits above the profile, and the profile link now has a brighter card background with a border
- Refactored the logged-in shell so `NavigationCoordinator` now owns section selection, library detail selection, drill-down path, and back/forward history, with toolbar, lifecycle, and column routing extracted out of `LoggedInView`
- Migrated `RecentlyPlayedService` and `TopItemsService` to the stored-unstructured-`Task` dedup pattern used by the other library services, and persisted both via `@State` in `LoggedInView`, so their loads survive caller `.task` cancellation and can't get stuck on the `isLoading` guard. `TopItemsService` keys its in-flight tasks by pagination key path so top artists and top tracks dedup independently
- Unified token-refresh handling into a single `KeychainManager.refreshAndPersist` policy used by both the launch path (`loadAuthResultWithRefresh`) and the runtime session (`SpotifySession`), eliminating two divergent refresh implementations and centralizing the 5-minute refresh buffer as `SpotifyAuthResult.refreshBufferSeconds`
- Hardened the Rust FFI C header (`spotifly_rust.h`): replaced magic return/event integers with typed C enums (`SpotiflyResult` for the `0/-1/-2/-3` command convention, `SpotiflyAudioControlEvent` for audio control events) and added nullability annotations (`#pragma clang assume_nonnull` plus explicit `_Nullable` on `spotifly_free_string`, `spotifly_get_connection_state`, and the audio-data callback). The audio-control switch in `SpotifyPlayer` is now exhaustive over the shared enum, removing the hand-duplicated `audioControl*` constants. ABI is unchanged (enums use fixed `int32_t`/`uint8_t` underlying types), so no Rust rebuild is required

### Fixed
- The playback position no longer jumps to a stale value and back after a reconnect. Readiness was published the moment Spirc existed, while activation and the rehydrating load still had to run. Swift reacts to that publication by bootstrapping from the Web API, so it fetched and applied a server snapshot — in one measured case 145010 ms with a timestamp 144 seconds old — which Rust then overwrote 300 ms later with the real position of 99240 ms. `init_player_async` now builds a complete session and publishes its readiness exactly once, at the end: Spirc created, device activated, playback rehydrated, *then* announced. The activation path records its state without publishing (`store_active_device`) for the same reason, since publishing between activation and rehydration would reopen the same window. Chosen over the alternative of having Swift skip the Web API when playing locally, because that keys off state which is still settling at that moment — activation lands 483 ms after the bootstrap fires — and it would still have gone wrong for a track that was paused when the outage hit
- Playback no longer races after a reconnect. `AudioRenderer` paces the decoder by comparing audio written against wall clock since an anchor, because `AVSampleBufferAudioRenderer` accepts data eagerly and provides no real-time back-pressure. That anchor is reset in `start()` — but `start()` returns early when it is already rendering, and dropping the `Player` during a rebuild never ran `Sink::stop`, so the renderer kept believing it was rendering and the anchor survived the whole outage. On resume the throttle saw a large accumulated deficit, never slept, and let the decoder run flat out: measured at ~40 seconds of audio in under one second. Playback still *sounded* continuous because the renderer plays its buffer out in real time, but `EndOfTrack` fired ~40 s early and Spirc advanced the track with the audio still playing. Fixed on both sides — Rust now sends a stop when tearing a player down, and `start()` re-anchors the throttle even when it returns early (only the anchor, since a full pipeline reset mid-playback would glitch the audio)
- A dead session is now noticed even when Spotifly isn't the active device. Every existing recovery trigger needs something to happen: the cluster listener only acts when its stream *closes*, and librespot's dealer retries internally so that stream can stay open for minutes past a dead session; the zombie check in `require_session_connected` only runs when a command is issued. While Spotifly is playing, something trips one of those within seconds. While playback is on another device, nothing does — no commands are issued, so nothing calls `mark_disconnected`, so the published snapshot still reads "connected" and the Swift reconnect watchdog never arms either. Observed in testing: after a real outage with playback on a phone, the session stayed silently dead for 1m43s and only recovered because the machine happened to sleep and wake. A periodic check now polls `Session::is_invalid()` once a minute and starts the normal recovery when it finds a dead session. It costs one sleeping task per session generation waking once a minute to read two booleans, and exits when its generation is superseded, so it dies with the session it belongs to
- Playback now actually resumes after a reconnect. The rebuilt Player has no track loaded, and nothing else loads one — Spirc coming up ready and the device becoming active again only makes it *available* to play. So the session returned healthy and completely silent, while the UI kept showing the pre-outage track and position because `IS_PLAYING` and the position anchor survive the rebuild. The recovery path now issues one deterministic load of the captured context, seeking to the captured position, when playback was local and running before the outage. This replaces a five-second "auto-resume" window that waited for a `Paused` event on the assumption that the track would load itself via `transfer(None)` — nothing in that path ever called `transfer(None)`, so the event never arrived and the window did nothing. It went unnoticed because the rebuild was previously only the fallback for a failed soft reconnect, which kept the Player playing on its own
- Automatic recovery from a network outage now actually retries. Two bugs, both found by unplugging ethernet mid-playback. First, the reconnect loop invalidated itself: each attempt calls `init_player_async`, which bumps the session generation *before* it can fail, so the loop's supersede check compared against the value captured at loop start, saw its own rebuild as a foreign takeover, and abandoned after a single failed attempt — with the Player already torn down by the preceding cleanup, playback then stayed dead for the whole outage. The loop now adopts the generation its own attempt produced, so only genuinely foreign rebuilds and teardowns stop it. Second, the schedule was a fixed ten attempts totalling about three minutes, after which the loop exited entirely; any longer outage left nothing running to notice the network returning, and only the Swift watchdog's 120-second forced reinitialize — or a manual play — could recover it. Backoff now caps at 30 seconds and keeps retrying. This is not idle polling: the loop exists only while disconnected and exits on any lifecycle event, since every iteration re-checks the generation and the teardown flags
- Recovery is now generation-safe, closing a race where Swift and Rust could end up on different session generations. Two problems: the player event listener's stale-session check compared `EVENT_LISTENER_GENERATION` against `SESSION_GENERATION`, but the former was written to the latter's new value on every bump — so the two were always equal and the check could never reject anything. And the reconnect loop was guarded only by a `RECONNECTING` flag, which says "a loop is running", not "the thing it is fixing still exists": it could sleep up to 30 seconds between attempts, wake after a manual restart or a logout had already rebuilt or torn everything down, and rebuild over the top with a stale token. Each listener now captures its own generation (possible only because a rebuild replaces the listener along with its session — the old global existed because soft reconnect kept one listener alive across sessions), the reconnect loop abandons if its generation moved or a teardown started, checked both after each backoff sleep and after the token round-trip, and `spotifly_cleanup` invalidates the generation up front so anything in flight notices. `EVENT_LISTENER_GENERATION` is gone. Five new unit tests cover the rules
- Fixed a "Publishing changes from background threads is not allowed" runtime warning, and the thread-safety hole behind it. The Combine subjects bridging Rust callbacks into Swift are `nonisolated(unsafe)` globals reached from Rust's own threads, and only three of the eleven callbacks hopped to the main actor before sending — the other eight relied on every subscriber remembering `.receive(on: DispatchQueue.main)`. That unwritten invariant broke as soon as a SwiftUI `.onReceive` subscribed to the connection snapshot, because `.onReceive` delivers on whatever thread the publisher emits on. All non-audio callbacks now hop first, which also closes a real hazard a subscriber-side hop never could: several Rust tasks (player event listener, cluster listener, reconnect loop) can publish concurrently, and Combine subjects are not safe against concurrent `send` — `.receive(on:)` hops only *after* the subject has already delivered. Audio data keeps its separate real-time-safe path
- Initialization no longer reports success before the player is usable. `PlaybackViewModel` set `isInitialized` as soon as the FFI initializer returned, then polled `isSpircReady` for five seconds and ignored the timeout — so Swift could permanently believe the player was up while every Connect command failed, and `initializeIfNeeded` would then refuse to retry because the flag was already true. Readiness is now the authoritative condition (session connected **and** Spirc ready), a timeout is treated as failure, and the flag stays false so the next caller retries. On the Rust side, `spotifly_init_player` no longer falls back to a bare `session.connect()` when Spirc initialization fails: every Spotifly control goes through Spirc, so a connected session without one is not a player, and returning success for it was what made the unusable state permanent
- A stale Web API response can no longer overwrite newer state from Rust. `fetchInitialPlaybackState` fetched playback and queue data and applied both unconditionally when the requests completed, but Rust callbacks can arrive while those requests are in flight — so after a reconnect or transfer Swift could briefly show the correct live state and then replace it with an older network snapshot. `AppStore` now carries a monotonic `liveStateRevision` that is bumped whenever authoritative playback or queue state from Rust is accepted; the bootstrap captures it before issuing its requests and discards the response if it moved. One counter covers both playback and queue: it is coarser than tracking them separately, but the only cost is occasionally dropping bootstrap data that the live callbacks are already replacing. Provisional `SetQueue` notifications deliberately do not bump it, since they carry no usable queue and the Web API refresh they schedule must not be treated as stale. This replaces relying on the Web API `timestamp`, which was only ever used to compensate the position anchor *within* a response and was never compared against anything Rust had published
- Whether Spotifly is the active Connect device is now one derived fact instead of two competing ones. Rust tracked it in an `IS_ACTIVE_DEVICE` atomic written from fourteen scattered command and event sites and never reconciled against the cluster, while the cluster listener separately pushed the active device ID to Swift's `AppStore` — so playback routing (which read the atomic) and the views (which read the store) could disagree about whether Spotifly or a remote speaker was active, especially around external transfers. The cluster listener now computes `is_active = cluster.active_device_id == own_device_id` (the same comparison `SpircTask` makes internally) and publishes it in the connection snapshot, so both readers see the same value. Also: an empty active-device ID is no longer dropped, so "nothing is playing anywhere" clears the state instead of leaving the last active device shown forever; and `PlayerEvent::Stopped` no longer clears active-device state, which had made local playback simply ending look like a remote device taking over
- Swift no longer drives reconnection or Web API refetches from Connect activation. The two FFI callbacks are renamed to what they actually report (`spotifly_register_became_active_callback` / `..._became_inactive_callback`, surfaced as `SpotifyPlayer.becameActive` / `.becameInactive`), and `LoggedInLifecycleModifier` now keys off readiness transitions in the connection snapshot instead. Previously the activation callback triggered a full `fetchInitialPlaybackState`, so **every** device handoff fired an unguarded Web API bootstrap that could overwrite live Rust state — the most likely cause of Swift and Rust disagreeing about what was playing — while the deactivation callback armed a watchdog that would force a full reinitialize. Both now fire only on genuine connect/disconnect transitions, and the initial rise to ready is skipped because startup already bootstraps once
- The deactivation callback no longer doubles as a reconnect-failure signal. It was fired both by Spirc (meaning "another device took over", immediately) and by the reconnect loop after all ten attempts were exhausted (meaning "recovery gave up", late), so one callback carried two unrelated meanings with wildly different timing. Exhaustion is now reported only through the connection snapshot, which already carries `last_error` and the attempt count
- Handing playback off to another Spotify device no longer looks like a network outage. librespot emits `SessionDisconnected` when the local Connect device becomes **inactive**, not when the session fails — `SpircTask::handle_disconnect()` runs on an explicit disconnect, on shutdown, and on any cluster update that gives the active role to another device (this is upstream behavior, not part of the Spotifly patch). Rust treated every one of those as a dead session: it marked the connection disconnected and started a reconnect loop against a perfectly healthy session, so playing to a phone or speaker could show a disconnected UI and fire an unnecessary reconnect. The event now updates active-device state only, and recovery starts solely from real transport evidence — a `Session` that reports itself invalid, the cluster/dealer stream ending, or an explicit force-reconnect. The session-validity check preserves the one genuine failure this event does report (librespot calls `handle_disconnect` when the Spirc task shuts down unexpectedly, which the cluster listener can miss while the dealer stream is still open)
- The connection snapshot's "connected" facts now come from the point where the connection is actually established. `connected_since_ms`, the reconnect backoff counter, and `last_error` were reset in the `SessionConnected` handler, which fires on Connect *activation* and can happen repeatedly over one healthy session; they now reset where the session and Spirc are created. `SessionConnected` only records the connection id and marks the device active
- Player initialization and restart are now serialized through one stored `Task`. `forceReinitialize` and `initializeIfNeeded` both ran `SpotifyPlayer.initialize`, which performs a Rust cleanup followed by a rebuild — and `@MainActor` prevents them running simultaneously but not overlapping, since every `await` is a suspension point another caller can enter. Two overlapping calls could interleave one call's cleanup with the other's rebuild, leaving Swift holding state for a Rust generation that had already been replaced. Late callers now await the in-flight run instead of starting a competing one, which also coalesces the genuinely concurrent triggers: system wake and the reconnect watchdog can fire together, and one rebuild is the correct response to both. The two near-duplicate bodies collapsed into one, and `isInitialized` is cleared up front so a restart whose `initialize()` throws no longer leaves the flag stuck true
- Playback commands no longer report success for actions Rust rejected. Three paths bypassed the connectivity guards that `next`/`previous`/`pause`/`resume`/`toggleShuffle` already had: `togglePlayPause` called the unguarded `SpotifyPlayer.pause()` FFI wrapper directly and asserted `isPlaying = false` itself (instead of routing through the view model's guarded `pause()`, which also carries the Web API fallback for remote devices and leaves the flag to the Mercury callback); `stop()` cleared track and playing state even when the session was down; and `performSeek` had no guard at all, so during a short outage the progress bar stayed parked at a position playback never reached. `performSeek` now re-syncs the anchor from the real position when the command can't be sent, which keeps scrubbing feedback immediate without lying about the result
- Transferring playback to another device no longer reports success unconditionally. `DeviceService.transferPlayback` optimistically marked the target active and returned `true` while the FFI call ran detached and its `SpotiflyResult` was discarded, so a rejected transfer (no session, invalid session, SpClient failure) left the device list showing a device that never became active. The two transfer wrappers now return whether Rust accepted the command, and a rejected transfer rolls the optimistic update back to the previous active device and returns `false`
- Opening a playlist no longer fails for newer/stricter Spotify developer accounts. `fetchPlaylistTracks` was still calling the deprecated `GET /playlists/{id}/tracks` endpoint, which Spotify now rejects with `403` for apps approved after the API tightened — `fetchPlaylistDetails()` would succeed but the tracks fetch failed, so the whole playlist appeared broken even though the playlist list loaded fine. Switched to `GET /playlists/{id}/items` (the documented replacement) and added pagination via the response's `next` URL, since the new endpoint caps at 50 items per page versus the old endpoint's 100
- Opening a playlist for the first time no longer occasionally fails with a cancellation error. `PlaylistDetailView` lives in the list+detail split that appears when Playlists switches from 2 to 3 columns, so the detail view could be recreated mid-fetch, re-triggering its `.task` and firing a second, untracked `fetchPlaylistDetails` request; when the original view was torn down its in-flight request was cancelled and the surviving view surfaced that as an error. `PlaylistService.fetchPlaylistDetails` now dedups in-flight requests per playlist ID via a stored `Task` (matching the pattern used by `AlbumService`/`ArtistService`/`PlaylistService`'s own user-playlists load), so a re-triggered `.task` awaits the existing request instead of racing a new one
- Playlist, album, and artist rows in the sidebar lists are now clickable across their full width instead of only over the cover art and label. The rows were full-width `Button`s with `.buttonStyle(.plain)`, but on macOS that style's hit-testing doesn't reliably honor `.contentShape(Rectangle())` over a transparent `Spacer()` region — clicks only registered over the actual rendered image/text content even though the row's layout and selection highlight already spanned the full width. Replaced the `Button` wrapper with a plain `HStack` plus `.onTapGesture(perform:)`, which does respect `contentShape` consistently
- Restored the always-visible search field in the top toolbar. A previous refactor had switched it to the `.searchable(text:isPresented:)` variant, which hides the field unless `isPresented` is true (and it defaulted to false), so the field had disappeared. It is again attached to the `NavigationSplitView` as a plain `.searchable(text:)`, visible in every section
- Reworked the logged-in window layout to an Apple Music-style hierarchy: a single, stable two-column `NavigationSplitView` (sidebar | content region). The 2- vs 3-column variation now happens *inside* the content region (a single section view, or a list + detail `HSplitView`), so the sidebar column is never recreated — its width stays put across every section switch and no longer snaps between per-layout defaults. The now-playing bar is overlaid on the content region, so it centers over column 2 (or columns 2+3) without the previous sidebar-width math
- Volume changes during local playback now take effect immediately instead of lagging by up to ~2 seconds. Volume was applied by librespot's software mixer in Rust, baking the gain into PCM that then sat in the render buffer, so changes were only heard once that buffer drained. The Rust player now uses `NoOpVolume` (no sample attenuation) and gain is applied at the output via `AVSampleBufferAudioRenderer.volume`, which scales audio as it plays. The slider value is passed through librespot's default logarithmic taper (`VolumeCtrl::Log`, 60 dB) so the perceived curve is unchanged, and the soft mixer still tracks the logical volume so Spotify Connect reporting and remote volume control are unaffected
- Favorites no longer intermittently render the empty "No favorites yet" state despite the `/me/tracks` request firing. The load was tied to the Favorites view's `.task`, so when the view was recreated (navigation/column-layout change) mid-request the in-flight load was cancelled, and a recreated view's `.task` could observe `isLoading == true` and bail — leaving the list stuck empty until a manual refresh. `TrackService.loadFavorites` now uses the stored-unstructured-`Task` dedup pattern (matching `AlbumService`/`ArtistService`) so the load survives caller cancellation, and `TrackService` is persisted via `@State` in `LoggedInView` so the in-flight task reference survives view recreation
- Handle Spotify's upcoming refresh-token expiration (refresh tokens expire after six months starting July 20, 2026): `invalid_grant` responses are now detected as a distinct `SpotifyAuthError.tokenRevoked`, the stored token is discarded instead of retried, and an expired/revoked token mid-session now invalidates `SpotifySession` and routes the user back to the sign-in flow rather than silently looping on a dead access token
- Starting song radio from the currently playing track now seeks with the same interpolated playback position the UI uses, avoiding stale-position jumps when the radio context loads
- Fixed the Now Playing overlay (menu bar) not updating when a song auto-advances during album/playlist playback
- Favorites now resolve via batched `/me/tracks/contains` checks for the tracks actually shown in album, playlist, queue, search, and now-playing views instead of depending on a full favorites preload
- Saving and removing favorite tracks now uses Spotify's saved-tracks endpoint correctly, so heart toggles persist again across Spotify clients
- Clicking Favorites in the sidebar now loads the favorites list automatically again, and the first real favorites fetch replaces any optimistic placeholder entries instead of appending to them
- Navigation history is now tracked consistently across sidebar section switches, library detail selections, and pushed search destinations, with shared back/forward controls in the content toolbar
- Back/forward history restores no longer depend on a next-runloop reset flag; history recording is now suppressed until the exact restored snapshot is reached
- Search-result drill-down navigation now stores track IDs instead of full track payloads, so back/forward history does not retain large copies of search result arrays
- The navigation coordinator API no longer exposes ignored section/selection context parameters, and card/caller plumbing for those dead arguments has been removed
- Navigation history cleanup: removed the trivial back wrapper and documented why section switches clear the visible stack before history snapshots are recorded

## [1.2.5] - 2026-03-11

### Added
- French localization (merci [@statisticalyquiet](https://github.com/statisticalyquiet)! 🇫🇷🥐)
- Shuffle mode

### Fixed
- Fix silent failure (no audio) when playing a new album/playlist immediately after the previous one ends, if a network reconnect races the track load (audio key timeout left player in a broken state with no context)

## [1.2.4] - 2026-03-06

### Fixed
- Fix connecting to Spotify Connect enabled speakers
- Bug fixes and performance improvements

## [1.2.3] - 2026-02-27

### Changed
- AirPlay audio routing rewritten to use `AVAudioEngine` with a custom `AudioRenderer` for more reliable AirPlay device support
- Spotify Connect session stability improvements: better soft reconnect handling, reduced playback jolts during network recovery
- Use 300px album art instead of 640px across the app — reduces download size and eliminates OS-side JPEG transcode overhead in Now Playing (largest display size is 200pt)

### Fixed
- Mini player mode no longer breaks when a fullscreen notification triggers a window state change
- Significantly reduced CPU usage during playback: split Now Playing metadata updates into full vs position-only paths, lowered seek bar update frequency, stopped unnecessary drift-check writes, and removed redundant per-second `currentPositionMs` updates (~94% reduction in active CPU samples vs 1.2.2)

## [1.2.2] - 2026-02-08

### Added
- Context-aware track playback: double-tap a track in an album, playlist, or favorites to play from that position within the context (thanks [@vitbashy](https://github.com/vitbashy)!)

### Changed
- Adapt to [Spotify Web API breaking changes (February 2026)](https://developer.spotify.com/documentation/web-api/references/changes/february-2026): migrate removed endpoints, update playlist response structure, and replace batch fetches with parallel individual requests

### Fixed
- Double-tapping a queue track when playing radio (no context URI) no longer silently does nothing — falls back to single track playback
- Clicking a track card in search results before any playback has occurred now properly initializes the player first

### Removed
- Artist top tracks section (endpoint removed by Spotify with no alternative)
- New Releases section (endpoint removed by Spotify with no alternative)
- Artist follower counts, user email/country/follower display (fields removed from API responses)

## [1.2.1] - 2026-02-06

### Added
- 🎉 Spotify Connect support — Spotifly now shows up as a real Spotify Connect device
- Seamless playback transfer between Spotifly and other Spotify devices (phone, desktop, etc.)
- Automatic session reconnection with exponential backoff

### Changed
- All playback controls (play, pause, seek, volume, next, previous) now go through Spotify Connect for proper state sync across devices

### Fixed
- Remote playback state (queue, position, track) now shows immediately on launch
- Playback state updates correctly in the UI when controlled locally

## [1.2.0] - 2026-01-12

### Added
- User-facing README with screenshots, download links, and setup guide
- DEVELOPMENT.md with architecture and build documentation
- Images directory with screenshots for GitHub page

### Changed
- Releases now published to main repo (ralph/spotifly) instead of homebrew-spotifly
- Updated release process documentation in CLAUDE.md

## [1.1.7] - 2026-01-09

### Added
- Queue editing: Edit queue like playlists with drag-and-drop reordering and track removal
- Fixed queue header with song count, scroll-to-current button, clear queue button, and edit mode toggle
- Only unplayed tracks can be reordered or removed from the queue
- Real-time queue updates: when player advances during editing, track is automatically removed from edit list
- New Rust FFI functions for queue manipulation: `spotifly_remove_from_queue`, `spotifly_move_queue_item`, `spotifly_clear_upcoming_queue`

## [1.1.6] - 2026-01-07

### Changed
- Client ID is now mandatory: removed optional toggle, users must provide their own Spotify Client ID
- Added link to setup instructions on login screen
- Added note about using existing Spotify apps with the required redirect URI

## [1.1.5] - 2026-01-07

### Added
- Custom Client ID support: Users can now provide their own Spotify Client ID on the login screen via a checkbox and input field, useful for working around Spotify API restrictions

## [1.1.4] - 2026-01-05

### Added
- Streaming quality preferences (Normal, High, Very High) in Preferences window
- Sleep-proof token refresh: tokens are now validated lazily on-demand instead of background timers

### Fixed
- Fixed favorite indicator not updating correctly after toggling
- Fixed token expiration handling when Mac wakes from sleep

## [1.1.3] - 2026-01-05

### Changed
- Use market from OAuth token instead of hardcoded US for proper regional content
- Optimized album loading: reduced page size and prevented duplicate fetches
- Moved service state to centralized AppStore for consistent architecture
- Reduced artist pagination limit to 20 for better performance

### Fixed
- Fixed artist pagination issues
- Auto-select first item in library list views for better UX

## [1.1.2] - 2026-01-04

### Fixed
- Mini player bugfixes and performance improvements

## [1.1.1] - 2026-01-04

### Added
- Playlist management (edit, rename, delete, reorder tracks)

### Fixed
- Bug fixes and performance improvements

## [1.1.0] - 2026-01-03

### Added
- 3-dot context menu on tracks with actions:
  - Play Next
  - Add to Queue
  - Start Song Radio
  - Go to Artist
  - Go to Album
  - Share (copies link to clipboard)
- Like/Unlike current track with Cmd+L keyboard shortcut
- Menu bar entries for all keyboard shortcuts (Playback and Navigate menus)
- Heart indicator on tracks showing favorite status

### Fixed
- Bug fixes and performance improvements

## [1.0.1] - 2026-01-02

### Fixed
- Fixed crash on login in release builds by embedding Spotify client credentials in the app bundle

### Changed
- Updated build process to automatically inject credentials from environment variables

## [1.0.0] - 2026-01-01

### Added
- Lightweight Spotify player for macOS using librespot
- Recently played tracks, albums, artists, and playlists
- Queue management with drag-to-reorder
- Playback controls with progress bar
- Search functionality across tracks, albums, artists, playlists
- Favorites management
- Mini player mode
- AirPlay support
- Native macOS app with Spotify Web API integration
