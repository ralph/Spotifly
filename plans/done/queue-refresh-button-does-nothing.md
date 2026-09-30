# The refresh button does nothing in the Queue section

Status: **Done** 2026-09-29. Built and unit-tested; not yet seen in the running app; see
Verification.
Components: `Spotifly/ViewModels/NavigationCoordinator.swift` (`canRefreshCurrentSection`),
`Spotifly/Views/LoggedInView.swift` (`refreshCurrentSection`), `Spotifly/Views/LoggedInToolbars.swift`
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
the cluster. There is nothing the button could fetch again, so neither shows it now.

The cause was two lists that had to agree and did not: `canRefreshCurrentSection` said where
the button showed, and `refreshCurrentSection` said what it did, with a `default: break`. They
are one switch now. `LoggedInView.refreshAction(for:)` returns the section's refresh, or nil,
and the toolbar draws the button only for a non-nil action. The switch names every section and
has no `default`, so a new section does not compile until someone decides whether it refreshes.
`canRefreshCurrentSection` and its test assertion are gone, and so is `queue.refresh`, a string
nothing used.

## Verification

- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, exit 0. The coordinator
      test that asserted Favorites could refresh went with the property; the switch is what
      decides now, and the compiler checks it.
- [ ] Live: the Queue and Speakers sections show no refresh button in the toolbar. The Queue
      keeps its scroll-to-current button. Playlists, Albums, Artists and Favorites still show
      the refresh button, and it reloads the list.
