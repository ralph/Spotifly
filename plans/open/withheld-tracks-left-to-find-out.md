# What finding out a withheld track by loading it still costs

Status: **Open**, not planned. What is left of `plans/done/unplayable-track-attempts-cost-and-show.md`
once a withheld track stopped being shown. Read from the code; nothing observed.
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
- **spclient's metadata is not read for it.** A track hydrated only through spclient, such as
  a queue entry from a context the app never listed, is not greyed. `/metadata/4` has
  `restriction { countries_allowed: "" }` and no `alternative` for a withheld track, but a
  relinked one has the same restriction with an alternative and plays. Reading it needs the
  account's country, which only the accesspoint has.
- **Files the player cannot decode.** A track whose files are all MP3, AAC or FLAC throws
  `trackNotFound("No Ogg Vorbis file available")`, which is not skipped, so auto-advance
  stops there. Spotify has not been seen to serve such a track to a Premium account.
- **A failed transfer reports twice.** `loadAndPlay` gives up playback through
  `playbackFailed`, and `takeOver`'s catch releases again. The cost is one extra PutState.

## Solution

Not planned.

## Verification

Not defined yet.
