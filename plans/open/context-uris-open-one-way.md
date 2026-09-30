# A context's uri is turned into a page in two places, and this Mac does not name its own

Status: **Open**, not planned. From the altitude review of
`plans/done/queue-header-names-no-liked-songs.md`; read from the code, nothing observed.
Components: `Spotifly/Views/QueueListView.swift` (`ContextLink`, `navigate(to:)`),
`Spotifly/Views/LoggedInLifecycleModifier.swift` (`SPOTIFLY_DEBUG_OPEN`),
`Spotifly/Models/Route.swift`, `Spotifly/SwiftLibrespot/Connect/SpircController.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`SpircPlayerState`)
Found: 2026-09-30, in the review of the queue header's context name

## Summary

Two small things the header fix left as they were.

## Problem

- **Two uri-to-page mappings.** The queue header's `ContextLink` and `navigate(to:)` turn a
  context uri into a page. `SPOTIFLY_DEBUG_OPEN` does the same with its own chain of
  `SpotifyURI.id(from:kind:)` calls. Only the header knows that `LikedSongs.uri` is Favorites;
  the debug hook would open it as a playlist page. The next link from a uri, such as the
  now-playing bar's context or a deep link, would make a third. `Route` and `Selection` already
  model the pages.
- **This Mac's own cluster state names no context.** `SpircController` builds the reported
  `PlayerState` from `SpircPlayerState` and never fills `contextMetadata`, though the field is
  there and serialized (field 21). librespot copies the resolved context's metadata into its
  player state. The name is at hand since the header fix (`LibrespotClient.contextName`). Not
  measured whether the web player or a phone shows this Mac's context without it; they may look
  albums and playlists up themselves.

## Solution

Not planned. A `Route(uri:)` beside `Route` in `Route.swift`, used by both mappings. For the
report, first look at how the web player and a phone name a context this Mac plays; if they miss
it, carry the resolver's metadata into `SpircPlayerState`, as librespot does.

## Verification

Not defined yet.
