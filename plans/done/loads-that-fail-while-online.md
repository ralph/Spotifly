# Loads that fail while the network stays up wait for Try again

Status: **Done** 2026-10-01. Unit tests for the requests, and the artwork retry seen in a
test-host probe against a local server; not seen in the running app, which no server error
was at hand for. See Verification. Split from
`plans/done/failed-loads-wait-for-try-again.md`.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`SpotifyCredentials.retryingPassingFailures`,
`PartnerAPI.query`), `Spotifly/PartnerAPI/PathfinderOperations.swift` (`retriesPassingFailures`),
`Spotifly/PartnerAPI/SpclientAPI.swift` (`get`),
`Spotifly/Views/Components/RetryingAsyncImage.swift`
Found: 2026-09-29, in the altitude review of the artwork fix

## Summary

A load that fails while the network stays up, from a server error, a dropped connection or a
captive portal, was not asked for again: nothing counts as a return. Reads to Spotify's APIs
are now asked for again in place, twice, after 1 and 3 seconds, on a server error or a dropped
connection. Artwork that fails is asked for again after 5 s, 30 s and 3 min, and then left.

## Problem

`NWPathMonitor` reports the path satisfied throughout a server error or a captive portal, so
`NetworkMonitor.returns` never moves. Artwork kept its placeholder until the view was rebuilt,
and a page or list waited for Try again.

## Solution

**Requests: in the one place every request to Spotify's own APIs passes through.**
`SpotifyCredentials` already ran each attempt, and once more after a 401
(`retryingRefusedToken`). `retryingPassingFailures` wraps that for reads:

- **What may pass:** HTTP 5xx; a connection that dropped or could not be made (`URLError`
  `.networkConnectionLost`, `.cannotConnectToHost`); and spclient's CORS preflight refused with
  a 5xx, since it goes first and a server error meets it there.
- **What does not:**
  - anything that answers the same each time, such as a 404 or a 403;
  - a request made with no network at all (`.notConnectedToInternet`), which the network's
    return already retries, so failing at once shows the error at once;
  - a timeout, which has already waited the minute `URLSession` gives it: two more would keep a
    page waiting three, and every caller that joined it in `InFlightRequests` with it;
  - a 429: a rate limit is the whole client's, and eight metadata reads asking again together
    after a second only add to it. Honouring `Retry-After` would need the header carried out
    of the attempt.
- **Not writes, and not the library check.** Each `PathfinderOperation` says whether it is
  retried (`retriesPassingFailures`), so a new write cannot be retried for a forgotten argument:
  the playlist and library mutations are not, since a write that failed may have happened, and
  a save asked again could land after the remove that undid it. Neither is
  `areEntitiesInLibrary`, which every heart on screen asks on its own, and whose failure leaves
  the heart as it was. spclient's `get` retries, and its `send`, which carries the playlist
  writes, the rootlist and the Connect commands, does not.
- **Two retries, after 1 s and 3 s**, so a blip of a few seconds never reaches the page. A
  longer outage still shows the error, with Try again, and the network's return still asks
  again.
- The pause is injected (`pause:`), so the tests do not wait.

**Artwork: `RetryingAsyncImage`**, which every artwork goes through, and which `AsyncImage`'s
own loading bypasses the request layer for. A failed image is asked for again after 5 s, 30 s
and 3 min, then left until the network returns or its url changes. The cap is the point: an
image the CDN answers 404 for would otherwise be asked for forever. A slow image is not
restarted: the timer follows a failed phase, not a missing image. An image that failed with no
network at all counts as loading, and waits for the network's return rather than the timer.

**Not reached: playback's own requests.** `SPClient` (track metadata, the context resolver,
the CDN url) signs its requests itself rather than through `SpotifyCredentials`, so a 5xx there
still fails at once; see `plans/open/playback-requests-skip-the-shared-credentials.md`.

**Not done: a page's own timed retry.** A page or list that failed for longer than the request
retries still waits for Try again or the network's return. Retrying it on a timer would need its
failure to outlive the reload: the error, and the view holding the retry with it, are replaced by
a spinner while a load runs, so a timer there would start over at its first pause each time.

## Verification

- [x] Unit tests (`PassingFailureRetryTests`, 9): a 503 then a 200 uses the 200 after one pause
      of 1 s; a 500 that goes on is reported after three attempts and pauses of 1 s and 3 s; a
      dropped or refused connection is asked again; a 404, a 429, a timeout and a request with
      no network are asked once; a playlist change and a library save are asked once, and so is
      the library check; spclient's read is asked three times, also when its preflight is the
      one refused, and its write once.
- [x] An existing test that used a 500 for "the profile request fails" now uses a 403, which is
      not retried; the test is about the failure, not its kind.
- [x] Build, 482 unit tests and the lint.
- [x] Artwork, in a throwaway test-host probe: `RetryingAsyncImage` rendered against a local
      server that answers a path's first request with a 500. Its phases went `empty`, `error`
      at 0.0 s, then `empty` and `image` at 5.1 s, and the server saw two requests in the nine
      seconds watched.
