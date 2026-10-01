# A client token Spotify rejects is answered 400, which the retry for a refused one misses

Status: **Open**, not planned. One live measurement; what a token Spotify revoked or let expire
gets is not known.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`SpotifyCredentials.retryingRefusedToken`),
`Spotifly/Auth/ClientTokenProvider.swift`
Found: 2026-10-01, while verifying `plans/done/playback-requests-skip-the-shared-credentials.md`

## Summary

Every request to Spotify's own APIs is asked again once, with a fresh client token, when it is
answered 401 (`retryingRefusedToken`). That rule was written from reasoning, not from a refusal
seen. The one refusal measured since was a 400 with an empty body, which the rule passes over.

## Problem

The client token is cached for the fortnight Spotify says it is good for. If Spotify stops
taking it before then, every request that carries it fails until the app relaunches. The retry
exists for that, and only fires on a 401.

Measured on 2026-10-01 with a throwaway build that changed the token on one request per path:

| Request | Made-up token | Real token, one character changed | No token |
|---|---|---|---|
| `PUT connect-state/v1/devices/…` | 400 | 400 | – |
| `POST extended-metadata` | – | 400 | – |
| `GET storage-resolve/…` | – | 400 | – |
| `GET context-resolve/…` | 400 | – | 200 |

Every 400 had an empty body. A changed token is not a revoked one: Spotify may well answer a
token it issued and has since revoked, or one past its expiry, with a 401. Neither could be
brought about: there is no revoked token at hand, and one expires after two weeks.

pathfinder (`api-partner`) was not measured. Its 400s for a bad request name the variable they
wanted, in the body.

## Solution

Not planned. Options, once what a revoked token gets is known:

- If it is a 401, nothing to do; record it here and close this.
- If it is a 400, treat a 400 **with an empty body** as a possible refusal, as a 401 is now.
  A bad request to pathfinder names its fault in the body, so it would not be retried; one to
  spclient could cost a second request and a new client token.
- Either way, the client token's age could be shortened, so a revoked one lives days rather than
  a fortnight. It costs one more request to clienttoken.spotify.com per period.

The measurement that would decide it: keep a client token from one launch and use it after it
expires, or after Spotify's clients have been signed out of the account, and log the status.

## Verification

Not defined yet.
