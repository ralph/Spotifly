# A count of one said "1 tracks"

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/*.lproj/Localizable.stringsdict` (new), `Spotifly/*.lproj/Localizable.strings`,
`SpotiflyTests/LocalizationTests.swift`
Found: 2026-10-02, in the review of `plans/done/units-are-written-the-english-way.md`

## Summary

`metadata.tracks` was `"%d tracks"` in English, `"%d Tracks"` in German and `"%d titres"` in
French, with no singular. A playlist with one track said "1 tracks". The review found the queue's
count the same: "1 songs (0 upcoming)". Both keys now have plural forms in a
`Localizable.stringsdict` for each language.

## Problem

`.strings` files have one form per key. Plural forms need a `.stringsdict` entry, or a String
Catalog's plural variations, and a lookup that picks the form by the number.

## Solution

- **`Localizable.stringsdict`** in `en`, `de` and `fr`, with `metadata.tracks` as
  `%#@tracks@`, `one` and `other`: "track"/"tracks", "Track"/"Tracks", "titre"/"titres". The
  key left the three `.strings` files.
- **The helper is unchanged.** `localizedNumberString` resolves the key with
  `String(localized:)`, which hands back the plural format, and `String(format:)` picks the form.
  Measured in German in the test host before choosing:

  | Lookup | 1 | 1007 |
  | --- | --- | --- |
  | `String(format:)`, no locale (the helper) | 1 Track | 1007 Tracks |
  | `String(format:locale:)` | 1 Track | 1.007 Tracks |
  | `String.localizedStringWithFormat` | 1 Track | 1.007 Tracks |

  A locale groups the digits, which the helper exists to avoid. Without one, the plural rule is
  the app's language's: the French app says "0 titre", as French counts zero as one.
- **`LocalizationTests` reads `.stringsdict` keys too**, as part of a language's strings, so
  the key is still found in English and in each language.

- **`queue.song_count %lld %lld`**, the Queue section's "52 songs (50 upcoming)" when no device
  is active, moved to the `.stringsdict` too, as `%1$#@songs@ (%2$lld upcoming)`. `Text` formats
  it from its interpolation, so no code changed.

`show_all.tracks` stays in `.strings`: the link shows only for more than five tracks. No other
string counts something.

## Verification

### Live, in French (2026-10-02)

- "Spotifly test: phase 4 create": "Par llralphj · 1 titre · 4 min".
- "Meine Playlist Nr. 37", empty: "Par llralphj · 0 titre".
- The Queue section, opened by a throwaway hook (not committed) with no device active: "52 titres
  (50 à venir)", so `Text` finds the key in the `.stringsdict` and fills both arguments.

### Unit tests

597 pass, two of them new:
- `a track count takes the language's plural` pins the key's locale: "1 track", "2 tracks",
  "1 Track", "1007 Tracks", "1 titre", "2 titres". It leaves out French zero, since the test
  host's own language picks the rule, and it is German.
- `the queue's song count takes the language's plural`: "1 song (0 upcoming)", "3 songs (2
  upcoming)", "1 Song (0 ausstehend)", "1 titre (0 à venir)".
