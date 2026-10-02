# Some localization keys are invisible to the compiler, and the strings are three hand-kept files

Status: **Open**, not planned
Components: `Spotifly/LocalizationFormatting.swift`, `Spotifly/*.lproj/Localizable.strings`,
`SpotiflyTests/LocalizationTests.swift`, `Spotifly.xcodeproj/project.pbxproj`
Found: 2026-10-02, reviewing the fix for missing localization strings

## Summary

`LocalizationTests` now checks every key the compiler extracts against English, and the three
languages against each other. Two gaps remain: keys the compiler never sees, and no check in
the other direction, for strings no code uses.

## Problem

- **Keys the compiler never sees.** `localizedNumberString` and `localizedTextString` take
  `key: String` and pass it to `NSLocalizedString`. So the compiler does not extract
  `metadata.tracks`, `metadata.by_owner` or `show_all.tracks`.
  - A test of keys named against the strings files cannot check them.
  - A cleanup driven by extraction would remove them as unused, and bring the raw keys back.
  - The fix of 2026-10-02 kept them only because its manual pass also searched the source.
- **No check for unused strings.** Two entries survived that manual pass, because their names
  are prefixes of used ones (`playlist.edit`, `playback.play_track`). A test would need the
  hidden keys above to be visible first.
- **Three hand-kept files.** The project already sets `LOCALIZATION_PREFERS_STRING_CATALOGS`,
  `STRING_CATALOG_GENERATE_SYMBOLS` and `SWIFT_EMIT_LOC_STRINGS`, but uses `.lproj/*.strings`.
  A String Catalog with manually managed keys, reached through generated symbols, would make a
  missing key a compile error. Its per-language completion would show a missing translation.

## Solution

Not planned. In order:
1. Make the helpers' parameter `LocalizedStringResource`, which the compiler extracts, and call
   `String(localized:)` inside.
2. Add the reverse test: every English key is named by the code.
3. Possibly migrate to a String Catalog with generated symbols. That rewrites the three files
   into one and touches every call site, so it is a plan of its own.

## Verification

None yet.
