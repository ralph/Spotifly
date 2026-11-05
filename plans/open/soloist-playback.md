# Spotify Soloist as the playback engine

Status: **Open**, draft. Decided on 2026-11-05: Spotifly drops the App Sandbox. The rest of
the direction is not agreed, and the live pairing probe (step 1) has not run. Researched
2026-11-02 against Soloist 1.3.10.35 (macOS build of 2026-11-02); Spotifast's setup and the
Homebrew cask checked 2026-11-03 (1.3.10.37, built that day).
Components: proposed new `Spotifly/Soloist/` (manager, WebSocket client, setup);
`Spotifly/ViewModels/PlaybackViewModel.swift` (`playbackTarget`), `Spotifly/SpotifyPlayer.swift`,
`Spotifly/PartnerAPI/ConnectState.swift`, `Spotifly/Views/SpeakersView.swift`,
`Spotifly/Views/PreferencesView.swift`, `Spotifly/KeychainManager.swift`; for leaving the
sandbox, `Spotifly/Spotifly.entitlements`, `Spotifly.xcodeproj/project.pbxproj`,
`Spotifly/SpotiflyApp.swift`, `Spotifly/SwiftLibrespot/Core/StoredCredentialsStore.swift`,
`RELEASE.md` and `../homebrew-spotifly/Casks/spotifly.rb`
Found: 2026-11-02, after Spotify shipped Soloist for Apple Silicon Macs. Spotifly's own audio
path depends on audio keys that Spotify refuses for some accounts (#223, librespot#1649).

While this plan is a draft, change it through discussion. Once it is agreed, keep Summary and
Solution stable: put findings and proposed changes under "Implementation notes", with
reasons. Work inside the agreed scope can go on; a change that crosses an agreed boundary
pauses the affected work until it is agreed. The PR that finishes the work moves this file
to `plans/done/`.

## Summary

Spotify Soloist is Spotify's own headless Spotify Connect receiver. It ships for Linux, Apple
Silicon macOS 13+ and Windows. It plays with Spotify's own engine, including lossless, and
needs no audio keys from us. It is the only playback route Spotify publishes for third-party
clients.

Soloist only plays. It has no search, library or playlists. So this plan replaces the
**playback** half of Spotifly and keeps browsing on Pathfinder and spclient. A client that
uses no reverse-engineered API at all is not reachable today; "Why not fully official"
explains why.

Proposed shape:

1. Spotifly downloads Soloist from Spotify's CDN after the user consents. It never bundles
   it.
2. Spotifly runs Soloist as a child process with a loopback WebSocket.
3. Spotifly treats Soloist as a Connect device it owns: it starts playback through the
   existing remote path, and reads lifecycle and pairing state from the WebSocket.
4. The Swift librespot engine stays as the fallback.

A sandboxed Spotifly cannot run Soloist from any install location (probes below), and
Spotifast works because it is not sandboxed. So Spotifly drops the App Sandbox (decided
2026-11-05) and moves its data out of the container once.

One decision still blocks making Soloist the default: **AirPlay.** Soloist plays only to the
system's default output.

## Problem

Spotifly's audio path requests AES keys over the accesspoint. Spotify refuses them for some
accounts. Per librespot#1649, newer accounts get no keys at all; in #223 a reporter's account
was refused while the same files played on Ralph's. Nothing on our side can change Spotify's
answer, and the path is reverse-engineered end to end.

Soloist solves this with Spotify's own engine. The questions this plan answers are what
Soloist covers, what it does not, and what Spotifly has to change to use it.

## Solution

### What Soloist provides (from the docs and the macOS build)

- **Process.** It is one executable, `soloist`. Spotify signs it with its Developer ID
  (team `2FNC3A47ZF`, identifier `com.spotify.soloist`), with the hardened runtime and no
  entitlements, and notarizes it (`codesign --test-requirement="=notarized"` passes).
- **Download.** The macOS build is `soloist-builds.spotifycdn.com/soloist_release_osx_arm64.tar.gz`
  (10.7 MB; it holds `soloist`, `CHANGELOG.md` and `THIRD_PARTY_LICENSES.txt`). The URL
  never changes, and Spotify publishes no checksum list.
- **Expiry.** Each build expires 90 days after its build date. An expired build exits with
  code 10. `--version` prints the build date.
- **Redistribution.** The docs forbid redistributing the archives or binaries and ask apps
  to link to Spotify's download page instead.
- **Command line.** `-n` sets the device name and `-k` the API key; both are required.
  `-D`/`-C` set the data and cache directories. `-w 127.0.0.1:0` enables the WebSocket; the
  chosen port is written to `<data>/ws.port`. `-i` sets the initial volume (default 40).
  `--pair` pairs and exits; `--single-track` plays one URI and exits. The key can only be
  given as an argument (soloist#12, #24). Any local user can read it: on macOS, `ps` shows
  other users' arguments too (checked on 2026-11-02: root's appear for an ordinary user).
- **Login.** Soloist only logs in through Spotify Connect pairing: the user picks the
  device once in an official Spotify app (phone or desktop). It never asks for a password or
  opens a browser. The session is stored in the data directory and restored on later starts.
  The key's account needs Premium. According to the README, once Soloist runs, Free and
  Premium accounts can both connect to it. That would let Free accounts play in Spotifly,
  which the built-in engine cannot do. Not tested.
- **WebSocket.**
  - Commands: `play` (optional `uri`: track, album, playlist or episode), `pause`,
    `skip_next`, `skip_prev`, `seek`, `set_volume`, `set_shuffle`, `set_repeat_context`,
    `set_repeat_track`, `add_to_queue` (tracks only), `activate`, `deactivate`, `get_state`,
    `get_queue` (a `limit` of 0 returns every entry), `get_auth_state`.
  - Events: `auth_state`, `playback_state`, `track_changed`, `playback_changed`,
    `context_changed`, `options_changed`, `volume_changed`, `device_changed`,
    `queue_changed`, and `position_sync` (a position, timestamp and speed: the same anchor
    model as ours). Items carry their name, covers, parent, creators and duration.
  - Not supported: starting a context at a given row (soloist#9, open), inline track lists,
    and removing, reordering or clearing queue entries. The socket has no authentication,
    so it must be bound to loopback.
- **Audio.** Soloist plays through Core Audio to the system's default output. Linux has
  `--pipewire-device` to choose an output; macOS has no equivalent.
- **Features.** Lossless up to 24-bit/44.1 kHz, loudness normalization, crossfade,
  automix, Jam, podcasts and audiobooks.

### Probes run on 2026-11-02

1. **The Soloist key is not a Web API credential.** Sent as a Bearer token to
   `/v1/me`, `/v1/search`, `/v1/tracks/{id}` and `/v1/me/player/devices`, it got 401
   "Missing/invalid/expired access token" each time. As a client id, `client_credentials`
   with and without a secret got 400 `invalid_client`. The docs agree: the key is only used
   to start the program and to prove the device during Connect login.
2. **A sandboxed app cannot run the Soloist it downloads.** The probe was a command-line
   tool signed with Spotifly's sandbox entitlements (`app-sandbox`, `network.client`,
   `network.server`). Results:
   - Downloading with URLSession and unpacking with `/usr/bin/tar` both worked. Every file
     got `com.apple.quarantine` (flags `0086`, agent `sbprobe`).
   - `posix_spawn` of the downloaded `soloist` failed with `EPERM`. The kernel log shows
     two refusals:
     - the sandbox: `deny(1) process-exec*` on the container path;
     - quarantine: "exec … denied since it was quarantined by sbprobe; and created without
       user consent".
   - `removexattr("com.apple.quarantine")` from inside the sandbox failed with `EPERM`.
   - A copy placed in the container from outside, with no quarantine, was also refused with
     `deny(1) process-exec*`.
   - `/usr/bin/true` started normally.

   So the sandbox refuses to run any binary in the container, and quarantine is a second,
   separate refusal on top of that.
3. **Installing Soloist outside the container does not help** (2026-11-03, same entitlements,
   Soloist 1.3.10.37). `posix_spawn` failed with `EPERM` for each of these:
   - `/opt/homebrew/bin/soloist`, from the Homebrew cask (quarantined by Homebrew);
   - the same binary at its `Caskroom` path;
   - Spotifast's copy in `~/Library/Application Support`, which has no quarantine.

   `/usr/bin/true` started normally. So a sandboxed Spotifly cannot start Soloist from any
   install location.

### Prior art: Spotifast

Spotifast (`../spotifast`) ships this integration on Linux, macOS and Windows since 0.15
(`docs/_reference/soloist.md`, `src/soloist/`, about 4,700 lines including native audio):

- **No sandbox.** Spotifast 0.17.0 is signed with a Developer ID and the hardened runtime,
  and has no entitlements, so it has no container. Its downloaded `soloist` has no
  quarantine attribute. macOS quarantines every file a sandboxed app writes. An unsandboxed
  app's own downloads are quarantined only if it sets `LSFileQuarantineEnabled`. This is
  why the download and launch work there.
- **Download and updates.** It downloads from the CDN after the user enters a key, and
  stores the key in the system credential store. In the build's last 30 days it checks daily
  for a newer build, and swaps it in only while the player is inactive.
- **Integrity.** After `--version` succeeds, it stores the build under
  `builds/<sha256>/` and checks that digest before each reuse. It does not check Spotify's
  code signature (`src/soloist/install.rs`).
- **Process.** It runs one child with `--ws 127.0.0.1:0` and keeps the child's output in a
  private log with the key removed.
- **Pairing.** Setup shows the exact device name to pick in the official Spotify app. The
  device must appear in the account's device list before Spotifast controls it.
- **Control.** Basic commands and state go over the WebSocket. "Collection starts keep their
  offset through the existing playback request": the Web API's start-playback call.
- **Queue editing.** It is not offered while Soloist plays.
- **Mac audio.** A Core Audio process tap reroutes the child's audio through Spotifast's EQ
  and visualizers. It needs macOS 14.2+ and the "System Audio Recording" permission
  (`NSAudioCaptureUsageDescription`).
- **Positioning.** Its docs say plainly that the integration claims no endorsement from
  Spotify and bypasses no DRM.

Music Assistant also downloads Soloist from Spotify after the user consents, renews it, and
warns that Spotify's terms do not clearly allow this use.

### Why not fully official

**The Web API cannot carry Spotifly's browsing.** Since February 2026, new Development Mode
apps have these limits (each user would register their own app):

- Premium is required, and each app takes at most five users.
- `GET /playlists/{id}/items` works only for playlists the user owns or collaborates on.
  Discover Weekly, Spotify's own playlists and other people's playlists return metadata
  without tracks.
- These endpoints are gone: the batch `GET /tracks`, `/albums` and `/artists`;
  `/browse/new-releases`; `/browse/categories`; `/artists/{id}/top-tracks`; `/users/{id}`
  and `/markets`.
- Search returns at most 10 results per page.
- `linked_from`, `popularity` and `available_markets` are no longer in track responses, and
  `product` and `country` are no longer in `/me`.

Apps created since November 2024 also get no related artists, recommendations or audio
features. Spotifast meets these limits and still reads those things over its librespot
session.

**The Developer Policy (§III.11) rules out the product itself.** It forbids products that
replicate or try to replace a core Spotify experience, whichever API they use. Using Soloist
makes the audio path official; it does not make Spotifly a sanctioned client.

### Proposed design

**Leaving the sandbox** (decided 2026-11-05). This lands as the first PR, before any Soloist
code. Nothing visible changes except where the files live.

- **Build settings.** Set `ENABLE_APP_SANDBOX = NO` in both configurations. Remove
  `app-sandbox`, `network.client`, `network.server` and `files.user-selected.read-only` from
  `Spotifly.entitlements`, and remove the matching `ENABLE_*_NETWORK_CONNECTIONS` and
  `ENABLE_USER_SELECTED_FILES` settings. Keep the hardened runtime and
  `keychain-access-groups`.
- **What moves.** Without a container, `UserDefaults` uses
  `~/Library/Preferences/rvdh.Spotifly.plist`, and Application Support is the user's own.
  Keychain items are not in the container, so they stay. The keychain checks the app's
  signing identity (team and bundle id), which does not change.
- **The stored login moves to the Keychain.** `StoredCredentialsStore` keeps a reusable
  login in `credentials.json`, and its comment relies on the container to protect it.
  Outside the container, any process of the user can read that file. Store the login with
  `KeychainManager` instead, where the keymaster tokens already are.
- **Migration, once at launch,** before anything reads `UserDefaults`:
  1. Skip if a marker key is set, or if `~/Library/Containers/rvdh.Spotifly/Data` does not
     exist.
  2. Copy every key from the container's preferences plist that is not already set. This
     keeps the settings and the Connect device id (`DeviceInfo`); without the id, Spotify
     would see a new device.
  3. Move the container's `credentials.json` into the Keychain.
  4. Set the marker. Caches are not copied.

  If the container cannot be read, skip the migration and log it. The user then signs in
  once more, and the settings start from their defaults.
- **Reading the old container.** macOS 14 and later protect app containers from other apps.
  The shell here cannot read Spotifly's container ("Operation not permitted"). According to
  Apple at WWDC23 (quoted on the developer forums), apps signed by the same team can read
  each other's containers without a prompt. Releases are signed with team `89S4HZY343`, so the migration should work. This
  is not tested; step 2 of Verification checks it.
- **Elsewhere.** `RELEASE.md` says the sandbox is on. The cask's `zap` lists
  `com.spotifly.app` paths, which do not match the bundle id `rvdh.Spotifly`. List the real
  ones: the preferences plist, `~/Library/Caches/rvdh.Spotifly`,
  `~/Library/Application Support/Spotifly` and the old container.
- **No change needed:** the playlist cover picker calls
  `startAccessingSecurityScopedResource()` and already handles `false`, which is what an
  unsandboxed app gets.

**Lifecycle.** A `SoloistManager` owns the executable and the process:

1. Download the archive over HTTPS from the CDN into `Application Support/Spotifly/Soloist/builds/`.
   Unpack it with a bounded extractor that rejects links and paths outside the directory.
2. Check the code signature against
   `anchor apple generic and identifier "com.spotify.soloist" and certificate leaf[subject.OU] = "2FNC3A47ZF"`
   before every launch. A build that fails the check is never run.
3. Read the build date from `--version`. Renew during the last 30 days; swap builds only
   while nothing plays.
4. Launch with:
   - `-n "<device name>"`;
   - `-k <key from the Keychain>`;
   - `-D` and `-C` under `Application Support/Spotifly/Soloist/`;
   - `-w 127.0.0.1:0`;
   - `-i` set to the last volume.

   Read `ws.port`, then connect. Restart the process if it exits unexpectedly. Exit code 10
   means the build expired: renew it. Stop the child when Spotifly quits, and stop a child
   left over from an earlier run before starting a new one.

**Control.** Soloist is a Connect device that Spotifly launched. Spotifly controls it the
way it controls a remote device today:

- **Starting playback** (with a row, a `skip_to`, or an inline track list) goes through
  `ConnectCommand.play` on the existing `.remote(deviceId:)` path in
  `PlaybackViewModel.playbackTarget`. The WebSocket cannot carry these: it has no offset and
  no inline context.
- **State** comes from the dealer's cluster pushes, as for any remote device. The WebSocket
  adds what the cluster cannot say: whether the process runs, whether it is paired
  (`auth_state.logged_in`), and whether it is active.
- **Transport commands** (pause, skip, seek, volume, shuffle, repeat, queue add) can use
  either route. Open decision 3 settles which.

**Engine selection.** One setting chooses the engine: "Spotify Soloist" or "Built-in". With
Soloist chosen, "this Mac" in Speakers is the Soloist device, and the built-in engine does
not play. The built-in engine stays for:

- users who skip setup;
- Soloist outages and expired builds;
- queue editing (open decision 4).

**Setup** has four steps:

1. A link to `developer.spotify.com/dashboard/soloist`.
2. A field for the key, stored in the Keychain.
3. Consent to download Soloist from Spotify.
4. "Choose `<device name>` in the Spotify app on your phone": Spotifly waits for
   `auth_state.logged_in`, then for the device in its own device list.

**Errors to name:** not paired, key refused at login, build expired and renewal failed,
download failed, and process crashed.

### Alternatives considered

| Option | For | Against |
| --- | --- | --- |
| Soloist + keep Pathfinder (proposed) | Official audio, no audio keys, lossless; browsing unchanged | Browsing stays reverse-engineered; drops the App Sandbox; AirPlay decision |
| Soloist + Web API, user's own client id | Every interface official | Loses the tracks of playlists the user doesn't own, home, top tracks and batch reads; quota; §III.11 still applies |
| Keep the built-in engine only | No new dependency | #223-class refusals stay unfixable; no lossless |
| Bundle Soloist in the app | No download step | Forbidden by Spotify; builds expire after 90 days anyway |
| User installs Soloist (homebrew/cask has `spotify-soloist`) and runs it | Sandbox untouched; Spotifly's cask could `depends_on` it | A sandboxed Spotifly can't start it (probe 3), so users start it and fix the port by hand; `brew upgrade` skips `:latest` casks without `--greedy`, so the 90-day renewals fall to users |

**Bringing back the Web API** is not proposed. If a later step needs it, write a thin async
client for the endpoints actually used, starting from the one deleted in f09b996 (about 2,760
lines), updated for the February 2026 renames:
`/playlists/{id}/tracks` → `/items`, and `/me/tracks` etc. → `/me/library`.

Peter Schorn's SpotifyAPI is not a fit:

- It is Combine-only: 263 `AnyPublisher` returns and no async API, with `swift-tools-version`
  5.6.
- It still calls the `/me/tracks` endpoints that new apps cannot use.
- It has an open PKCE refresh bug (#77).
- It was last changed in May 2026.

### Open decisions

1. **Sandbox: decided on 2026-11-05, drop it.** "Leaving the sandbox" above has the design.
   The options were:
   - **Drop the App Sandbox** (chosen). This is the simplest, and Spotifast does the same.
     Spotifly ships through the Homebrew cask, so nothing requires the sandbox. The cost is
     moving the container's data once.
   - **Embed an unsandboxed helper** (an XPC service or login item) that downloads, checks
     and launches Soloist, so the app stays sandboxed. Sparkle uses this pattern for
     Developer ID apps. It was not probed.

   Probe 3 ruled out a third way: installing Soloist somewhere else. What the choice gives
   up: Soloist runs unsandboxed either way, so the sandbox protected only Spotifly's own
   code, such as the built-in engine's C Vorbis decoder, which parses data from the
   network.
2. **AirPlay (blocks a default switch, not an opt-in engine).** Soloist cannot use
   Spotifly's AVPlayer route. The options are:
   - (a) the user sets the Mac's output to AirPlay;
   - (b) a Core Audio process tap feeding Spotifly's AVPlayer path, as Spotifast does for
     its EQ. This needs a permission, adds latency, and is a grey area;
   - (c) ask Spotify for a macOS output option like `--pipewire-device`.

   The proposal is (a) plus filing (c), with the built-in engine kept for AirPlay until one
   of them works.
3. **Transport over the WebSocket or connect-state.** The WebSocket is official and local.
   Connect-state is already built and is the only route for starts with an offset. The
   proposal: connect-state for everything first, because it is one path and already tested;
   move to the WebSocket where it has the same command.
4. **Queue editing while Soloist plays.** Soloist has no remove or reorder. Either hide
   these controls, as Spotifast does, or try connect-state's queue writes on Soloist's
   device (unverified).
5. **Two Connect devices.** Spotifly registers its own Connect device to send commands. With
   Soloist running, other apps see both "Spotifly" and the Soloist device. Decide whether
   Spotifly's own registration can be hidden or not playable.

## Verification

### Step 1: live pairing probe (manual, no app code)

This needs Ralph's phone. Keep the volume low and keep playback off WohnzimmerStereo.

1. Run the downloaded `soloist` by hand with `-n "Spotifly Soloist Test" -i 10 -w 127.0.0.1:0`.
   Give it its own `-D`/`-C` in the scratchpad.
2. Pair from the Spotify app on the phone.
3. Check that the device appears in the installed Spotifly's Speakers list.
4. From Spotifly, play a playlist from a middle row (`skip_to`), an inline track list, and a
   queue add; then pause, seek and skip. Note what Soloist does and what its WebSocket
   reports.
5. Play from the phone instead, and record what the WebSocket reports while Soloist is not
   the active device.
6. Note which output Soloist uses when the Mac's output is the HomePod.
7. If a Free account is available, check whether it can pick the paired device and play.

This step settles open decisions 3 and 4 and part of 2.

### Step 2: leaving the sandbox (manual, with a release-signed build)

The migration depends on how the build is signed, so test it with an archive signed with the
Developer ID, not with a Debug run beside the installed app.

1. Start from the installed sandboxed release, signed in, with a non-default volume and
   bitrate.
2. Note Spotifly's device in the Spotify app's device list.
3. Replace `/Applications/Spotifly.app` with the unsandboxed build and start it.
4. Check: no permission prompt; still signed in; volume and bitrate kept; no second Spotifly
   device in the device list.
5. Check that `~/Library/Application Support/Spotifly/credentials.json` does not exist.

A release build does not log (`debugLog` compiles away), so these observations are the
result.

### After implementation

Tests:
- the migration: keys copied only where unset, the marker, the stored login moved, and an
  unreadable container skipped;
- the parser for every documented WebSocket event;
- the archive extractor (rejects links and paths outside the directory);
- the signature check (rejects a re-signed binary);
- the expiry date parsed from `--version`;
- the engine choice in `playbackTarget`.

Manual run:
- setup from a clean state;
- pairing, then a restart that restores the session;
- a play from a row in a playlist;
- an expired build (simulate with exit code 10);
- killing the child mid-track.

### Implementation notes

None yet.
