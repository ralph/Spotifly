# Development Guide

How Spotifly is put together, and how to build, run and debug it.

## Architecture

Spotifly is a SwiftUI app with no dependencies outside Apple's SDKs except two C
libraries it vendors for Ogg Vorbis decoding. Everything else it needs from Spotify —
signing in, the library, search, playback and Spotify Connect — it speaks itself, in
Swift.

```
 SwiftUI views ── view models ── AppStore + services (Store/)
                                      │
        ┌─────────────────────────────┼──────────────────────────────┐
        │                             │                              │
  Auth/                        PartnerAPI/                    SpotifyPlayer (facade)
  one OAuth grant,             pathfinder GraphQL and               │
  loopback redirect            spclient REST                  SwiftLibrespot/
                                                               LibrespotClient
                                                               ├── LibrespotSession
                                                               │   ├── Accesspoint (TCP, Shannon cipher)
                                                               │   ├── DealerConnection (WebSocket)
                                                               │   └── SpircController (Connect state)
                                                               └── AudioPipeline ──▶ AudioRenderer
```

| Where | What it does |
|---|---|
| `Spotifly/Auth/` | One OAuth grant (PKCE) against Spotify's own desktop client id, redirected to a one-shot listener on a loopback port. That single token signs in to the accesspoint, which hands back credentials for reconnecting, and is the bearer for every HTTP API; tokens live in the keychain. |
| `Spotifly/PartnerAPI/` | The APIs Spotify's own clients use: pathfinder GraphQL at `api-partner.spotify.com` for the library, search and pages, and spclient REST. The public Web API is not used. |
| `Spotifly/Store/` | The normalized `AppStore` and the services that fill it, and `PlayerModel`, which holds what the UI shows of the player — see `AGENTS.md`. |
| `Spotifly/SpotifyPlayer.swift` | The static facade the app sends playback commands through, backed by `LibrespotClient.shared`. The client publishes its state as snapshots, which `PlayerModel` applies on the main actor. |
| `Spotifly/SwiftLibrespot/` | Playback and Spotify Connect. A Swift port of [librespot](https://github.com/librespot-org/librespot)'s protocol handling, which is where the type names come from. |
| `…/Network/` | Accesspoint resolution, the TCP connection with its Diffie-Hellman handshake and Shannon cipher, and the spclient HTTP client (metadata, `storage-resolve`, connect-state). |
| `…/Dealer/`, `…/Connect/` | The dealer WebSocket, and `SpircController`, which publishes this device's state to the Connect cluster and turns remote commands into player calls. |
| `…/Audio/` | `AudioPipeline`: metadata, then the audio key (over the accesspoint) and the CDN URL side by side, the download, AES-128-CTR through CommonCrypto, and Vorbis decoding into the `AudioRenderer`, a chunk at a time, each one awaited. The next track is fetched ahead and, with gapless playback on, decoded straight after the current one. |
| `…/Proto/` | A small hand-written protobuf reader and writer, and the messages built with it. |
| `Spotifly/AudioRenderer.swift` | The output: `AVSampleBufferAudioRenderer` on a render synchronizer, fed through its macOS 27 receiver, whose `enqueue` suspends until it wants more audio — the only pacing there is. It keeps AirPlay 2 and Spatial Audio working. |
| `Spotifly/Vendor/` | libogg 1.3.5 and libvorbis 1.3.7, unmodified, compiled by Xcode — see `Vendor/README.md`. |

## Prerequisites

- Xcode 27 or later, for the macOS 27 SDK
- macOS 27 or later
- A Spotify Premium account to play anything

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
"$(xcodebuild -scheme Spotifly -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Spotifly.app/Contents/MacOS/Spotifly" 2>&1 | grep -E 'AudioPipeline|SpircController'
```

Debug builds also read a few environment variables that drive playback without the UI:

| Variable | Effect |
|---|---|
| `SPOTIFLY_DEBUG_AUTOPLAY=1` | Plays a fixed album about 5 s after launch; a `spotify:` uri instead of `1` plays that |
| `SPOTIFLY_DEBUG_PAUSE_AFTER=<s>` | With autoplay: pauses after that long, resumes 6 s later |
| `SPOTIFLY_DEBUG_NEXT_AFTER=<s>` | With autoplay: skips twice, that far apart |
| `SPOTIFLY_DEBUG_QUEUE_AFTER=<s>` | Queues a track, then an album |
| `SPOTIFLY_DEBUG_OPEN=<uri>` | Opens a `spotify:album:`, `spotify:artist:` or `spotify:playlist:` page, for an id nothing in the app leads to |
| `SPOTIFLY_DEBUG_DEVICE_ID=<id>` | Registers under another Connect device id, so a second instance is a second device |
| `SPOTIFLY_DEBUG_ACCOUNT_TYPE=free` | Runs the account as that type, as if the accesspoint had named it: `free` hides this Mac from Connect and turns its playback off |
| `SPOTIFLY_DEBUG_TRANSFER_HERE_AFTER=<s>` | Pulls playback to this instance |
| `SPOTIFLY_DEBUG_TRANSFER_TO=<name>` with `SPOTIFLY_DEBUG_TRANSFER_TO_AFTER=<s>` | Hands playback to the named device |
| `SPOTIFLY_DEBUG_DROP_AP_AFTER=<s>` | Drops the accesspoint socket that long after login, as a reset from Spotify does |
| `SPOTIFLY_DEBUG_REINIT_AFTER=<s>` | Rebuilds the session as Speakers → Reconnect does, and logs the bar's track before and after |
| `SPOTIFLY_DEBUG_RESUME_AFTER=<s>` | Presses Play, as the bar's button does; on another device's track, mirrored, that takes it over |

Connect only shows its problems with a second device: another instance under
`SPOTIFLY_DEBUG_DEVICE_ID`, or Spotify's web player.

Two things to know about signing in:

- **One grant per account.** Spotify keeps a single live refresh token per account and
  client id, and rotates it on every refresh. Anything else signed in with the same
  client id — Spotifly on another Mac, a probe — revokes this one's when it refreshes, and
  the app then signs out.
- **Release and development builds share a data container.** A Developer ID build and a
  locally signed one have different signatures, so whichever runs second makes macOS ask
  whether it may use the other's data, and it sits waiting on that alert.

## Performance

[`docs/cpu-benchmark.md`](docs/cpu-benchmark.md) records where the CPU goes while
playing and while paused, against 1.2.7, the last release before the Swift stack, with
the scripts to repeat it.
