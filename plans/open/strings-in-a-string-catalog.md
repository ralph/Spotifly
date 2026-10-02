# The strings are three hand-kept files rather than a String Catalog

Status: **Open**, not planned
Components: `Spotifly/*.lproj/Localizable.strings`, every call site of a localized string,
`SpotiflyTests/LocalizationTests.swift`, `Spotifly.xcodeproj/project.pbxproj`
Found: 2026-10-02, step 3 of `plans/done/localization-keys-hidden-from-the-compiler.md`

## Summary

The project already sets `LOCALIZATION_PREFERS_STRING_CATALOGS`,
`STRING_CATALOG_GENERATE_SYMBOLS` and `SWIFT_EMIT_LOC_STRINGS`, but keeps its strings in three
`.lproj/Localizable.strings` files, one per language, kept in step by hand.

## Problem

`LocalizationTests` now catches the drift these files allow, at test time:
- a key the code names with no English string;
- a language missing a key English has, or having one English lacks;
- an English string no code names.

A String Catalog with manually managed keys, reached through generated symbols, would make a
missing key a compile error, and Xcode's per-language completion would show a missing
translation without running anything.

## Solution

Not planned. Converting the three files into one `Localizable.xcstrings` is one Xcode action;
the cost is the call sites. With generated symbols, `Text("metadata.tracks")` becomes a symbol
such as `Text(.metadataTracks(count))`, so every localized string in the app is touched once.
The formatting helpers in `LocalizationFormatting.swift` would go, since a catalog entry takes
its arguments. `LocalizationTests` would then check little the compiler does not.

## Verification

None yet.
