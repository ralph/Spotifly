# The refresh button does nothing in the Queue section

Status: **Open.** Recorded, not planned.
Components: `Spotifly/ViewModels/NavigationCoordinator.swift` (`canRefreshCurrentSection`),
`Spotifly/Views/LoggedInView.swift` (`refreshCurrentSection`)
Found: 2026-08-15, in a review of the plans. Re-checked 2026-09-29.

## Summary

The toolbar shows a refresh button in the Queue section, and pressing it does nothing.

## Problem

`NavigationCoordinator.canRefreshCurrentSection` returns `true` for `.queue`, so the button is
drawn. `LoggedInView.refreshCurrentSection` has no `.queue` case and falls through to
`default: break`. `.speakers` documents its no-op explicitly; the queue does not. So either a
case is missing or an exclusion is.

## Solution

Not planned. The queue comes from the player's snapshots, not from a fetch the button could
repeat, so leaving `.queue` out of `canRefreshCurrentSection` is the likely answer.

## Verification

The Queue section shows no refresh button, or pressing it visibly reloads the queue,
whichever the solution chose.
