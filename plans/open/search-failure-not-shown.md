# A search that fails says nothing

Status: **Open**, not planned. Split from `plans/done/list-failures-the-retry-cannot-see.md`; read
from the code, nothing observed.
Components: `Spotifly/Store/Services/SearchService.swift`, `Spotifly/Views/LoggedInView.swift`
(`performSearch`), `Spotifly/Store/AppStore.swift` (`searchErrorMessage`)
Found: 2026-09-30, in the review of the network-return retry

## Summary

A submitted search that fails, offline or on a server error, leaves the app where it was. The
error is kept in `searchErrorMessage`, which only a debug log reads.

## Problem

`performSearch` navigates to the results only when there are some. A failure sets
`searchErrorMessage` and nothing else happens: no message, no results, no Try again.

## Solution

Not planned. It needs a place to say it: the search field lives in the toolbar, and the results
section opens only for a query with results. Retrying a submitted search by itself when the
network returns is doubtful, since the user may have moved on; showing the error comes first.

## Verification

Not defined yet.
