# A client token Spotify rejects is answered 400, which the retry for a refused one missed

Status: **Done** 2026-10-01, stacked on #135. Unit tests, and seen live against Spotify with a
throwaway build that changed the client token. What a token Spotify revoked or let expire gets
is still not known; see Verification.
Components: `Spotifly/Auth/SpotifyCredentials.swift` (`attempt`, `retryingRefusedToken`)
Found: 2026-10-01, while verifying `plans/done/playback-requests-skip-the-shared-credentials.md`

## Summary

Every request to Spotify's own APIs was asked again once, with a fresh client token, when it
was answered 401 (`retryingRefusedToken`). That rule was written from reasoning, not from a
refusal seen. The refusals measured are a 400 with an empty body and a header naming the client
token as the fault, which the rule passed over. A response with that header is now taken as a
refusal too.

## Problem

The client token is cached for the fortnight Spotify says it is good for. If Spotify stops
taking it before then, every request that carries it fails until the app relaunches. The retry
exists for that, and only fired on a 401.

Measured on 2026-10-01 with throwaway builds that changed the token on one request per path:

| Request | Made-up token | Real token, one character changed | No token |
|---|---|---|---|
| `POST api-partner …/pathfinder/v2/query` | – | 400 | – |
| `PUT connect-state/v1/devices/…` | 400 | 400 | – |
| `POST extended-metadata` | – | 400 | – |
| `GET storage-resolve/…` | – | 400 | – |
| `GET context-resolve/…` | 400 | 400 | 200 |
| `GET metadata/4/track/…` | – | **200** | – |

Every 400 had an empty body and the header `client-token-error: INVALID_CLIENTTOKEN`. The
`metadata/4` reads the pages make took the changed token. The web player's own scripts were no
help: none of the 70 it loaded names `client-token-error` or `CLIENTTOKEN`.

## Solution

**The header decides, not the status.** `SpotifyCredentials.attempt` reads `client-token-error`
from the response into the `Attempt`, and `retryingRefusedToken` drops the token the request
carried and asks once more, with a fresh one, when the header is there, as it does after a 401.
A 400 without it is a bad request, which asking again would not mend, so it is not retried.
Only a failure counts: a header on a 2xx would not drop a token that worked. Every client goes
through it: the pages, playback's reads and the dealer's state report.

**Not done: a 401 still drops the client token.** A 401 can be either credential, and the only
one recorded here was the bearer's. Dropping the bearer instead, when no header names the
client token, would need `KeymasterSession` to drop a refused bearer, which it cannot yet. Left
until a 401 is seen that is not the bearer's expiry.

**Not done: renewing the token sooner.** The granted token carries `refresh_after_seconds`
(field 3) besides `expires_after_seconds` (field 2): 1,209,600 and 1,216,800 when measured, two
hours apart on a fortnight. librespot caches the token for `refresh_after_seconds`
(`SpClient::client_token`, read 2026-10-01). `ClientTokenProvider` asks for a token whenever
the cached one has expired by field 2, before each use, so a token is never used past its
expiry, and renewing two hours earlier would not shorten the life of a revoked one.

## Verification

- [x] Unit tests (`SPClientRequestTests`): the refused-token test runs over a 401 and over a
      400 with `client-token-error`, each dropping the client token it carried and asking the
      CDN url again; a 400 without it is `requestFailed(…, 400)` after one request, with
      nothing dropped; the write table has a row for the refusal, asked again too.
- [x] Build, 518 unit tests and the lint.
- [x] Live (2026-10-01), a throwaway build that changed the client token on the first request
      to each path, with `SPOTIFLY_DEBUG_AUTOPLAY=1` and two Nexts: pathfinder's first query, the
      first state report, the context resolve, the first track metadata and each CDN url were
      answered 400 with `INVALID_CLIENTTOKEN`, logged as refused, and answered 200 on the second
      attempt. All three tracks played.
- [ ] A token Spotify revoked or let expire: not at hand. If its refusal carries no
      `client-token-error`, and is no 401, it still fails until the app relaunches.
