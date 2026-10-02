# Menu commands lose the logged-in session when its window closes

Status: **Open**, not planned, and the window-closed behaviour is **not measured**: it is read
from the code
Components: `Spotifly/SpotiflyApp.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/ViewModels/PlaybackViewModel.swift`
Found: 2026-10-02, in the review of `plans/open/state-held-twice.md`, phase 4

## Summary

The store and the services live in `LoggedInView`'s `@State`, so they belong to the window. A
menu command that needs them reaches them in one of three ways:
- a weak reference in the process-wide `PlaybackViewModel`, for ⌘L;
- a focused scene value, for ⌘R;
- the debug-only `AppStore.current`.

With the window closed, the first is nil and the second is greyed.

## Problem

- **⌘L stays enabled and does nothing.** `PlaybackViewModel.toggleCurrentTrackFavorite()`
  returns early when its weak `trackService` is nil. The same was true of the weak store before
  phase 4.
- **⌘R greys out.** It reads `homeService` as a focused scene value.
- **The comments promise more.** The comments on `PlaybackViewModel.errorMessage` say that media
  keys and ⌘L reach the model with the window closed; for ⌘L that only holds while the window
  exists.

## Solution

Not planned. The general change would be a session object owned by the `App`, holding the store
and the services in place of the window's `@State`. Every menu command could then reach it, and
the three workarounds would go.

## Verification

None yet. First, confirm whether closing the main window frees `LoggedInView`'s state.
