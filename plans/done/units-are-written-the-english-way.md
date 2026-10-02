# Durations and percentages were written the English way in every language

Status: **Done** 2026-10-02, verified live
Components: `Spotifly/Store/Entities.swift` (`formatDuration`),
`Spotifly/Views/Components/ConnectionStatusView.swift` (`UptimeDisplay`),
`Spotifly/Views/SpeakersView.swift`, `SpotiflyTests/DurationFormattingTests.swift`
Found: 2026-10-02, live-checking `plans/done/localization-keys-hidden-from-the-compiler.md`; the
uptime and the percentage in this plan's review

## Summary

Three readouts put a number and its unit together by hand, so every language got English:
- **An album's or playlist's length** in its header: the French app said "2 hr 44 min".
- **The connection's uptime** in Speakers: "1h 2m 5s".
- **A Connect device's volume** in Speakers: "50%", where French and German write "50 %".

Each now comes from the system's formatters, in the app's language.

## Problem

- `formatDuration(milliseconds:)` built `"\(hours.formatted()) hr \(minutes.formatted()) min"`.
- `UptimeDisplay.formattedUptime` built `"\(hours)h \(minutes)m \(seconds)s"`, dropping leading
  zero units.
- `SpeakersView` showed `Text(verbatim: "\(volume)%")`.

The numbers followed the locale, the units never did, and no strings file had them.

## Solution

- **Lengths:** `Duration.UnitsFormatStyle`, hours and minutes, abbreviated, minutes rounded down
  as before. The locale is a parameter defaulting to `.autoupdatingCurrent`, so the tests can
  pin one.
- **Uptime:** the same style, narrow, with hours, minutes and seconds allowed from the largest
  unit present down, and zero units shown, so the readout keeps the shape it had: "1h 0m 5s",
  not "1h 5s".
- **Volume:** `volume.formatted(.percent)`.

| | Before | After |
| --- | --- | --- |
| Length, English | 2 hr 44 min | 2 hr, 44 min |
| Length, German | 2 hr 44 min | 2 Std., 44 Min. |
| Length, French | 2 hr 44 min | 2 h et 44 min |
| One hour, English | 1 hr 0 min | 1 hr |
| Uptime, English | 1h 2m 5s | 1h 2m 5s |
| Uptime, German and French | 1h 2m 5s | 1h 2min 5s |
| Volume, English | 50% | 50% |
| Volume, German and French | 50% | 50 % |

The length in English gains a comma and drops a zero unit, as the formatter writes them.
Hand-kept unit strings in the three `Localizable.strings` would have kept the English form
exactly, at the cost of two keys per language and the formatter's knowledge of each language's
spacing: French keeps a number with its unit with no-break spaces, U+202F before "h" and U+00A0
before "min".

## Verification

### Live (2026-10-02)

- **Lengths**, Today's Top Hits, 50 tracks:
  - French (`-AppleLanguages '(fr)'`): "Par Spotify · 50 titres · 2 h et 44 min".
  - German: "Von Spotify · 50 Tracks · 2 Std., 44 Min.".
- **Speakers, in French**, through a throwaway hook (not committed) that opened the section at
  launch, since accessibility cannot select a sidebar row:
  - the devices read "computer · 50 %" and "avr · 37 %";
  - the uptime read "1min 17s" after 77 s.

The uptime with hours was checked in a script only, as "1h 2min 5s" in German and French and
"1h 2m 5s" in English: reaching it live takes an hour.

### Unit tests

595 pass. `DurationFormattingTests` is new:
- the three languages, compared with Foundation's spaces read as plain ones, since which spaces
  it uses is its data, not the app's;
- under an hour;
- rounding down: 2:44:40 is "2 hr, 44 min", and 59 s is "0 min";
- a zero unit left out: "1 hr", but "0 min".

### Seen in passing

- `plans/open/track-counts-have-no-plural.md`: a one-track playlist says "1 tracks".
- `plans/open/release-dates-shown-as-iso.md`: an album's header shows "1969-09-26" in every
  language.
- The device types in Speakers, "computer" and "avr", are Spotify's own words, shown as they
  come. Left as is.
