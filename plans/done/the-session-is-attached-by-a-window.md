# The session is attached to playback by a window, not when the account signs in

Status: **Done** (2026-10-03)
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

As proposed: `AuthViewModel.isSignedIn`'s `didSet` starts the session (`startSession`),
outside any view update and before the sign-in's connect, which `authorizeStreaming` starts
right after setting it. From the review: `LoggedInSessions.start()`, which replaces
`session()`, makes the session and activates its queue service, so a current session is always
a started one, and `AuthViewModel` attaches it to `PlaybackViewModel`; a grant renewed while
signed in finds the session and does nothing (re-attaching the same objects still notified
observers). `ContentView` reads
`sessions.current` and makes nothing; the window's task no longer activates or attaches, and
the modifier lost its queue and track service reads.

## Verification

With throwaways that logged the session's start, showed the login screen while the keychain
kept its grant, and answered the grant with the held one after 2 s (not committed):

- **A sign-in:** the session started at 46.865, with the sign-in; the queue service's first
  update at 47.158, before the connect's `Initialization complete` at 47.532, whose queue it
  hydrated at once (47.537); one service (`svc#1`), no second-session warning. The bar and
  Control Center then named the album's first track.
- **A launch:** the session started at 17.538, the queue service followed at 17.793, the
  connect completed at 19.133; the bar and Control Center named the track.
- The same again on the final code: the session at 36.024 with the sign-in, the queue service at
  36.272, the connect at 36.654; at a launch 53.258, 53.664 and 54.944.
- 624 unit tests pass (two of the session tests became one, as starting now activates).

Left, from the review: the launch's connect still runs from the window's task, after the
profile and start page requests, where a sign-in's runs from `AuthViewModel`. Not filed.
