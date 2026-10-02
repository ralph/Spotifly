# A count of one said "1 tracks"

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/*.lproj/Localizable.stringsdict` (new), `Spotifly/*.lproj/Localizable.strings`,
`SpotiflyTests/LocalizationTests.swift`
Found: 2026-10-02, in the review of `plans/done/units-are-written-the-english-way.md`

## Summary

`metadata.tracks` was `"%d tracks"` in English, `"%d Tracks"` in German and `"%d titres"` in
French, with no singular. A playlist with one track said "1 tracks". The key now has plural forms
in a `Localizable.stringsdict` for each language.

## Problem

`.strings` files have one form per key. Plural forms need a `.stringsdict` entry, or a String
Catalog's plural variations, and a lookup that picks the form by the number.

## Solution

- **`Localizable.stringsdict`** in `en`, `de` and `fr`, with `metadata.tracks` as
  `%#@tracks@`, `one` and `other`: "track"/"tracks", "Track"/"Tracks", "titre"/"titres". The
  key left the three `.strings` files.
- **The helper is unchanged.** `localizedNumberString` resolves the key with
  `String(localized:)`, which hands back the plural format, and `String(format:)` picks the form.
  Measured in the test host before choosing:

  | Lookup | 1 | 1007 |
  | --- | --- | --- |
  | `String(format:)`, no locale (the helper) | 1 track | 1007 tracks |
  | `String(format:locale:)` | 1 track | 1.007 Tracks (German) |
  | `String.localizedStringWithFormat` | 1 track | 1.007 Tracks |

  A locale groups the digits, which the helper exists to avoid. Without one, the plural rule is
  the app's language's: the French app says "0 titre", as French counts zero as one.
- **`LocalizationTests` reads `.stringsdict` keys too**, as part of a language's strings, so
  the key is still found in English and in each language.

`show_all.tracks` stays in `.strings`: the link shows only for more than five tracks.

## Verification

### Live, in French (2026-10-02)

- "Spotifly test: phase 4 create": "Par llralphj · 1 titre · 4 min".
- "Meine Playlist Nr. 37", empty: "Par llralphj · 0 titre".

### Unit tests

596 pass. `a track count takes the language's plural` pins the key's locale: "1 track", "2
tracks", "1 Track", "1007 Tracks", "1 titre", "2 titres". It leaves out French zero, since the
test host's own language picks the rule, and it is German.
