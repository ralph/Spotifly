# An album's release date was shown as an ISO date, and more precisely than Spotify knows it

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/PartnerAPI/PathfinderAlbum.swift` (`releaseDate(isoString:precision:)`),
`Spotifly/PartnerAPI/PathfinderSearch.swift`, `Spotifly/PartnerAPI/PathfinderArtist.swift`,
`Spotifly/PartnerAPI/PathfinderEntities.swift`, `Spotifly/Store/Entities.swift`
(`formatReleaseDate`), `Spotifly/Views/AlbumDetailView.swift`, `SpotiflyTests/ReleaseDateTests.swift`
Found: 2026-10-02, in the review of `plans/done/units-are-written-the-english-way.md`

## Summary

Abbey Road's header said "17 Tracks · 47 min · 1969-09-26" in German, where a German reader
expects "26. Sept. 1969". And an album Spotify dates only to a year said "1971-01-01". The date
is now kept as precise as Spotify knows it and written in the app's language: "26. Sept. 1969",
"1971".

## Problem

- **The ISO day in every language.** `Album.releaseDate` is a string, and `AlbumDetailView`
  showed it as it was.
- **A day Spotify never said.** Spotify writes a date it only knows the year of as that year's
  first of January, with a precision beside it. Measured 2026-10-02 on Rodriguez, "Coming From
  Reality", in both `getAlbum` and `libraryV3`:
  `{"isoString":"1971-01-01T00:00:00Z","precision":"YEAR"}`. Three of the account's 46 saved
  albums are dated this way. The decoders cut the timestamp at the `T` and dropped the precision,
  so the header said "1971-01-01". Comments said the views render a year; the album header never
  did.

## Solution

- **Stored to its precision.** `releaseDate(isoString:precision:)` cuts the timestamp to
  `YYYY-MM-DD` for `DAY`, `YYYY-MM` for `MONTH` and `YYYY` for `YEAR`, and keeps the day for a
  precision it does not know. The three date decoders read `precision` and use it:
  `getAlbum`'s, `libraryV3`'s and search's (`PathfinderAlbum`), and the artist page's in either
  of its two shapes. Search's `{year}` stays the year.
- **Shown in the app's language.** `formatReleaseDate(_:locale:)` writes a day as "Sep 26, 1969",
  "26. Sept. 1969" or "26 sept. 1969", a month as "Sept. 1969", and a year as "1969", from
  `Date.FormatStyle` in UTC, so no time zone moves the day. Anything it cannot read is shown as
  it came. `AlbumDetailView` uses it.

The artist page shows the first four characters of the same string, a year, as before.

## Verification

### Live, in German (2026-10-02)

- **Before (`main`):** "Coming From Reality" said "10 Tracks · 40 Min. · 1971-01-01".
- **After:**
  - "Coming From Reality": "10 Tracks · 40 Min. · 1971".
  - Abbey Road: "17 Tracks · 47 Min. · 26. Sept. 1969".

A throwaway log, not committed, read the raw `getAlbum`, `libraryV3` and artist responses for the
measurement. The Beatles' 53 releases and Bach's are all dated to the day; the account's albums
were where the coarse ones turned up.

### Unit tests

605 pass. `ReleaseDateTests` is new:
- the cut for each precision, and for none;
- the `getAlbum`, `libraryV3` and artist-overview shapes keeping a coarse date coarse;
- a day in English, German and French, with Foundation's spaces read as plain ones;
- a month ("Mai 1971") and a year;
- an unreadable date shown as it came.
