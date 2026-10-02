# The now-playing bar is missing on search's "show all" tracks page

Status: **Open**, not planned; cause unknown
Components: `Spotifly/Views/LoggedInView.swift` (`contentRegion`),
`Spotifly/Views/SearchAllTracksView.swift`, `Spotifly/Views/LoggedInContentRouterView.swift`
Found: 2026-10-02, live-checking `plans/open/state-held-twice.md`, phase 1; the same on `main`

## Summary

On the search results page the bar shows, overlaid on the content region. After "Alle 20 Tracks
anzeigen", which pushes `SearchAllTracksView` onto the content router's `NavigationStack`, it is
gone. The accessibility tree has none of its buttons either.

## Problem

The bar is an `.overlay(alignment: .bottom)` on `contentRegion` in `LoggedInView`, which wraps
the content router, so a pushed destination should still be under it. It was seen with a
900×450 window and with a 1400×846 one.

## Solution

Not planned. Start by finding what the pushed page changes about the overlay: its own toolbar,
a safe-area or `contentMargins` difference, or the `NavigationStack` replacing the hosting view.

## Verification

None yet.
