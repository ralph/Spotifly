# Playback's requests to spclient sign themselves, and miss both retries

Status: **Open**, not planned. Read from the code; nothing observed. Ready to take up: the retries
it would reuse are on main since #123 (2026-10-01).
Components: `Spotifly/SwiftLibrespot/Network/SPClient.swift` (`authorizedRequest`, `getTrack`,
`resolveContext`, `resolveCDNUrl`), `Spotifly/PartnerAPI/PartnerAPI.swift` (`SpotifyCredentials`)
Found: 2026-10-01, in the altitude review of `plans/done/loads-that-fail-while-online.md`

## Summary

Every request the app's pages make to Spotify's own APIs goes through `SpotifyCredentials`,
which asks again once after a 401 with a fresh client token, and again after a 5xx or a dropped
connection. Playback's requests to spclient do not: `SPClient` signs them itself, so a 5xx, a
dropped connection or a refused client token fails a track's start, a context's resolve or a
CDN url at once.

## Problem

- `SPClient.authorizedRequest` repeats `SpotifyCredentials.sign`.
- `getTrack` reports any status but 200 as `trackNotFound`, a 503 included, so a passing server
  error reads as a track Spotify has not got.
- None of them gets the 401 retry, so a client token revoked early fails playback until the
  app relaunches, which `retryingRefusedToken` was written to prevent for the pages.

## Solution

Not planned. Probably: `SPClient` takes a `SpotifyCredentials` and runs its reads through
`retryingRefusedToken` and `retryingPassingFailures`, as `SpclientAPI.get` does. `getTrack` is a
read sent as a POST, so the HTTP method does not decide it. Playback has its own latency
limits: two retries of a second and three are long for a Next, and may want shorter pauses.

## Verification

Not defined yet.
