# Loads that fail while the network stays up wait for Try again

Status: **Open**, not planned. Split from `plans/done/failed-loads-wait-for-try-again.md`; read
from the code, nothing observed.
Components: `Spotifly/NetworkMonitor.swift`, `Spotifly/Views/Components/RetryingAsyncImage.swift`,
`Spotifly/Views/Components/InlineLoadError.swift`
Found: 2026-09-29, in the altitude review of the artwork fix

## Summary

A load that fails while the network stays up, from a server error or a captive portal, is not
asked for again: nothing counts as a return.

## Problem

`NWPathMonitor` reports the path satisfied throughout a server error or a captive portal, so
`NetworkMonitor.returns` never moves. Artwork keeps its placeholder until the view is rebuilt, and
a page or list waits for Try again, as it always did.

## Solution

Not planned. It would need a retry that does not depend on the network, with a backoff, and only
for failures that may pass: an image a CDN answers 404 for would otherwise be asked for forever.

## Verification

Not defined yet.
