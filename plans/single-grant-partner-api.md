# One grant, no dashboard app — moving Spotifly onto the client's own APIs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** One browser authorization, minted with Spotify's own desktop client id, that serves
local playback *and* every metadata read and write the app performs — so Spotifly stops
requiring each user to register a Spotify developer application and allowlist themselves in it.

**Architecture:** Swift owns the OAuth flow and holds the token. That single token authorizes
three things: the librespot session (accesspoint login), the pathfinder GraphQL API at
`api-partner.spotify.com`, and the spclient REST API at `spclient.wg.spotify.com`. The Web API
at `api.spotify.com` and the user's dashboard client id are retired at the end of the
migration, not the start — every phase leaves a working app.

**Tech Stack:** Swift 6.3 / SwiftUI, strict concurrency; Swift Testing (`import Testing`);
Rust FFI retained for playback for now (see Track B for its exit).

---

## Evidence

This plan rests on a probe rather than on inference. `libspot-probe/` in the workspace root
(Go, built against the `libspot/` checkout) runs five legs against the live service with one
token and reports each independently. Three runs on 2026-08-12, all five legs green:

| Run | Token minted by |
| --- | --- |
| default | libspot's session — DPoP-signed exchange |
| `-plain-pkce` | bare `golang.org/x/oauth2` exchange, no DPoP, no Client-Token |
| `-plain-pkce -refresh` | as above, then the refresh token spent and every leg re-run on the refreshed token |

The legs: spclient `metadata/4` (JSON), spclient extended-metadata (protobuf), pathfinder
`searchTracks`, spclient `storage-resolve` (CDN url), and accesspoint login followed by AES
audio-key delivery.

What this establishes, and what each fact costs us if it is wrong:

- **login5 is not on the path.** libspot authenticates the accesspoint with the OAuth token
  itself (`AUTHENTICATION_SPOTIFY_TOKEN`, `libspot/ap/ap.go:105`), never trading stored
  credentials through login5. The 2026-08-11 break is therefore avoidable rather than merely
  survivable.
- **DPoP is not required.** The plain-PKCE token is 435 characters against 498 for the
  DPoP-issued one and is accepted everywhere the latter is. No P-256 proof implementation is
  needed on the Swift side.
- **The refresh grant works the same way, and Spotify rotates the refresh token on every
  refresh.** Persisting the replacement is mandatory; keeping the original means the *second*
  refresh fails, roughly an hour in, presenting as a random logout.
- **A Client-Token is required for the two API surfaces** but not for the token exchange. It
  is obtained unauthenticated from `clienttoken.spotify.com/v1/clienttoken` with a protobuf
  body, keyed by client id and a generated device id.

`plans/streaming-auth-needs-a-first-party-client-id.md` records the earlier finding that a
dashboard client id cannot obtain a client token at all. That constraint is unchanged; this
plan resolves it by removing the dashboard client id from the app rather than working around
it.

## Why this is worth doing

Playback already works on `rework-auth`: `spotifly_authorize_streaming` mints a keymaster
token through `librespot_oauth` and caches the AP credentials. What that branch does *not*
remove is the second grant and everything hanging off it.

Today a new user must create an app in the Spotify developer dashboard, paste its client id
into the login screen (`SpotifyConfig.getClientId()` calls `fatalError` without one), and then
add their own account to that app's allowlist — `UserNotWhitelistedView` exists solely to walk
them through it. For an open-source music client that is the single largest barrier to first
use, and it exists only because `api.spotify.com` demands a first-party-or-your-own client id
and rejects the desktop one with 429.

The client's own APIs have no such requirement. Removing the dashboard dependency removes: the
client-id text field, the allowlist screen and its three localizations, the whitelist check,
`SpotifyConfig`, and the entire second OAuth flow — plus the class of bug where the two grants
authorize different accounts, which `rework-auth` had to add a guard for.

## Global constraints

- **Never send a keymaster token to `api.spotify.com`.** Every endpoint returns 429. During
  the migration both tokens exist; they are not interchangeable and must not share a provider.
- **Persist the rotated refresh token on every refresh**, or the session dies at the second
  refresh.
- **Relinking: measured, and it bites.** Settled on 2026-08-13 with a known pair — Xavier Rudd,
  "The Letter": original `459GknUJgpky3io0y482bi`, DE substitute `7FcObTmCbQYyC8qzlTL2SE`, taken
  from `/v1/me/tracks?market=DE` where `linked_from` names both.

  - **pathfinder returns the substitute** (`7FcObT…`) and never the original, with nothing in
    the response to say a substitution happened.
  - **spclient is id-faithful**: asked for either id it returns that id, so it neither relinks
    nor exposes the relationship.
  - The Web API library returns the **original**, because that is what was saved.

  So the same track had two identities depending on where the app found it, and it showed:
  favoriting from a search result saved the substitute while the library row was keyed to the
  original, so the heart did not light and removal missed.

  **Settled on 2026-08-13: the market id is the identity.** Recovering an original from a
  substitute is not possible by asking for it — the substitute looks canonical from every
  angle, and the only bridge is the shared `external_ids.isrc`. So the app stopped trying:
  `RelinkableTrackCodable`, `logicalId`/`logicalUri` and the `linked_from` projections are
  deleted, every path takes the id it was given, and `market=from_token` goes everywhere it is
  supported so the Web API answers with the same recording pathfinder and playback use.

  Why that direction rather than the other, given Spotify's docs require the original id for
  Web API writes:

  - it is the only id every source can produce — pathfinder cannot produce the original at all,
    so "always original" is unimplementable while "always market" is not;
  - Spotify's own client holds nothing else. pathfinder gives it no `linked_from`, and it saves
    from search perfectly well, so the client's own collection API — where these writes are
    going — must accept market ids;
  - nothing keyed by track id is persisted. `AppStore` is in-memory, so a market-scoped id
    never outlives a launch and a market change repairs itself.

  What still holds from the old rule: **one identity per track, or the store corrupts.** Two
  ids for one song is a queue pointing at a key `store.tracks` misses. Consistency was always
  the requirement; which id carries it was not.

  **Settled the same day: writes with a market id work.** The docs' warning does not bite.
  Saving and removing the relinked track by its market id both succeeded, confirmed not by the
  UI — which updates optimistically — but by Spotify's collection service pushing the change
  back over Mercury, `hm://collection/collection/<user>/json`, with an `addedAt` matching the
  second the request was sent. The service names the track by its **market** id, the same one
  pathfinder returns, and the removal cleared an entry that had been saved under the original
  id. So Spotify resolves the relink on write; nothing needs to hold an original.

  That also removes the duplicate-library worry: saving from search does not create a second
  entry alongside one saved under an original id.

  **A find for task 12:** that Mercury feed is the library change stream, and it is already
  arriving — librespot logs it as an unknown subscription and drops it (`could not dispatch
  command`, and a base64 warning from trying to decode what is plain JSON). It carries exactly
  what the favorites list needs to stay live: identifier, `removed`, `addedAt`. Subscribing to
  it is likely cheaper than polling `/me/tracks`, and it is the mechanism the real client uses.

  How much polling it would replace is now measured. In a run on 2026-08-13 the Now Playing bar
  sent **seven identical `/me/tracks/contains` requests for one track in under two minutes**,
  while that track played continuously — `.task(id: currentTrackId)` re-firing on view
  re-creation, into `refreshFavoriteStatuses`, which ignores the resolved cache by design. That
  is a pre-existing defect rather than migration fallout, and worth fixing on its own; but it is
  also the shape of the thing the feed removes, so do not port the polling to the client's own
  API before deciding whether to keep polling at all.

- **Re-derive the track-relinking rules for the new endpoints.** `CLAUDE.md` documents them
  for the Web API, where `market` decides whether you get the track you asked for or a playable
  alternative, and where the identity rule (logical id owns store keys, favorites, queue
  position) is enforced through `RelinkableTrackCodable`. libspot's spclient sends
  `market=from_token` on every request (`libspot/spc/make.go:26`), and pathfinder responses
  have their own shape entirely. **Do not assume the existing conformances carry over.** Each
  ported endpoint must state, in its task, which id it returns and how the logical id is
  recovered. This is the single most likely source of a subtle, store-corrupting bug in this
  plan.
- **Pathfinder uses persisted queries.** Every operation carries a hardcoded SHA-256 hash
  (`libspot/pathfinder/pfrequest/operations.go:100`) that Spotify rotates when it ships a new
  web client. Treat the hash table as data with an upstream, not as constants.
- **A superseded run must not write** (`AGENTS.md`), and the `InFlightRequests` rules in
  `CLAUDE.md` apply unchanged to the new clients: check the cache before the token, unstructured
  runs, `try Task.checkCancellation()` after the network call.
- Swift formatting: `swiftformat --swiftversion 6.3`. Format touched files.
- Swift tests: `xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES`.
  Treat the exit code and `** TEST SUCCEEDED **` as authoritative; the log is racily written,
  so never count tests by unique name.
- One commit per problem. Every task's commit includes its `CHANGELOG.md` entry under
  `## [Unreleased]`, matching the surrounding density — mechanism and why, not just what.

---

## Track A — one grant, and the client's own APIs

### Phase 1: Swift owns the grant

The OAuth flow moves from Rust into Swift. Not because Rust does it badly, but because Swift
needs the *token*, and today Rust mints it, hands it to librespot and drops it. Everything
downstream in this plan needs that token in Swift, and Track B needs it there permanently.

- [ ] **Task 1: A loopback OAuth client in Swift.**
      PKCE (S256), authorization URL opened with `NSWorkspace`, and a loopback listener on
      `http://127.0.0.1:<port>/login` — `ASWebAuthenticationSession` cannot serve this, because
      the desktop client id's redirect is plain HTTP on loopback rather than a custom scheme.
      Bind port 0 and read back the assigned port, as the Rust path already does. Validate the
      `state` parameter and bound the wait, so a closed browser tab fails rather than hanging.
      New: `Spotifly/Auth/KeymasterAuth.swift`. Tests cover URL construction, the challenge,
      state mismatch rejection and callback parsing — not the browser round-trip.

- [ ] **Task 2: Token storage with rotation.**
      Access token, refresh token, expiry and the account id in the keychain, refreshed through
      the same `refreshBufferSeconds` policy `SpotifyAuthResult` already defines. **The refresh
      response's refresh token replaces the stored one.** A test drives two consecutive refreshes
      against a stub and fails if the second sends the original token.

- [ ] **Task 3: Feed librespot from Swift's token, and delete the Rust OAuth.**
      `spotifly_authorize_streaming` loses its `librespot_oauth` client and takes a token
      argument instead; Swift performs the grant and passes the result. The credentials cache,
      the account-mismatch guard and the generation checks stay exactly as they are — this task
      changes where the token comes from and nothing else. Removes `librespot-oauth` from
      `rust/Cargo.toml`. Recount the clippy `not_unsafe_ptr_arg_deref` baseline afterwards: it
      tracks pointer-taking FFI entry points and this task adds one.

### Phase 2: The two API clients

- [ ] **Task 4: Client-Token acquisition.**
      A protobuf POST to `clienttoken.spotify.com/v1/clienttoken` carrying client id, version
      and a generated 40-hex-character device id, returning the granted token. Two messages in
      each direction; hand-encode them as the `swift-librespot` branch does under
      `Proto/` rather than adding a protobuf dependency for four fields. Cached with the device
      id, refetched on 401.

- [ ] **Task 5: `PartnerAPI` — the pathfinder GraphQL client.**
      POST to `api-partner.spotify.com/pathfinder/v2/query` with `Authorization: Bearer`,
      `Client-Token`, `App-Platform: OSX_ARM64` (or the Intel equivalent), the xpui
      `Origin`/`Referer`, and a body of `{variables, operationName, extensions.persistedQuery}`.
      Operation hashes live in one table with a comment naming libspot as their upstream.
      Ship it with the four search operations `SearchService` actually needs — `searchTracks`,
      `searchAlbums`, `searchArtists`, `searchPlaylists` — and their response types. One
      operation would have been a smaller first step but a broken one: `SearchService.search`
      requests all four types and `SearchResultsView` renders a section per category, so
      shipping tracks alone silently deletes three quarters of the search results.

- [ ] **Task 6: `SpclientAPI` — the REST client.**
      `spclient.wg.spotify.com` with the same two headers. Two shapes to support: JSON
      (`metadata/4/track/{gid}`, which needs a CORS-style `OPTIONS` preflight first, as libspot
      sends) and protobuf (extended-metadata, storage-resolve — needed by Track B, not by
      Track A). Base62↔GID conversion lands here; it is 20 lines and both clients need it.

### Phase 3: Migrate the reads, one at a time

43 call sites across seven `SpotifyAPI+*.swift` files. Each task ports one service's reads
behind the existing service layer, so `AppStore`, `InFlightRequests` and the views do not move.
Order runs cheapest-first, and each task is independently shippable and revertible:

- [ ] **Task 7: Search** (`SpotifyAPI+Search.swift`, 1 call site, four result categories) — the
      smallest real test of `PartnerAPI`, and the one whose relinking behaviour is best
      understood. Parity with the current result shape is the acceptance criterion, not "search
      returns something".
- [x] **Task 8: Tracks** — batch metadata through `ensureTracksLoaded`, on spclient rather than
      pathfinder. Identity path: spclient is **id-faithful**, so it hydrates whatever id the
      store already holds and introduces no second identity; the conversion keys on the
      requested id, not the returned gid. `metadata/4` is one entity per request where
      `/v1/tracks` took fifty, so batches run eight in flight — `extended-metadata` is the
      endpoint that batches properly, and it is protobuf, so it waits for Track B. Only a 404
      may be reported as an absent track, since `TrackService` remembers absences permanently.
      Removed what it orphaned: `fetchTrack`, `fetchTracks`, the `/v1/tracks` envelope, and the
      unreachable `TrackLookupViewModel`.
- [x] **Task 9: Albums** — the album *view*: details and tracks, through pathfinder `getAlbum`,
      one request replacing `/albums/{id}` and `/albums/{id}/tracks`. spclient was measured and
      rejected: `metadata/4/album` gives `disc[].track[]` entries holding a bare `gid`, so one
      album would cost a request per track. First hash that could not be vendored — libspot
      declares `OpGetAlbum` and panics — so it was harvested from the web bundle and verified
      live; `libspot-probe/harvest-hashes.sh` makes that repeatable. Identity path: album
      tracks carry a `uri` and no `id`, and pathfinder *does* expose `relinkingInformation`
      here, unlike search — deliberately not decoded, since the id already is the market id.
      `RecentlyPlayedService` moved to the same call. Removed `fetchAlbumDetails`,
      `fetchAlbumTracks` and `AlbumTracksCodable`.

      **Re-scoped by surface rather than by file.** The other three call sites in
      `SpotifyAPI+Albums.swift` belong to other screens and move with them: `fetchArtistAlbums`
      with task 10, and `fetchUserAlbums` plus the save/remove writes with task 12. Grouping by
      file would have meant porting the artist page's discography before the artist page.

- [x] **Task 10: Artists** — the artist *page*: `queryArtistOverview` for identity,
      `queryArtistDiscographyAll` for releases, concurrently. Two operations because the
      overview samples the discography (10 of 15 albums) and the discography query carries no
      profile. Both hashes harvested and verified live. Shapes measured, not assumed: releases
      nest as `items[].releases.items[]` except in `popularReleasesAlbums`, which is flat; and
      the two operations use different date shapes. Sections overlap, so releases are
      deduplicated by id. `RecentlyPlayedService` moved to the overview. Removed
      `fetchArtistDetails`, `fetchArtistAlbums`, and the dead `SpotifyAPI+Search.swift`.

      **Genres are gone**, and this is a real user-visible loss rather than a deferral: no
      client-owned API returns them — checked across three pathfinder operations and spclient's
      artist metadata — while the Web API does. Spotify's own artist pages do not show them.
      `Artist.genres` is removed rather than left empty.

      Still on the Web API here, by surface: `fetchUserArtists` and follow/unfollow go with
      task 12; `fetchUserTopArtists` and `fetchUserTopTracks` are a Home-screen surface with no
      obvious pathfinder equivalent and need their own decision — the web client builds Home
      from a single `home` operation (`23e37f2e…`, harvested, unverified), which may replace
      several of these calls at once or none of them.
- [x] **Task 11: Playlists** — the playlist *page* and its item writes. `fetchPlaylist` for
      details plus contents in one request; `addToPlaylist`, `removeFromPlaylist` and
      `moveItemsInPlaylist` for the writes. All four share two hashes and are selected by
      operation *name*, which is load-bearing: the wrong name returns a playlist with no tracks
      rather than an error.

      **Mutation schemas were discovered without writing.** Sending a mutation with no variables
      is rejected during GraphQL validation, before any resolver runs, and the rejection names
      the variables and their types; a deliberately invalid input field returns full SDL with
      doc comments. Only the final round-trip touched a real (scratch) playlist, and it added
      and removed one track by the uid it had just created. That technique works for any input
      type on this API and is worth reaching for before any future write migration.

      **A rejected write is HTTP 200** with a failure `__typename`; success is
      `AddItemsToPlaylistPayload` / `RemoveItemsFromPlaylistPayload` / `MoveItemsInPlaylistPayload`.
      Checking only the status code would leave an optimistic update standing after a failed write.

      **Store change: `Playlist` holds `[PlaylistItem]`** (uid + track id), because the writes
      address entries by per-occurrence uid rather than by track uri. This fixes a real defect:
      the Web API path removed *every* copy of a track from a playlist that held it twice.
      `trackIds` survives as a computed property. Remaining gap: `TrackContextMenu` is shared by
      every list and does not know its row, so removal from there resolves to the first
      occurrence — exact only once the uid is threaded through `TrackRow`.

      Verified against a live playlist: add, remove (including the duplicate case) and reorder.
      Two defects surfaced in testing and are recorded in the changelog — a missing
      `enableWatchFeedEntrypoint` variable, and a drop handler that mixed pre- and post-reorder
      frames. The second is the interesting one: it was latent under the Web API, which took
      positions Spotify resolved against its own order, and only became visible once items were
      named by uid.

      Still on the Web API by surface: `fetchUserPlaylists` and create/rename/delete/follow go
      with task 12.
- [ ] **Task 12: User/library.** Schemas probed 2026-08-13, no writes performed. The surface
      collapses hard — six Web API write endpoints become two mutations, and three list calls
      become one query:

      | Web API today | Replacement |
      | --- | --- |
      | `/me/playlists`, `/me/albums`, `/me/following?type=artist` | `libraryV3` with `filters` |
      | `/me/tracks` | `fetchLibraryTracks` |
      | `/me/tracks/contains` | `areEntitiesInLibrary($uris: [ID!]!)` |
      | `saveTrack`, `saveUserAlbum`, `followArtist` | `addToLibrary($libraryItemUris: [String!]!)` |
      | `removeSavedTrack`, `removeUserAlbum`, `unfollowArtist` | `removeFromLibrary($libraryItemUris: [String!]!)` |

      `libraryV3` and `fetchLibraryTracks` both accept **empty variables**, so nothing is
      required; `libraryV3` answers `data.me.libraryV3` with `availableFilters`
      (Playlists/Artists/Albums/Audiobooks), `totalCount`, and mixed `items[]` of
      `{addedAt, depth, item{__typename,_uri,data}, pinnable, pinned, playedAt}`. The test
      account returned 120 items across four kinds in one page, so the three separate library
      sections are one query filtered three ways.

      Two consequences worth deciding before writing code. **Audiobooks appear in the library**
      and the app has no concept of them — they need filtering out or a placeholder, not a crash.
      And **`addToLibrary` takes uris of any kind**, so `TrackService.toggleFavorite`,
      `AlbumService.saveAlbumToLibrary` and `ArtistService.followArtist` all become the same
      call with a different uri prefix; whether they stay three service methods or become one is
      a judgement call, and three thin wrappers over one call is probably still right, since the
      views and the optimistic store updates differ per kind.

      Writes must be verified the way task 11's were: schema by empty-variable rejection first,
      then one reversible round-trip against something disposable. `addToLibrary` on a track is
      self-cleaning (add, check, remove), so it needs no scratch entity — but it does touch the
      real library, so confirm before running it.

      The identity question that once gated tasks 11 and 12 is settled — the market id owns the
      store key and the favorites state — and so is the write question: Spotify accepts market
      ids for saves and removals, measured. See the relinking constraint above, including the
      collection Mercury feed, which is the more interesting way to build task 12.

- [ ] **Task 12a: Player control** (`SpotifyAPI+Player.swift`, 12 call sites) — last, but not
      optional. An earlier draft of this plan left it undecided, which quietly made Phase 4
      unreachable: a keymaster token gets 429 from `api.spotify.com`, so any call left there
      keeps the dashboard grant alive and the whole point of the plan with it.

      The replacement is spclient's connect-state API, which is what the real client uses and
      what `libspot/connect/` implements in full — `player/command/from/{from}/to/{to}` for
      play, pause, skip, seek, shuffle, repeat and queue-add (`connect/endpoints.go`), plus
      transfer, device list, playback state and queue reads (`connect/commands.go`). That
      covers every call site in `SpotifyAPI+Player.swift`, including the `startPlayback` and
      device-transfer paths `rework-auth` added, so the remote-device fallback survives the
      migration rather than being dropped for it.

- [ ] **Task 12b: Home, rebuilt on `home`.** Probed 2026-08-13 and viable — this is the section
      that unblocks Phase 4, since `/me`, `/me/top/artists`, `/me/top/tracks` and
      `/me/player/recently-played` have no one-to-one replacements and keep the dashboard grant
      alive on their own.

      **Do not port the current layout.** `home` (`23e37f2e…`) returns Spotify's own start page:
      a `greeting`, `homeChips` for filtering, and `sectionContainer.sections.items[]` — 31
      titled sections in the test account, each holding Playlists, Albums or Artists under
      `sectionItems.items[].content.data`. "Your favorite artists" subsumes top artists and a
      "Recents" section (item kind `List`) looks like the recently-played equivalent. Building
      the page from whatever sections arrive is both less work and closer to what the real
      client shows than reproducing three Web API calls would be.

      Two required variables, `timeZone: String!` and
      `homeEndUserIntegration: HomeEndUserIntegration!`. The second is an **enum** whose member
      is `INTEGRATION_WEB_PLAYER` — established by reading the web bundle's call site
      (`homeEndUserIntegration: (0,p.mg)()`) rather than by guessing, after a wrong guess made
      the validator's "found JSON string" message look like a type mismatch and sent the probe
      chasing every other JSON shape. Note for next time: that message means *invalid enum
      member* as readily as it means wrong type, so read the caller before enumerating shapes.

      Sections carry a per-section `__typename` (`HomeShortsSectionData` and others) that
      decides presentation, so the page wants a small renderer per section type with a generic
      fallback — an unknown section should render as a plain shelf rather than disappear.

### Phase 4: Retire the dashboard app

Only once no `api.spotify.com` call remains:

- [ ] **Task 13:** Delete `SpotifyConfig`, the client-id field in `ContentView`,
      `UserNotWhitelistedView` and the whitelist strings in all three localizations, the
      dashboard OAuth in `SpotifyAuth.swift`, and the account-mismatch guard that exists only
      because two grants could disagree. Update the README and the Homebrew tap's setup
      instructions, which currently tell users to register an app.

---

## Track B — Swift-native playback

Independent of Track A and gated on one unknown. The `swift-librespot` branch already has the
expensive parts working — Shannon cipher, Diffie-Hellman, the AP handshake, dealer, connect
state, spclient, chunked CDN download. What it does not have is audio:
`Audio/VorbisDecoder.swift` returns silence from a `TODO`, and `AudioPipeline.swift` calls
`downloadAllData()` before decoding rather than streaming, with a comment conceding as much.
Neither is an architectural dead end; both were left for last.

- [ ] **Task B1 (the gate): a decoder spike.**
      Standalone, outside the app. Take a CDN url and AES key from `libspot-probe -show-token`,
      fetch the file, decrypt it (AES-CTR, 167-byte header skipped), decode through libvorbis or
      tremor, write a WAV, listen to it. Success criteria: it sounds correct, and decoding runs
      comfortably faster than realtime on one core. C dependencies are acceptable; Rust and Go
      are not.
      **If this fails, Track B stops here** and librespot keeps playing music at no cost to
      Track A.
- [ ] **Task B2:** Wire the decoder into `AudioPipeline` incrementally — decode from
      `ChunkedDownloader` as chunks arrive, feed an `AVAudioSourceNode`, start playback after
      roughly a second of decoded audio rather than after the whole file.
- [ ] **Task B3:** Replace the branch's auth layer with Phase 1's, which is simpler than what
      it currently carries: no login5, no stored credentials, no client-token dance for the AP.
- [ ] **Task B4:** Seek, gapless, and the 49-function FFI surface's Swift equivalents; delete
      `rust/` when the last one is gone.

Open question for B4, to be settled with a measurement rather than a preference: Spotify serves
some tracks as AAC, which `AVFoundation` decodes natively. If the catalogue coverage is good
enough it may be cheaper than Vorbis for some paths. Do not act on this before B1.

---

## What this plan does not decide

- **Whether Track B ships at all** — B1 decides it.
- **How persisted-query hashes get refreshed** when Spotify rotates them. Today the answer is
  "watch libspot and copy". If that becomes painful, a small extractor that reads them out of
  the live web client is the fallback, but it is not worth building pre-emptively.
