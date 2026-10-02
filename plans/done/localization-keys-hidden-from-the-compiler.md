# Some localization keys were invisible to the compiler, and nothing found unused strings

Status: **Done** 2026-10-02, steps 1 and 2, verified live. Step 3, the String Catalog, is
`plans/open/strings-in-a-string-catalog.md`
Components: `Spotifly/LocalizationFormatting.swift`, `SpotiflyTests/LocalizationTests.swift`
Found: 2026-10-02, reviewing the fix for missing localization strings

## Summary

`LocalizationTests` checked every key the compiler extracts against English, and the three
languages against each other. Two gaps remained: keys the compiler never saw, and no check in the
other direction, for strings no code uses. The formatting helpers now take a
`LocalizedStringResource`, so the compiler sees every key, and a new test checks that every
English string is named by the code.

## Problem

- **Keys the compiler never saw.** `localizedNumberString` and `localizedTextString` took
  `key: String` and passed it to `NSLocalizedString`. So the compiler did not extract
  `metadata.tracks`, `metadata.by_owner` or `show_all.tracks`.
  - A test of keys named against the strings files could not check them.
  - A cleanup driven by extraction would remove them as unused, and bring the raw keys back.
- **No check for unused strings.** The plan named two entries left over, `playlist.edit` and
  `playback.play_track`; both were gone by the time this was done.

## Solution

1. **The helpers take a `LocalizedStringResource`** and resolve it with `String(localized:)`,
   then format with `String(format:)` as before. The call sites are unchanged: a string literal
   becomes a resource, and the compiler extracts a literal passed as one
   (`SWIFT_EMIT_LOC_STRINGS`).
2. **`every English string is named by the code`**, the reverse of the existing test, built on
   the same `.stringsdata` reading. After step 1 the two sets are equal: 205 keys each.

### Not interpolation

The rest of the app puts a value into its key, as `Text("artist.show_all \(count)")` with the
key `"artist.show_all %lld"`, which the compiler also extracts. The review suggested the same
here, deleting the helpers. It was built and measured: SwiftUI formats an interpolated `Int` for
the locale, so the 1007-track test playlist's header said "1.007 Tracks" in German, where `main`
and the helpers say "1007 Tracks". The helpers' `String(format:)` exists to keep those ASCII
digits, so they stay, and their comment now says why.

### Step 3

Step 3, a String Catalog with generated symbols, would rewrite the three files into one and touch
every call site. It is `plans/open/strings-in-a-string-catalog.md`.

## Verification

### Unit tests (2026-10-02)

- 591 pass, the new one among them.
- **Negative check:** with `LocalizationFormatting.swift` put back to `main`'s, the new test
  fails, naming exactly `metadata.by_owner`, `metadata.tracks` and `show_all.tracks`.

### Live (2026-10-02)

`String(localized:)` resolves a resource in its locale, where `NSLocalizedString` used the
bundle's preferred localization, so both were checked:
- **German** (the system's language): Abbey Road's header says "17 Tracks · 47 min".
- **French** (`-AppleLanguages '(fr)'`): Today's Top Hits says "Par Spotify · 50 titres".
- **German, a four-digit count:** "Spotifly test: 1007 tracks" says "Von llralphj · 1007 Tracks".

### Seen in passing

The same French header says "2 hr 44 min": `formatDuration` writes "hr" and "min" in English
for every language. That is `plans/open/durations-are-written-in-english.md`.
