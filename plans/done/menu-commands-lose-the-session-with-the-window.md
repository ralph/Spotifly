# The logged-in session went with its window

Status: **Done** 2026-10-02, verified live; the logout and sign-in by the user on 2026-10-03,
whose log showed a fresh store after the sign-in (`store:81`, then `store:691`)
Components: `Spotifly/Store/LoggedInSession.swift` (new), `Spotifly/SpotiflyApp.swift`,
`Spotifly/ViewModels/AuthViewModel.swift`, `Spotifly/Views/ContentView.swift`,
`Spotifly/Views/LoggedInView.swift`, `Spotifly/Views/LoggedInLifecycleModifier.swift`,
`Spotifly/Store/Services/QueueService.swift`, `Spotifly/Store/AppStore.swift`, `AGENTS.md`
Found: 2026-10-02, in the review of `plans/done/state-held-twice.md`, phase 4

## Summary

The store and the services lived in `LoggedInView`'s `@State`, so they belonged to the window.
Closing the window, which leaves the app running and playing, freed them. A `LoggedInSession`,
owned by the app for as long as the account is signed in, now holds them, and a window shows it.

## Problem

### Measured (main, `f53ccfb`, 2026-10-02)

The silent librespot test device played an album, Spotifly mirrored it, and a throwaway hook
closed the window 20 s in. A throwaway log in `AppStore`'s `deinit` said `AppStore freed` the
moment the window closed. When the device moved to the album's second track, Control Center's
Now Playing, read with `MRNowPlayingRequest`, had the title "Spotifly", no artist and no artwork.

`PlaybackViewModel`, which lives as long as the process, reads the current track's metadata
from the store it holds weakly, and finds none, so it publishes its placeholder title. With the
store, `QueueService` went too, so nothing fetched the queue's metadata any more.

### Read from the code

- **⌘L stayed enabled and did nothing:** `toggleCurrentTrackFavorite()` returns early when its
  weak `trackService` is nil.
- **The comments promised more:** `PlaybackViewModel.errorMessage` says media keys and ⌘L reach
  the model with the window closed.
- **The Debug menu's store dump** reached the store through a debug-only `AppStore.current`.
- **Playback stopped hearing the lists' unplayable tracks** with the window closed: that was an
  `.onChange` in `LoggedInLifecycleModifier`. So was asking again for the queue's metadata when
  the network returned.
- **A grant revoked with the window closed went unheard:** `AuthViewModel`, the one listener,
  was the window's `@State`.

## Solution

- **`LoggedInSession`** holds the store and every service, made as `LoggedInView.init` made
  them.
- **`LoggedInSessions`** makes the session the first time a window shows the signed-in app, and
  ends it when `AuthViewModel.isSignedIn` turns false, which every way out of the account
  passes through: the logout, a grant found revoked, a launch that finds no grant. The next
  sign-in starts from an empty store. The session is read from a view's body, so the holder is
  not observed.
- **`AuthViewModel` is the app's**, the `App`'s `@State`, injected into the window, and holds
  the sessions: their lifetime is the sign-in's. Kept per window, as the review found, a grant
  revoked with the window closed would go unheard and leave the old session for the next
  sign-in, which could be another account's. There is none in the unit-test host, where its
  grant would sign the developer in.
- **`LoggedInView`** takes the session and reads the services from it, and
  `environment(session:)` injects them all. What stays with the window is its navigation:
  `NavigationCoordinator` is still the view's `@State`.
- **`LoggedInLifecycleModifier`'s launch task** runs again when a window reopens on the session.
  Each step does nothing the second time: `QueueService.activate()` and the profile's session
  load guard themselves, `loadHome()` returns once loaded, and the player's initialization is
  `IfNeeded`.
- **`QueueService` passes the store's unplayable tracks to playback**, beside the withheld
  tracks it already passes the other way, where the window's `.onChange` used to, and asks again
  for the queue's metadata when the network returns. The call and the network are injected for
  tests.
- **`ActivationRegistry`** keeps its check, a second live `QueueService`, which now means a second
  live session; its comments say so.
- **The Debug menu** reaches the store through the session, and `AppStore.current` is gone.

Left with the window, as before:
- **⌘R** refreshes the start page the window shows, through its focused scene value.
- **⌘1–⌘4** select the window's sections.
- **The network's return** asks again for the start page and the profile through
  `retryingWhenNetworkReturns`; the profile also asks by itself (`ProfileService.loadForSession`).

`PlaybackViewModel` still holds the store and the track service weakly, so ending the session
frees them; while it lasts, ⌘L reaches them.

## Verification

### Live (2026-10-02)

The same run as the measurement, on this branch, after the review's changes:
- No `AppStore freed` when the window closed. At the device's next track, the session's
  `QueueService` (`svc#1`) logged the new queue and `11 of 11` tracks with metadata, and Control
  Center's title was "Sunny Baby", the second track.
- **Reopening the window** (`open` on the running app): the start page and the bar's "Sunny
  Baby" showed at once. The only request was the hearts' `areEntitiesInLibrary`: no start page,
  no profile.
- **Debug → Dump Store to Clipboard:** 139 KB of the session's store. The clipboard was put back
  as it was.

Not checked live:
- **⌘L with the window closed:** it would save or remove a track in your library. It reaches
  the same session whose store the run above saw alive.
- **A logout:** signing in again is yours to do. A unit test checks that ending the session
  frees it.

### Unit tests

617 pass, six of them new:
- every window shows the one session;
- signing out ends it;
- an ended session is freed, and so is one whose queue service was activated: its observations
  hold the store until the service's `deinit` cancels them;
- `QueueService` passes the store's unplayable tracks to playback, as they stand and on a change;
- the network's return asks again for the queue's metadata a failed fetch left missing.
