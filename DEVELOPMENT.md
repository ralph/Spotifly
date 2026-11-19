# Development Guide

How Spotifly is put together, and how to build, run and debug it.

## Architecture

Spotifly is a SwiftUI app with no dependencies outside Apple's SDKs. It plays no audio
itself: Spotify's Soloist, which it downloads from Spotify and runs as a child process, is
this Mac's player. Everything else it needs from Spotify — signing in, the library, search
and Spotify Connect — it speaks itself, in Swift.

```
 SwiftUI views ── view models ── AppStore + services (Store/)
                                      │
   ┌──────────────────┬───────────────┴──────┬──────────────────────────┐
   │                  │                      │                          │
   Auth/              PartnerAPI/            SpotifyPlayer (facade)     Soloist/
   one OAuth grant,   pathfinder GraphQL,    │                          SoloistEngine runs
   loopback redirect  spclient REST and      SwiftLibrespot/            Spotify's Soloist,
                      connect-state          LibrespotClient            the player, as a
                      commands               └── LibrespotSession       child process
                                                 ├── DealerConnection (WebSocket)
                                                 └── SpircController (hidden device)
```

| Where | What it does |
|---|---|
| `Spotifly/Auth/` | One OAuth grant (PKCE) against Spotify's own desktop client id, redirected to a one-shot listener on a loopback port. That single token is the bearer for every HTTP API and the dealer; tokens live in the keychain. |
| `Spotifly/PartnerAPI/` | The APIs Spotify's own clients use: pathfinder GraphQL at `api-partner.spotify.com` for the library, search and pages, and spclient REST. Every play, transport command and transfer goes over spclient's connect-state (`SpclientAPI.swift`). The public Web API is not used. |
| `Spotifly/Store/` | The normalized `AppStore` and the services that fill it, and `PlayerModel`, which holds what the UI shows of the player — see `AGENTS.md`. |
| `Spotifly/SpotifyPlayer.swift` | The static facade over `LibrespotClient.shared`: the session's lifecycle, transfers, and the tracks an album or playlist queues as. The client publishes its state as snapshots, which `PlayerModel` applies on the main actor. Plays and commands do not go through it: `PlaybackViewModel` sends them over connect-state, to the active device or to Soloist. |
| `Spotifly/Soloist/` | `SoloistEngine` runs Spotify's Soloist, the only player, as a child process, with the key the user enters in Settings → Playback, from Spotify's Soloist dashboard. `SoloistInstaller` downloads it from Spotify and checks that Spotify signed it. Soloist is a Connect device like any other; its loopback WebSocket only says whether it is paired. See `plans/done/soloist-playback.md`. |
| `Spotifly/SwiftLibrespot/` | Spotify Connect, as a controller. A Swift port of [librespot](https://github.com/librespot-org/librespot)'s protocol handling, which is where the type names come from. It plays nothing. |
| `…/Core/`, `…/Public/` | `LibrespotSession` owns the dealer and Spirc for one login. `LibrespotClient` mirrors the cluster into `PlayerSnapshot`s, with the device list, and recovers the session after sleep or a lost connection. |
| `…/Network/` | `APResolver`, for the dealer and spclient endpoints, and `SPClient`, spclient's context resolver, which says what tracks an album or playlist queues as. |
| `…/Dealer/`, `…/Connect/` | The dealer WebSocket, which pushes the cluster and whose requests are answered without being acted on, and `SpircController`, which registers this session's hidden device and keeps it on the cluster with a heartbeat. |
| `…/Proto/` | A small hand-written protobuf reader and writer, and the messages built with it. |

## Prerequisites

- Xcode 27 or later, for the macOS 27 SDK
- macOS 27 or later
- A Spotify Premium account, and a key from Spotify's Soloist dashboard for Settings →
  Playback, to play on this Mac

## Building

Open `Spotifly.xcodeproj` and build (⌘B), or:

```bash
xcodebuild -scheme Spotifly -destination 'platform=macOS' build
```

The unit tests:

```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES
```

They run inside the app (`TEST_HOST`). Hosting them, it opens an empty window and does not sign
in, so a test run leaves the Debug app you have open, and its Connect device, alone.

Format Swift before committing:

```bash
swiftformat --swiftversion 6.4 .
```

## Running and debugging

Debug builds log to stderr through `debugLog`, which compiles away in Release. Run the
binary directly to read it, and filter by module — `AGENTS.md` lists the prefixes:

```bash
"$(xcodebuild -scheme Spotifly -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Spotifly.app/Contents/MacOS/Spotifly" 2>&1 | grep -E 'Soloist|SpircController'
```

Debug builds also read a few environment variables that drive playback without the UI:

| Variable | Effect |
|---|---|
| `SPOTIFLY_DEBUG_AUTOPLAY=1` | Plays a fixed album about 5 s after launch; a `spotify:` uri instead of `1` plays that |
| `SPOTIFLY_DEBUG_PAUSE_AFTER=<s>` | With autoplay: pauses after that long, resumes 6 s later |
| `SPOTIFLY_DEBUG_NEXT_AFTER=<s>` | With autoplay: skips twice, that far apart |
| `SPOTIFLY_DEBUG_QUEUE_AFTER=<s>` | Queues a track, then an album |
| `SPOTIFLY_DEBUG_OPEN=<uri>` | Opens a `spotify:album:`, `spotify:artist:` or `spotify:playlist:` page, for an id nothing in the app leads to |
| `SPOTIFLY_DEBUG_DEVICE_ID=<id>` | Registers the hidden device under another id, so a second instance is a second controller |
| `SPOTIFLY_DEBUG_TRANSFER_TO=<name>` with `SPOTIFLY_DEBUG_TRANSFER_TO_AFTER=<s>` | Hands playback to the named device |
| `SPOTIFLY_DEBUG_REINIT_AFTER=<s>` | Rebuilds the session as Speakers → Reconnect does, and logs the bar's track before and after |
| `SPOTIFLY_DEBUG_RESUME_AFTER=<s>` | Presses Play, as the bar's button does: a resume on the active device, or with none, a transfer of the last playback to Soloist |

Connect only shows its problems with a second device, such as Spotify's web player. A
second instance under `SPOTIFLY_DEBUG_DEVICE_ID` is not a second player: it runs Soloist
from the same folder, and stops the first instance's Soloist to start its own.

Three things to know about signing in:

- **One grant per account.** Spotify keeps a single live refresh token per account and
  client id, and rotates it on every refresh. Anything else signed in with the same
  client id — Spotifly on another Mac, a probe — revokes this one's when it refreshes, and
  the app then signs out.
- **Release and development builds share a data container.** A Developer ID build and a
  locally signed one have different signatures, so whichever runs second makes macOS ask
  whether it may use the other's data, and it sits waiting on that alert.
- **Soloist signs in on its own**, through Connect pairing: choose "Spotifly" once in the
  Spotify app on a phone on the same network. It keeps that login in its data folder,
  `~/Library/Application Support/Spotifly/Soloist/`.

## Performance

[`docs/cpu-benchmark.md`](docs/cpu-benchmark.md) records where the CPU went while
playing and while paused with the built-in player, which is gone. Soloist now plays in its
own process.
