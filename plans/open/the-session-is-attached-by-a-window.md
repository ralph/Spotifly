# The session is attached to playback by a window, not when the account signs in

Status: **Open**, small
Components: `Spotifly/ViewModels/AuthViewModel.swift` (`isSignedIn`),
`Spotifly/Store/LoggedInSession.swift` (`LoggedInSessions`),
`Spotifly/Views/ContentView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`
Found: 2026-10-03, in the altitude review of
`plans/done/the-bar-and-the-view-model-each-look-up-the-track.md`

## Summary

The signed-in account's session is made the first time a window shows it
(`LoggedInSessions.session()`, from `ContentView`'s body), and handed to playback by that window's
first task (`LoggedInLifecycleModifier`): `queueService.activate()` and
`PlaybackViewModel.attach(store:trackService:)`. The session outlives windows since #177, but
its start is still a window's.

## Problem

- **A sign-in's connect starts before the window's task runs:** `AuthViewModel` signs in and
  connects at once, and the window's task runs after its first frame. Until then the queue
  service does not follow the player and `PlaybackViewModel` has no store, so a report that
  arrives in between is not hydrated, and Control Center has no title for it.
- **Nothing visible comes of it today**, since the connect takes longer than the first frame.
  But the comment in the modifier ("before the first `await`, so no Spirc notification can
  arrive while the player is unobserved") promises an order that only holds by timing.
- The attach cannot simply move into `session()`: that runs in a view's body, where changing
  observed state is not allowed, and a session's construction has to stay inert
  (`ActivationRegistry`).

## Solution

Proposed: the session starts when the account signs in. `AuthViewModel.isSignedIn`'s `didSet`,
which already ends it, makes it, activates the queue service and attaches it to
`PlaybackViewModel`, outside any view update and before the sign-in's connect. `ContentView`
reads the session (`sessions.current`) without making one, and the window's task no longer
attaches.

## Verification

A launch and a sign-in (the faked one, without the browser): the queue service's first update
and the bar's and Control Center's titles, with the session attached before the connect.
