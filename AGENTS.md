# Spotifly

Spotify client for macOS (and maybe later iPad and iOS).

## Tech Stack

- **Language**: Swift 6 language mode with strict concurrency, built with Xcode 27. The app
  target defaults to `@MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION`), so a type
  used off the main actor, or from the test target, needs `nonisolated`
- **Target Platforms**: Latest Apple OSes only — macOS 27 is the deployment target (iOS and
  visionOS are listed at 27 too)
- **UI Framework**: SwiftUI
- **Playback and Spotify Connect**: Swift, in `Spotifly/SwiftLibrespot/`, ported from
  librespot, which is where its type names come from. Ogg Vorbis decoding is the vendored C
  libvorbis in `Spotifly/Vendor/`. `DEVELOPMENT.md` has the architecture.

## Development Guidelines

- Use Swift's strict concurrency features (`Sendable`, `@MainActor`, async/await)
- No backwards compatibility needed - target only the latest OS versions
- Format all Swift code with: `swiftformat --swiftversion 6.4 .`

Also read `AGENTS-twostraws.md` for general development guidelines and best practices inspired by Paul Hudson's "Two Straws" approach.

## Network Request Logging

All Spotify network requests must include debug logging. Add a log statement after constructing the URL string:

```swift
let urlString = "\(baseURL)/endpoint"
debugLog("SpclientAPI", "[GET] \(urlString)")
```

- Use the appropriate HTTP method: `[GET]`, `[POST]`, `[PUT]`, `[DELETE]`
- The first argument names the module making the request — `"SpclientAPI"`, `"PartnerAPI"`, `"KeymasterAuth"`, and so on
- `debugLog` lives in `DebugLog.swift` and compiles to an empty inlinable function outside DEBUG builds, so it needs no `#if DEBUG` around it

## Track identity is the market id

**A track can have two ids.** When a recording is not playable in the account's market,
Spotify substitutes one that is — a different `id` and `uri` for what a listener would call
the same song. Spotify's Web API, which the app no longer calls, names both, returning the
substitute as `id` and the id you asked for under `linked_from`. Which one you get depends
on the endpoint and on `market`.

**The rule: the app keys everything on the id the API returned, and never rewrites it.**
Store keys, favorites, queue position, playback, writes — all the market id. Nothing in the
app reconstructs an original, and no code should start.

The reason is that reconstruction is no longer possible. Search now runs on pathfinder, which
returns the market recording and carries **no `linked_from`** — there is nothing to trade the
substitute back for, and the substitute looks canonical from every angle. spclient is
id-faithful: it returns whatever id you ask for, so it hydrates entities without ever
introducing a second identity. Measured against a known pair on 2026-08-13 (Xavier Rudd, "The
Letter": original `459GknUJgpky3io0y482bi`, DE substitute `7FcObTmCbQYyC8qzlTL2SE`); the
detail is in `plans/done/single-grant-partner-api.md`.

So the choice is only *which* id every path agrees on, and the market id is the one every
path can produce. Send `market=from_token` everywhere it is supported and let the answer
stand: that is what makes a searched track and a saved track the same track.

**This reverses the earlier rule**, which normalised back to the original through a
`RelinkableTrackCodable` protocol. The two plans that introduced it were deleted on
2026-09-29 and are in git history. That rule existed because Spotify's
[relinking docs](https://developer.spotify.com/documentation/web-api/concepts/track-relinking)
require the original id for Web API writes. It stopped being available once search moved to
pathfinder, and the mismatch it caused was live: a relinked track favorited from search saved
one id while the library row held the other, so the heart did not light and removal missed.

**Relinking is many-to-one**, which the market id inherits: several saved recordings can
substitute to the same playable one, so a library page can name the same track twice, and two
pages can each name it once. Collections keyed by track id must tolerate that — `AppStore`
deduplicates `savedTrackIds` across the whole list, and anything building a dictionary from
track ids uses `uniquingKeysWith:` rather than `uniqueKeysWithValues:`, which traps. A knock-on
to expect rather than fix: a list can be shorter than the total Spotify reports, since that
counts saved entries and the list counts tracks.

What the old rule was *right* about, and what still holds: **one identity per track, or the
store corrupts.** Two ids for one song means the queue points at a key `store.tracks` misses,
the track re-fetches forever behind a placeholder, and the recovery loader writes a second
entity. Consistency is the requirement; which id carries it is not.

**Writes with a market id work** — measured on 2026-08-13, against the relinked pair above.
Spotify's docs warn that a substitute id "will likely return an error or other unexpected
result" for saves and removals; it does not. Saving and removing "The Letter" by its market id
both succeeded, and the proof is not the UI, which updates optimistically, but Spotify's own
collection service pushing the change back over Mercury:

```
hm://collection/collection/<user>/json
{"items":[{"type":"track",…,"removed":true, "identifier":"7FcObTmCbQYyC8qzlTL2SE"}]}
{"items":[{"type":"track",…,"removed":false,"identifier":"7FcObTmCbQYyC8qzlTL2SE","addedAt":1786605160}]}
```

`addedAt` matches the second the request was sent, so the write was recorded rather than
accepted and dropped — and the collection service names the track by its **market** id, the
same one pathfinder returns. The removal also cleared an entry that had been saved under the
*original* id, which says Spotify resolves the relink on write rather than keying entries
literally. That is the reading, not a certainty: the library was not re-snapshotted first.

**There is more than one track-shaped response**, which is the part that bites. Pathfinder
answers with a different shape for an album's tracks, a playlist's items (saved tracks
included: Liked Songs is read as a playlist, `LikedSongs`) and search results, and spclient's
metadata has its own; each has its own `Track` initializer in
`PartnerAPI/PathfinderEntities.swift` or `PartnerAPI/SpclientEntities.swift`. The failure
mode is a hand-written conversion that reintroduces an original id from somewhere: the
request looks correct and the store is wrong.

**When adding or changing a track-returning request:**

- send `market=from_token` where the endpoint supports it, as spclient's metadata does, so
  the id matches what pathfinder and playback use;
- do not project or read `linked_from`; if a response carries one, ignore it;
- build entities through those initializers — `Track(pathfinder:)` and its siblings,
  `Track(spclient:id:)` — rather than field by field. A hand-written conversion is how
  `/search` once came to disagree with everything around it while looking reasonable;
- where a response is read without one, as the queue reads the cluster's uris, take the id
  in the uri as given (`SpotifyAPI.parseTrackURI`).

## State Management Architecture

The app uses a normalized state store pattern (similar to Pinia/Redux) for data management.

### Core Components

**AppStore** (`Store/AppStore.swift`)
- Single source of truth for all entity data
- Normalized entity tables: `tracks`, `albums`, `artists`, `playlists`
- ID arrays for ordered collections: `savedTrackIds`, `userPlaylistIds`, `userAlbumIds`, `userArtistIds`
- Injected via `@Environment(AppStore.self)`

**PlayerModel** (`Store/PlayerModel.swift`)
- What the UI shows of the player: the connection, the Connect devices and the active one,
  the playback state, the queue with its context, the volume, and the last track playback
  skipped or stopped at over an error (`PlaybackInterruption`)
- Fed by `LibrespotClient.snapshots`: one `PlayerSnapshot` per change, and a slow main thread
  gets the newest rather than a backlog. The client never waits for the UI
- Views read it via `@Environment(PlayerModel.self)`. `QueueService` and `PlaybackViewModel`
  follow it with `Observations`. Nothing subscribes to the client directly, and nothing needs
  a hop to the main queue
- The queue is the player's alone: `queueEntries` gives it as rows of track ids, written in the
  same `apply` as `queue`, and the store holds only the tracks' metadata, which `QueueService`
  asks for on every change of the queue and again when the network returns. No copy of the
  queue is kept anywhere else, so its rows and its context come from one snapshot
- Commands still go through the static `SpotifyPlayer` facade

**Entities** (`Store/Entities.swift`)
- Unified data models: `Track`, `Album`, `Artist`, `Playlist`, `Device`
- Decoupled from API response types (conversions in `EntityConversions.swift`, and for the
  partner APIs in `PartnerAPI/PathfinderEntities.swift` and `PartnerAPI/SpclientEntities.swift`)

**Services** (`Store/Services/`)
- Handle API calls and update AppStore on success
- Each service takes `AppStore` in its initializer, except `DeviceService`, which only
  transfers playback and writes its guess at the active device into `PlayerModel`
- Injected via `@Environment(XxxService.self)`
- Available services: `TrackService`, `AlbumService`, `ArtistService`, `PlaylistService`, `ProfileService`, `HomeService`, `SearchService`, `DeviceService`, `QueueService`
- Views do not write the store; a write a view needs is a service method

### Network Request Deduplication

Every fetch goes through `InFlightRequests` (`Store/Services/InFlightRequests.swift`), a
keyed single-flight registry. A second caller for the same key awaits the run the first
one started, and the run is an *unstructured* Task, so it is not cancelled when its
caller is — SwiftUI cancels a view's `.task` on teardown, and the detail views are torn
down routinely (selection changes, section switches, the 2→3 column flip). The result
lands in `AppStore` either way, and whatever view replaces the cancelled one reads it
from there.

```swift
try await albumRequests.run(albumId) {
    try await self.loadAlbum(albumId: albumId)
}
```

Requests that carry **many IDs at once** use `BatchInFlightRequests`
(`Store/Services/BatchInFlightRequests.swift`) instead, because one key to one run does
not fit them: track metadata and saved-status checks each cover a set of IDs, and the next
caller arrives with an overlapping but different set. It joins the runs already carrying
some of its IDs and starts one run for the remainder, which it hands to the operation:

```swift
try await metadataLoads.run(missingTrackIds) { uncoveredTrackIds in
    // fetch only the IDs no current run covers
}
```

Same guarantees as the keyed registry — unstructured runs, cache check before the run,
entries dropped on failure so the next caller retries. `TrackService` owns both batch
registries; route new track metadata through `ensureTracksLoaded(trackIds:)` rather than
adding a second fetch path.

Rules when adding a loading path:

- **A key means one postcondition.** `album:<id>` always means "metadata *and* tracks are
  in the store". Two operations that fetch different amounts may not share a key.
- **Check the cache before the run.** Return early when the store already holds what the
  key promises, as `ensureAlbumLoaded` does, so a cache hit costs no request at all.
- **A superseded run must not write.** `cancel(_:)` only asks; call
  `try Task.checkCancellation()` after the network call, before touching the store.
- **Cache what was fetched, not what is non-empty.** `detailsLoaded` / `tracksLoaded` are
  set by the load, so a genuinely empty album is not re-fetched forever.
- **Views read the store**, never a `@State` copy of an entity.

The services that hold registries are stored as `@State` in `LoggedInView` so the
registries survive view recreation. `plans/done/section-request-pattern.md` has the full reasoning.

## Debug Logging

Everything logs through `debugLog(module, message)` in `DebugLog.swift`. It writes to
**stderr** in Debug builds and compiles away to nothing in Release, so there is no log level
to set and no environment variable to pass — building Debug is the switch.

### Connect Trace Logging

Connect state transitions come from the modules that own them, so narrowing a run down means
filtering on the module prefix:

```bash
./path/to/Spotifly.app/Contents/MacOS/Spotifly 2>&1 \
  | grep -E 'SpircController|DealerConnection|LibrespotSession'
```

- `SpircController` — registration, PutState reasons, the cluster it is answered with
- `DealerConnection` — the WebSocket: connection id, cluster pushes, remote commands, pings
- `Accesspoint` — the TCP connection to Spotify: connect, handshake, login, audio keys
- `LibrespotSession`, `LibrespotClient` — session lifecycle, recovery, command dispatch
- `AudioPipeline`, `AudioRenderer` — track loads, decoding, position, end of track

## Plans

`plans/` holds one Markdown file per problem, named after it, in one of two folders:

- `plans/open/` — not done: problems recorded but not planned, and those with a plan. Status
  says which, and ranks the ones being worked on. A plan being written lives on a
  `plan/<topic>` branch with a draft PR until it is merged.
- `plans/done/` — implemented. Kept because they record why the code does what it does, and
  code comments cite several. Move a plan here in the PR that finishes it, and set its status.

There is no index file; the folders are the index. A plan that no longer describes the code,
and whose reasoning nothing relies on, is deleted rather than kept, since git history has it.
Paths and plan names inside a done plan are as of when it was written, so a plan it names
may since have been deleted.

Every plan has the same structure:

```markdown
# <The problem, or what is built, in one line>

Status: **Open** or **Done**, then the date, PR or commits, and anything unconfirmed
Components: `the/files.swift` it touches
Found: <date>, <how it came up>

## Summary
## Problem
## Solution
## Verification
```

Anything else goes under one of the four as a `###` section. An open plan with no solution
yet says so under Solution and Verification rather than leaving them out.

## Changelog & Releases

### Changelog Management

- Keep `CHANGELOG.md` in this repo up to date with all changes (detailed, technical notes welcome)
- Use [Keep a Changelog](https://keepachangelog.com/) format with sections: Added, Changed, Fixed, Removed
- Add entries under `## [Unreleased]` as you work

### Release Process

When ready to release, run: `/release [version]` (e.g., `/release 1.1.5`)

This will:
1. Move `[Unreleased]` entries to a new version section with today's date
2. Bump `MARKETING_VERSION` in the Xcode project
3. Update `../homebrew-spotifly/CHANGELOG.md` with user-facing summary (temporary)
4. Commit both repos

After `/release`, you must:
1. Push both repos
2. Create a GitHub Release in this repo with the built .zip artifact
3. Update the cask in homebrew-spotifly, `Casks/spotifly.rb`: its `version` and `sha256` (the URL follows the version)

### About homebrew-spotifly

The `../homebrew-spotifly` repo is temporary scaffolding for the Homebrew tap. Once the app is accepted into official Homebrew, it will be deleted. Until then:
- Releases are published to **this repo** (ralph/Spotifly)
- The homebrew-spotifly repo only contains the tap's cask and a user-facing changelog
- Both changelogs are updated during `/release`
