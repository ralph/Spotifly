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
      Ship it with exactly one operation — `searchTracks` — and its response type.

- [ ] **Task 6: `SpclientAPI` — the REST client.**
      `spclient.wg.spotify.com` with the same two headers. Two shapes to support: JSON
      (`metadata/4/track/{gid}`, which needs a CORS-style `OPTIONS` preflight first, as libspot
      sends) and protobuf (extended-metadata, storage-resolve — needed by Track B, not by
      Track A). Base62↔GID conversion lands here; it is 20 lines and both clients need it.

### Phase 3: Migrate the reads, one at a time

43 call sites across seven `SpotifyAPI+*.swift` files. Each task ports one service's reads
behind the existing service layer, so `AppStore`, `InFlightRequests` and the views do not move.
Order runs cheapest-first, and each task is independently shippable and revertible:

- [ ] **Task 7: Search** (`SpotifyAPI+Search.swift`, 1 call site) — the smallest real test of
      `PartnerAPI`, and the one whose relinking behaviour is best understood.
- [ ] **Task 8: Tracks** (8 call sites) — batch metadata through `ensureTracksLoaded`. State the
      identity path explicitly; this is where relinking bites hardest.
- [ ] **Task 9: Albums** (5) and **Task 10: Artists** (6).
- [ ] **Task 11: Playlists** (9), including the write paths.
- [ ] **Task 12: User/library** (2) and the saved-tracks writes.

Player control (`SpotifyAPI+Player.swift`, 12 call sites) is deliberately last and may not move
at all: remote-device control over the Web API is a fallback for when this Mac is not a Connect
device, and the Connect equivalent belongs to the dealer connection, not to a REST client. Decide
it when the rest has landed — with a local session working, its value is mostly for controlling
*other* devices.

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

- **Whether player control moves off the Web API** (Phase 3 note above).
- **Whether Track B ships at all** — B1 decides it.
- **How persisted-query hashes get refreshed** when Spotify rotates them. Today the answer is
  "watch libspot and copy". If that becomes painful, a small extractor that reads them out of
  the live web client is the fallback, but it is not worth building pre-emptively.
