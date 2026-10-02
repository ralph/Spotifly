# Durations are written in English in every language

Status: **Open**, being fixed
Components: `Spotifly/Store/Entities.swift` (`formatDuration`)
Found: 2026-10-02, live-checking `plans/done/localization-keys-hidden-from-the-compiler.md`

## Summary

An album's or playlist's header says how long it is, as "2 hr 44 min" or "47 min". The words are
literals in `formatDuration`, so the French app says "2 hr 44 min", where French writes "2 h
44 min", and German "2 Std., 44 Min.".

## Problem

`formatDuration(milliseconds:)` builds `"\(hours.formatted()) hr \(minutes.formatted()) min"`.
The numbers follow the locale, the units never do, and no strings file has them.

## Solution

None yet.

## Verification

None yet.
