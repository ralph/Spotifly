# What finding out a withheld track by loading it still costs

Status: **Open**, in part. spclient's metadata is read for it since 2026-10-01, seen in the
running app; see Progress. The other three are weighed there and left. What is left of
`plans/done/unplayable-track-attempts-cost-and-show.md` once a withheld track stopped being shown.
Components: `Spotifly/SwiftLibrespot/Public/AutoAdvance.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`takeOver`, `loadAndPlay`),
`Spotifly/SwiftLibrespot/Audio/AudioPipeline.swift` (`fileToPlay`),
`Spotifly/PartnerAPI/SpclientEntities.swift`
Found: 2026-09-29, in the reviews of #57 and of its follow-up

## Summary

A track nobody fetched ahead is still found out by its metadata request, one per attempt. Since
the done plan above that is all an attempt costs, and nothing is shown or reported for it. Four
smaller things remain.

## Problem

- **A run costs a request each, with no cap.** `AutoAdvance.run` tries as many tracks as the
  queue holds, each with one extended-metadata request, 16 to 44 ms each in this session's
  logs. A context of many withheld tracks in a row is tried one by one. The endpoint takes a
  batch, so the next few could be asked for at once.
- **spclient's metadata is not read for it:** done; see Progress. A track hydrated only through
  spclient, such as a queue entry from a context the app never listed, was not greyed.
- **Files the player cannot decode.** A track whose files are all MP3, AAC or FLAC throws
  `trackNotFound("No Ogg Vorbis file available")`, which is not skipped, so auto-advance
  stops there. Spotify has not been seen to serve such a track to a Premium account.
- **A failed transfer reports twice.** `loadAndPlay` gives up playback through
  `playbackFailed`, and `takeOver`'s catch releases again. The cost is one extra PutState.

## Solution

Not planned.

## Verification

Not defined yet.

## Progress

- **spclient's metadata** (2026-10-01).
  - **No country needed.** The request asks with `market=from_token`, so the answer is already
    the account's market. A throwaway log, never committed, of the 52 tracks a Liked Songs queue
    hydrated: 18 had `restriction: [{countries_allowed: ""}]`, allowed nowhere, and 17 of those
    had an `alternative`, relinked releases that play ("Today Is a Gift" among them). The one
    without was "Girlfriend (feat. Dâm-Funk)", the library's one track pathfinder calls
    `COUNTRY_RESTRICTED`, which has no file to play. No restriction named a catalogue or a
    forbidden list.
  - **So:** `SpclientTrack.isWithheld` is a restriction allowed nowhere with no alternative, and
    `Track(spclient:id:)` makes it `.unplayable(reason: "COUNTRY_RESTRICTED")`, as pathfinder
    names it. The store's `upsertTracks` already hands every unplayable track to playback.
  - **Seen:** Liked Songs started two tracks before Girlfriend, so the app had not listed it and
    the fetch-ahead had not reached it. The queue's hydration fetched it from spclient and its
    row was greyed before anything loaded it. Two Nexts went from "Today Is a Gift" straight to
    "Tilted": no metadata request for Girlfriend, and no "Skipped" in the bar.
- **Weighed and left:**
  - **A batch for a run of withheld tracks.** Tracks from the queue's hydration are now known
    before a run reaches them, so a run asks only for tracks nobody hydrated, and each costs
    16 to 44 ms. A batch would pay only for several in a row, not seen in any library here, and
    would need a metadata cache in the pipeline so the playable one is not asked for again.
  - **Files the player cannot decode.** Not seen for a Premium account. Skipping such a track
    would need its own message, since it is not Spotify withholding it.
  - **A failed transfer reports twice.** One extra PutState. Telling `takeOver`'s catch whether
    the load had already given playback up needs state carried out of `loadAndPlay` for that
    alone.

