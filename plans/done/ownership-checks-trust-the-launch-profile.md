# Owner-only actions depended on the launch's profile request

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Store/Services/ProfileService.swift` (`loadForSession`),
`Spotifly/Views/LoggedInLifecycleModifier.swift`, `SpotiflyTests/PlaylistServiceTests.swift`
Found: 2026-10-02, in the review of `plans/done/state-held-twice.md`, phase 4

## Summary

Whether a playlist is the user's is decided by comparing its `ownerId` with `store.userId`, read
synchronously, and only the launch and the network's return fetched the profile for that. A
launch request that failed while the network stayed up left the owner-only actions missing until
a relaunch. The launch's load now asks again, after growing pauses, until a request answers.

## Problem

These read `store.userId` without asking `ProfileService`:
- `TrackContextMenu` (Remove from this playlist, and the owned playlists under Add to playlist);
- `PlaylistDetailView` (owner-only actions);
- `LoggedInToolbars` (Edit Details, cover, Delete).

A failure that may pass soon, a 5xx or a dropped connection, was already asked again inside the
request (`SpotifyCredentials.retryingPassingFailures`, #123). Anything else, or one that had not
passed in those seconds, was asked again only when the network returned. So until a relaunch the
owner-only actions were missing, and Add to playlist offered no playlists. A playlist write itself
still worked, because it fetches the profile through `ProfileService.require()`.

## Solution

`ProfileService.loadForSession()`, which the launch calls where it called `reload()`:
- **The first attempt** is made at once, and the launch waits for it as long as it did.
- **After a failure,** a background task asks again after 5 s, 30 s, 2 min, then every 5 min,
  until a request answers.
- **It stops** when any request answers: its own, a write's `require()`, or the network's
  return, which still asks at once. An answer with a profile that has no name counts, since
  asking again would not change it.
- **Offline, it skips** a timed attempt, which could only fail; the network's return asks.
- **It ends with the session:** the task holds the service weakly, and the service's
  `isolated deinit` cancels it.

The network's return now asks through the service too, `askAgain()` while `needsProfile`, where
the lifecycle modifier had its own wrapper and its own test of "done", `store.userProfile ==
nil`, which a nameless profile never left. The wait and the network are injected, so the tests
do not wait.

Considered and not done: the three views asking `ProfileService` themselves, like a write does.
That is three call sites for one fact the session can keep.

## Verification

### Live (2026-10-02)

A throwaway, not committed, made the first profile request throw `URLError(.badServerResponse)`,
which is not asked again inside the request. Then Playlists, with the user's own "Spotifly test:
phase 4 create" selected.

- **Before (main, `222fc28`):** after the failure, nothing asked again. 25 s on, the sidebar's
  profile button still said "Profil" with no name, and the playlist's toolbar had no Edit
  Details, cover or Delete.
- **After:** `Profile unavailable: …; asking again in 5 s`, then 5.07 s later
  `profileAttributes` and `Profile loaded on asking again`. The sidebar said "llralphj", and the
  toolbar showed the pencil, the cover menu and the bin.
- **After the review's changes, two requests failing:** the launch's failed, the one 5 s later
  failed, and the one 30 s after that loaded the profile.

### Unit tests

608 pass, four of them new:
- the session's load asks again until a request answers, and then stops (two failures, three
  requests);
- it stops when another request answers first, without a request of its own;
- offline, it makes no request on its timed wakes;
- a second call makes no second load.
