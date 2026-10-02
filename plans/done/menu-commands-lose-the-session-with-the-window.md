# The logged-in session went with its window

Status: **Done** 2026-10-02, verified live, except a logout, which needs the user to sign in again
Components: `Spotifly/Store/LoggedInSession.swift` (new), `Spotifly/SpotiflyApp.swift`,
`Spotifly/Views/ContentView.swift`, `Spotifly/Views/LoggedInView.swift`,
`Spotifly/Views/LoggedInLifecycleModifier.swift`, `Spotifly/Store/Services/QueueService.swift`,
`Spotifly/Store/AppStore.swift`
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
  `.onChange` in `LoggedInLifecycleModifier`.

## Solution

- **`LoggedInSession`** holds the store and every service, made as `LoggedInView.init` made
  them.
- **`LoggedInSessions`**, the app's `@State`, injected into the window's environment, makes the
  session the first time a window shows the signed-in app. `ContentView` ends it when
  `isSignedIn` turns false, which every way out of the account passes through, so the next
  sign-in starts from an empty store. The session is read from a view's body, so the holder
  keeps it unobserved.
- **`LoggedInView`** takes the session and reads the services from it. What stays with the
  window is its navigation: `NavigationCoordinator` is still the view's `@State`.
- **`LoggedInLifecycleModifier`'s launch task** runs again when a window reopens on the session.
  Each step does nothing the second time: `QueueService.activate()` and the profile's session
  load guard themselves, `loadHome()` returns once loaded, and the player's initialization is
  `IfNeeded`.
- **`QueueService` passes the store's unplayable tracks to playback**, beside the withheld
  tracks it already passes the other way, where the window's `.onChange` used to. The call is
  injected for a test.
- **The Debug menu** reaches the store through the session, and `AppStore.current` is gone.

Left with the window, as before:
- **⌘R** refreshes the start page the window shows, through its focused scene value.
- **⌘1–⌘4** select the window's sections.
- **The network's return** asks again for what a window shows, through
  `retryingWhenNetworkReturns`: the start page and the queue's metadata.

`PlaybackViewModel` still holds the store and the track service weakly, so ending the session
frees them; while it lasts, ⌘L reaches them.

## Verification

### Live (2026-10-02)

The same run as the measurement, on this branch:
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

615 pass, four of them new:
- every window shows the one session;
- signing out ends it;
- an ended session is freed;
- `QueueService` passes the store's unplayable tracks to playback, as they stand and on a change.
