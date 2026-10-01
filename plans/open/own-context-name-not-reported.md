# This Mac's cluster state names no context

Status: **Open**, built and sent, not yet seen anywhere it would show: whether a phone names a
context differently for it needs a phone. See Progress. Split from
`plans/done/context-uris-open-one-way.md`.
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

## Progress

- **Built** (2026-10-01), ahead of the phone the plan wanted first, as librespot does it
  (`set_active_context` copies the resolved context's `metadata` into `context_metadata`):
  `SPClient.ResolvedContext.metadata` keeps the resolver's whole `metadata` map, the client
  keeps it with the context (`contextMetadata`, empty for a bare list), and `SpircPlayerState`
  sends it as field 21. The context's name is read from it in one place,
  `[String: String].contextName`, for this Mac's queue and for another device's alike.
- **A handover** resolves the context again, so it reports the resolver's map too. librespot
  reports the transfer's own metadata only until its resolve lands, then the resolver's.
- **Seen sent:** a throwaway log, never committed, of the reported state: Liked Songs carried
  `context_description: "Lieblingssongs"`, `format_list_type: "liked-songs"`, `context_owner`
  and `playlist.revision`; "Not Bad for New Jersey" carried its name and `image_url`.
- **Not seen:** any difference on another device. The web player names contexts itself, as it
  did before. A phone is the check left.

