# A count of one says "1 tracks"

Status: **Open**
Components: `Spotifly/*.lproj/Localizable.strings`, `Spotifly/LocalizationFormatting.swift`,
the headers in `AlbumDetailView`, `PlaylistDetailView` and `SearchAllTracksView`
Found: 2026-10-02, in the review of `plans/done/units-are-written-the-english-way.md`

## Summary

`metadata.tracks` is `"%d tracks"` in English, `"%d Tracks"` in German and `"%d titres"` in
French, with no singular. A playlist with one track, such as "Spotifly test: phase 4 create",
says "1 Tracks" in German and "1 tracks" in English.

## Problem

`.strings` files have one form per key. Plural forms need a `.stringsdict` entry, or a String
Catalog's plural variations, and a lookup that picks the form by the number.

## Solution

None yet.

## Verification

None yet.
