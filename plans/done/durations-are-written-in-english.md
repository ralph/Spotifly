# Durations were written in English in every language

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Store/Entities.swift` (`formatDuration`),
`SpotiflyTests/DurationFormattingTests.swift`
Found: 2026-10-02, live-checking `plans/done/localization-keys-hidden-from-the-compiler.md`

## Summary

An album's or playlist's header says how long it is. The units were literals in
`formatDuration`, so the French app said "2 hr 44 min". The system's duration formatter now
writes it in the app's language.

## Problem

`formatDuration(milliseconds:)` built `"\(hours.formatted()) hr \(minutes.formatted()) min"`.
The numbers followed the locale, the units never did, and no strings file had them.

## Solution

`Duration.UnitsFormatStyle`, hours and minutes, abbreviated, minutes rounded down as before. The
locale is a parameter defaulting to `.autoupdatingCurrent`, so the tests can pin one.

| | Before | After |
| --- | --- | --- |
| English | 2 hr 44 min | 2 hr, 44 min |
| German | 2 hr 44 min | 2 Std., 44 Min. |
| French | 2 hr 44 min | 2 h et 44 min |
| One hour, English | 1 hr 0 min | 1 hr |

English gains a comma, and a zero unit is left out, as the formatter writes them. Hand-kept unit
strings in the three `Localizable.strings` would have kept the English form exactly, at the cost
of two keys per language and the formatter's knowledge of each language's spacing: French keeps
a number with its unit with no-break spaces, U+202F before "h" and U+00A0 before "min".

## Verification

### Live (2026-10-02)

Today's Top Hits, 50 tracks:
- **French** (`-AppleLanguages '(fr)'`): "Par Spotify · 50 titres · 2 h et 44 min".
- **German:** "Von Spotify · 50 Tracks · 2 Std., 44 Min.".

### Unit tests

595 pass. `DurationFormattingTests` is new: the three languages, under an hour, rounding down
(2:44:40 is "2 hr, 44 min", 59 s is "0 min"), and a zero unit left out ("1 hr", but "0 min").
