# Playback's requests to spclient sign themselves, and miss both retries

Status: **Done** 2026-10-01. Unit tests for the retries; live, playback through the new signing
and one finding about refusals. A server error could not be brought about live, and neither
could a 401: Spotify answered a client token it rejected with a 400. See Verification and
`plans/done/refused-client-token-answers-400.md`.
Components: `Spotifly/SwiftLibrespot/Network/SPClient.swift` (`getTrack`, `resolveContext`,
`resolveCDNUrl`), `Spotifly/SwiftLibrespot/Dealer/DealerConnection.swift` (`putState`),
`Spotifly/Auth/SpotifyCredentials.swift`, `Spotifly/PartnerAPI/PartnerAPI.swift`,
`Spotifly/PartnerAPI/SpclientAPI.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`initialize`),
`Spotifly/SwiftLibrespot/Core/Errors.swift` (`requestFailed`)
Found: 2026-10-01, in the altitude review of `plans/done/loads-that-fail-while-online.md`

## Summary

Every request the app's pages make to Spotify's own APIs goes through `SpotifyCredentials`,
which asks again once after a 401 with a fresh client token, and again after a 5xx or a dropped
connection. Playback's requests to spclient did not: `SPClient` signed them itself, so a 5xx, a
dropped connection or a refused client token failed a track's start, a context's resolve or a
CDN url at once. They now go through `SpotifyCredentials` too, with shorter pauses, and so does
the dealer's state report, for the 401 alone.

## Problem

- `SPClient.authorizedRequest` repeated `SpotifyCredentials.sign`, and so did
  `DealerConnection.putState`.
- `getTrack` reported any status but 200 as `trackNotFound`, a 503 included, so a passing server
  error read as a track Spotify has not got: "Track not found: spotify:track:…" in the bar.
- None of them got the 401 retry, so a client token revoked early would fail playback until the
  app relaunched, which `retryingRefusedToken` was written to prevent for the pages.

## Solution

**One set of credentials, handed to the playback stack whole.** `LibrespotClient.initialize`
takes a `SpotifyCredentials` (`httpCredentials`) where it took a bearer and a client-token
closure, and passes it to `SPClient` and, through the session, to `DealerConnection`.
`SpotifyPlayer` hands it `SpotifyCredentials.live`: the keymaster bearer, the shared client
token and its invalidation, `URLSession` and `Task.sleep`. The accesspoint login and the
dealer's socket still read the bearer from it.

**Three helpers on `SpotifyCredentials`**, which sign each attempt afresh, so a retry after a 401
carries the new client token:

- `attempt(_:)` signs and sends once, and names the client token it carried.
- `send(_:)` asks again once after a 401 (`retryingRefusedToken`): for writes.
- `read(_:)` also asks again after a failure that may pass (`retryingPassingFailures`).

The pages' clients use them too, where each wrote out the same signing and sending:
`PartnerAPI.query` reads or sends by its operation's rule, `SpclientAPI`'s writes send, and its
reads still run the CORS preflight before each attempt. `PartnerAPI` and `SpclientAPI` take a
`SpotifyCredentials`, `.live` by default, so the app's credentials are written once.
`SpotifyCredentials` moved out of `PartnerAPI.swift` into `Spotifly/Auth/`, since the playback
stack holds it too.

**Playback reads with shorter pauses**: 0.25 s and 1 s (`SPClient.retryPauses`), where a page
waits 1 s and 3 s. They are the credentials' own (`retryPauses`), set once when `SPClient` is
made, so no playback read can fall back to a page's. A track's start waits on them, and a Next that meets a lasting outage says
so after about 1.3 s rather than 4. librespot asks again with no pause at all, up to ten times,
and moves to another spclient host every third try (`SpClient::request_with_options`, read
2026-10-01). `getTrack` is a read sent as a POST, and is asked again as one, body and all. The
context resolver's 20 s deadline covers a page's retries, so a hung first attempt still fails
at 20 s, unretried, as a timeout.

**A request that still fails says so**: `LibrespotError.requestFailed("Track metadata", status:)`
reads "Track metadata failed: HTTP 503", and the same for "Storage resolve" and "Context
resolve", where the two `cdnError`s said "CDN error: …". `trackNotFound` is left for the 200
with no `Track`, which is what a track Spotify has no entry for gets. Auto-advance still stops
on both: only `trackUnavailable` is skipped.

**The dealer's state report gets the 401 retry only.** A report asked again after a pause could
land after the newer one that replaced it, so a server error fails it as before, now as
`requestFailed("PutState", status:)`.

### Not done

- **Moving to another spclient host**, as librespot does every third try. The session resolves
  one, and a server error that outlasts the retries still stops playback.
- **The CDN download itself** (`AudioPipeline.downloadWholeFile`) goes to Spotify's CDN, not its
  API, and carries no credentials. A failed one still stops the load; the change of track
  fetches a failed fetch-ahead again.

## Verification

- [x] Unit tests (`SPClientRequestTests`, 6): a track's metadata that meets a 503 is asked again
      after 0.25 s, as a POST with the same body, and the answer that follows is used; a 503 that
      goes on is `requestFailed("Track metadata", status: 503)` after three attempts and pauses of
      0.25 s and 1 s, not `trackNotFound`; a 401 on the CDN url drops the client token it carried
      and asks again; a context page that meets a 502 is asked again; each request carries the
      bearer, the client token, `App-Platform` and its `Accept`; `send` asks again after a 401 and
      not after a 503.
- [x] `AutoAdvanceTests`: `requestFailed` stops playback rather than skipping.
- [x] Build, 517 unit tests, the lint, and no warnings in the app's own code.
- [x] Live (2026-10-01), the Debug build with `SPOTIFLY_DEBUG_AUTOPLAY=1` and two Nexts: the
      context resolve, three tracks' metadata and CDN urls, and every state report answered 200
      with the shared signing, whose `Referer` has no trailing slash where `SPClient`'s had one.
      All three tracks played.
- [ ] A retry against Spotify itself: not seen. No server error was at hand, and a throwaway
      build that sent a rejected client token got a **400 with an empty body**, not a 401, from
      the state report, the track metadata and the CDN url, both for a made-up token and for the
      real one with one character changed. Its headers said why: `client-token-error:
      INVALID_CLIENTTOKEN`. So that refusal is not retried; the failed Next said
      "Storage resolve failed: HTTP 400". The context resolver answered the made-up token with a
      400 too, and answered 200 with no client token at all. Followed up in `plans/done/refused-client-token-answers-400.md`.
