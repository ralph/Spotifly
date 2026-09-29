# An album, artist or playlist union of an unknown kind reads as "no data"

Status: **Open.** Recorded, not planned. Read from the code in review; `GenericError` measured.
Components: `Spotifly/PartnerAPI/PartnerAPI.swift` (`album(id:)`, `artistUnion`, `playlistPage`),
`Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Views/ArtistDetailView.swift`,
`Spotifly/Views/PlaylistDetailView.swift`, `Spotifly/Views/Components/InlineLoadError.swift`,
`Spotifly/Store/Services/AlbumService.swift`, `ArtistService.swift`, `PlaylistService.swift`
Found: 2026-09-29, in the reviews of `plans/done/playlist-not-found-answers-500.md`

## Summary

Three guards now turn a `NotFound` union into "Spotify can't find this …" with no retry, one per
kind. Every other `__typename` still decodes as a success with nil fields, and the service then
throws "Spotify returned no data", with a Try again. The views each keep a `canRetry` flag beside
their error message by hand.

## Problem

- **One bad name is rejected, instead of the good one accepted.** The home page
  (`PathfinderHome.successTypename`) and the mutations (`PathfinderMutationResult.failure(unless:)`)
  accept only their success name. The album, artist and playlist unions single out `NotFound`.
  - Measured 2026-09-29: a malformed playlist id answers HTTP 200 with `GenericError`, "Failed to
    fetch playlist for uri …, status code: 400 BAD_REQUEST". That reads as "no data", and Try
    again repeats the 400. The app only opens ids Spotify gave it, so this is rare.
  - The guard pair, nil union then `NotFound`, is written out three times.
- **The retry flag lives beside the message.** Album, artist and playlist views each keep
  `errorMessage` and `canRetry` as two `@State`s. Other writers set `errorMessage` without
  `canRetry` (the playlist's delete, unfollow, rename and reorder), so the flag can describe an
  earlier error. Harmless today: after a `NotFound`, nothing on the page can fail again.
- **A page Spotify cannot find is asked for on every visit.** Nothing records the miss, and
  `ensure…Loaded` checks only whether the entity is loaded. Each rebuild of the view asks again
  and gets the same answer. `TrackService.unavailableTrackIds` already remembers such misses for
  tracks.

## Solution

Not planned yet. A likely shape:

1. One helper that takes a union and its kind, and switches on `__typename`: the success name
   (`Album`, `Artist`, `Playlist`) returns it, `NotFound` throws `notFound(kind)`, anything else
   throws an error carrying the name and the union's `message`, which stays retryable. Check the
   success names first: a kind nobody has seen, such as a pre-release album, would become an
   error.
2. A failure value that knows whether it can be retried, built from the error:
   `InlineLoadError(error:retry:)` asking `isRetryable` itself, or a `LoadFailure`. One `@State`
   per view instead of two, in all three views at once.
3. Remember ids Spotify answered `NotFound` for, for the session, and fail fast on them.

## Verification

Not defined yet.
