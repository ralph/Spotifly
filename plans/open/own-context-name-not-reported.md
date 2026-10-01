# This Mac's cluster state names no context

Status: **Open**, not planned. Split from `plans/done/context-uris-open-one-way.md`; read from the
code, nothing observed.
Components: `Spotifly/SwiftLibrespot/Connect/SpircController.swift`,
`Spotifly/SwiftLibrespot/Public/LibrespotClient.swift` (`SpircPlayerState`)
Found: 2026-09-30, in the altitude review of `plans/done/queue-header-names-no-liked-songs.md`

## Summary

`SpircController` builds this Mac's reported `PlayerState` from `SpircPlayerState` and never
fills `contextMetadata`, though the field is there and serialized (field 21). librespot copies
the resolved context's metadata into its player state.

## Problem

Whether it matters is not measured. The web player named Liked Songs while the Mac played it,
so it may look contexts up itself; a phone was not tried. The name is at hand since the header
fix (`LibrespotClient.contextName`).

## Solution

Not planned. First look at how a phone names a context this Mac plays. If it misses it, carry
the resolver's metadata into `SpircPlayerState`, as librespot does.

## Verification

Not defined yet.
