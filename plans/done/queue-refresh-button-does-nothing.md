# The refresh button does nothing in the Queue section

Status: **Done** 2026-09-29. Built and unit-tested; not yet seen in the running app; see
Verification.
Components: `Spotifly/ViewModels/NavigationCoordinator.swift` (`canRefreshCurrentSection`),
`Spotifly/Views/LoggedInView.swift` (`refreshCurrentSection`)
Found: 2026-08-15, in a review of the plans. Re-checked 2026-09-29.

## Summary

The toolbar showed a refresh button in the Queue section, and pressing it did nothing. Speakers
had the same button, and it did nothing too. Neither section shows it now.

## Problem

`NavigationCoordinator.canRefreshCurrentSection` returned `true` for `.queue` and `.speakers`,
so the button was drawn. `LoggedInView.refreshCurrentSection` had no `.queue` case and fell
through to `default: break`. Its `.speakers` case was an explicit `break`, "the device list is
pushed from the cluster", since #51 moved Speakers off the Web API. So in both sections the
button was offered and did nothing.

## Solution

Both sections come from state the player pushes: the queue from its snapshots, Speakers from
the cluster. There is no fetch the button could repeat, so `canRefreshCurrentSection` now names
only the four library sections that `refreshCurrentSection` reloads: Playlists, Albums, Artists
and Favorites. The explicit Speakers no-op is gone with it, and the switch's `default` says why
nothing else needs a case.

## Verification

- [x] Unit test: the queue, Speakers, the start page and the profile offer no refresh. The
      existing test still has Favorites offering it.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0.
- [ ] Live: the Queue and Speakers sections show no refresh button in the toolbar. The Queue
      keeps its scroll-to-current button. Playlists, Albums, Artists and Favorites still show
      the refresh button, and it reloads the list.
