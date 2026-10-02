# An album's release date is shown as an ISO date in every language

Status: **Open**
Components: `Spotifly/Views/AlbumDetailView.swift`, `Spotifly/Store/Entities.swift` (`Album.releaseDate`)
Found: 2026-10-02, in the review of `plans/done/units-are-written-the-english-way.md`

## Summary

Abbey Road's header says "17 Tracks · 47 min · 1969-09-26" in German, where a German reader
expects "26.09.1969", and an English one "Sep 26, 1969".

## Problem

`Album.releaseDate` is the string the API returned, and `AlbumDetailView` shows it as it is.
Spotify's dates can also be just a year, or a year and month, so it cannot simply be parsed as a
full date.

## Solution

None yet.

## Verification

None yet.
