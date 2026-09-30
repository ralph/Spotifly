# A remote play of a bare track list plays nothing

Status: **Done** 2026-09-29 (#84). Built, unit-tested, and both live checks passed on `0dd7076`
the same day; see Verification. The sending side has a plan of its own:
`plans/done/plays-sent-to-a-librespot-device.md`.
Components: `Spotifly/SwiftLibrespot/Dealer/DealerConnection.swift` (`parseCommand`, `play`),
`Spotifly/SwiftLibrespot/Dealer/DealerMessage.swift` (`PlayCommand`),
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`playTracks`, the remote `.play`
command, `takeOver`)
Found: 2026-09-29, in the review of #79. Recorded as "starts at its first track"; it plays
nothing at all.

## Summary

Another device can ask this one to play a list of tracks that no album or playlist names. Such a
command did nothing here. The parser looked for the list under a top-level `uris` key that no
sender uses. The real shape carries the tracks inside the context, which has no uri. Now that
list is read and played from the track the command names, by the rule every other start follows
since #79. A handover of such a list uses the same rule.

## Problem

### Where a bare list is sent

A context with no uri, its tracks inline under `pages[].tracks[]`:

- **The Web API.** librespot added `PlayContext::Tracks` for it in #1468 (2025-05-04): "Re-Add
  ability to handle/play tracks". A `PUT /me/player/play` with `uris` arrives that way, with
  `offset` as the `skip_to`. librespot plays it as the context `spotify:web-api`.
- **This app.** `ConnectCommand.play(trackUris:)` sends `uri: ""`, `url: ""` and the pages.
  Play Tracks, under Search's "Show all tracks", sends it when another device is playing, so one Spotifly playing a list on
  another took this path.
- **Spotify's own clients:** not seen sending one. The web player names its ad-hoc lists
  (`spotify:list:recent searches:default`, for example), and the iPhone sends a playlist's uri
  with its first page beside it (a librespot log of 2026-01-16). Both have a uri, so they are
  resolved as before.

The web player's own empty context is `{ pages: [], uri: "", url: "" }`, so an empty uri is how
Spotify's clients spell "no uri".

### What the parser did

`parseCommand` read `context.uri`, `skip_to`, and a top-level `uris`. A context of `uri: ""` and
pages came out as an empty context uri, no track and no list. `executeRemoteCommand` then matched
none of its branches, and the command was dropped.

`uris` has been there since the Swift port (#65). Neither librespot's `PlayCommand` nor
go-librespot's reads such a field.

### The two starts that chose on their own

- **`playTracks`** always started at index 0 and took no `skip_to`, so a list, once read,
  would have started at its first track whatever the sender named.
- **`takeOver`**, for a handover of a bare list, chose by hand: the list if it held the
  current track, otherwise the track **alone**, dropping the rest.

## Solution

1. **Read the list.** Without a uri, or with an empty one, `parseCommand` reads
   `context.pages[].tracks[].uri`, every page in order, as the list. With a uri, the pages are
   only a window of the context, and are ignored as before: the context is resolved.
   `PlayCommand.context` says which, as librespot's `PlayContext` does: `.uri` or `.tracks`.
   The top-level `uris` is gone, and with it `trackUriIfTrack`: a track sent as the context is
   played as its own context, as before.
2. **`playTracks(_:trackIndex:startingAtUri:positionMs:paused:)`** starts through
   `PlaybackQueue.start(in:index:uri:)`. The track decides, and one the list lacks goes in at
   the index.
3. **Both callers use it.** The remote `play` is now a switch on the context, `play` or
   `playTracks`, each with `skip_to`'s index and track. `takeOver` passes the handed-over
   track, so one missing from the list plays first and the list follows, rather than playing
   alone.
4. `PlayCommand` is `nonisolated`, like `TransferState`, so the tests can read it.

Not changed:

- `resume()` of a mirrored bare list still rebuilds it as the current track and the next
  tracks, without the history.
- `takeOver` and `resume()` still decide "an empty context uri is a bare list" themselves, from
  `TransferState.contextUri` and the mirrored queue. `TransferState` could expose the same
  `Context` enum; that is transfer parsing, outside this plan.

## Verification

- [x] Unit tests, `PlayCommandTests`, six cases: the iPhone's playlist play (the uri wins over
      its page), a clicked album row (track, index and seek), a context with no uri and two
      pages, an empty uri, the list this app sends read back through the parser, and a track
      sent as the context. Against the old parser the three list cases fail: nothing was read.
- [x] The start rule itself is `ContextStartTests`, from #79.
- [x] Build, unit tests and `swiftformat --swiftversion 6.4 --lint .`, 2026-09-29.
- [x] Live, a bare list sent to the Mac. **The two-instance step first written here could not
      work:** a Spotifly that can play keeps a play for itself (`PlaybackViewModel.playbackTarget`),
      so instance A would have played the list and sent B nothing. The Web API's
      `PUT /me/player/play` with `uris` answered 429 to the web player's token. So the command
      went from Chrome, with the web player's token, to
      `connect-state/v1/player/command/from/…/to/<the Mac>`: `context: {uri: "", url: "",
      pages: [{tracks: [Gold Lion, Girlfriend, The Diamond Church Street Choir]}]}` and
      `options.skip_to: {track_uri: <the third>, track_index: 2}`. **Passed** on `0dd7076`,
      2026-09-29: `Remote command: play(… Context.tracks([…3…]), trackUri: …7ue34Zx…, index: 2)`,
      then `Playing spotify:track:7ue34ZxB8zyetZ0BCiIrn2`.
- [x] Live, handover: the same list sent starting at Gold Lion, handed to a phone from Speakers,
      and taken back after about ten seconds. **Passed**, same day: the phone sent
      `TransferState(contextUri: "", contextTrackUris: [the three], currentTrackUri: Gold Lion,
      positionAsOfTimestamp: 53126)`, and the Mac took over at 65391 ms, where the phone had got
      to, with the other two tracks after it in the queue.
- Seen along the way: the queue's header went on naming the album played before ("Alive"),
  since `AppStore.setQueue` ignores an empty context uri. Recorded as
  `plans/done/queue-header-names-the-previous-context.md`.
