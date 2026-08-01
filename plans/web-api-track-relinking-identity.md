# Web API relinking caches tracks under the playable alternative's id

Status: **planned**
Components: `Spotifly/SpotifyAPI/APITypes.swift`,
`Spotifly/SpotifyAPI/SpotifyAPI+Tracks.swift`
Found: 2026-08-01, while documenting the `market` parameter after the bridge-side fix

## Symptom

None observed yet — this is a hazard with a proven mechanism and an unproven occurrence.
It needs a playlist or search result containing a track that is relinked for this account's
market.

When it happens, the track's entity is cached under the *playable alternative's* id, with
two consequences.

**Reads go stale.** The queue reports the context's logical id,
`AppStore.tracks[logicalId]` misses, and the Now Playing bar shows its placeholder while
the metadata is re-fetched on every queue update. The recovery loader then stores a
*second* entity under the logical id — two entities for one context item, exactly the state
`plans/relinked-track-now-playing-identity.md` set out to prevent.

**Writes break outright**, which is the more serious half. Spotify's
[track relinking documentation](https://developer.spotify.com/documentation/web-api/concepts/track-relinking)
is explicit:

> If you plan to do further operations on tracks (for example, removing the track from a
> playlist or saving it to "Your Music"), it is important that you operate on the original
> track id found in the `linked_from` object.

Using the relinked id "will likely return an error or other unexpected result". The app has
exactly those call sites — `saveTrack`, `removeSavedTrack`, `checkSavedTracks`, and
removing a track from a playlist — and every one of them takes its id from a store entity.
So a relinked track reached from a playlist row or a search result would today be
favorited, un-favorited, status-checked and removed using the wrong id.

That moves this out of "identity hygiene" and into documented API misuse.

## Mechanism

Spotify applies track relinking **only when `market` is sent**:

| | without `market` | with `market=from_token` |
| --- | --- | --- |
| Relinking | inactive — the requested id comes back | active — a playable substitute may come back |
| `linked_from` | absent | present *only when a substitution happened*, holding the requested track |
| `is_playable` | absent | present, replacing `available_markets` |
| `restrictions` | absent | `{"reason": "market"}` when unplayable with no substitute |

Two details matter for the design. `linked_from` carries the full original reference —
`id`, `uri`, `href`, `type`, `external_urls` — so the logical identity is fully recoverable
from the response itself. And it is absent when no substitution took place, so its presence
is the signal, not a comparison against what was requested. That is what lets the fix live
at a seam that no longer knows which id was asked for.

Where the app stands today:

| Request | `market` | Consequence |
| --- | --- | --- |
| `/v1/tracks?ids=` | no | ids as requested |
| `/albums/{id}/tracks` | no | ids as requested |
| `/playlists/{id}/items` | **yes** | relinked tracks cache under the alternative id |
| `/search` | **yes** | same, for track results |

Album playback works *because* albums do not send `market`. That is also why this stayed
invisible through the entire bridge-side investigation, which used an album.

## Why "just send `market` everywhere" is not the fix

It is the obvious idea, and it makes things worse rather than uniform.

The identity that has to win is not the Web API's — it is Spirc's. librespot resolves a
context server-side and reports the **context's** ids, which are the logical ones; the
relinked id appears only when the audio item is loaded. Our own log shows both: the queue
carried `3CCy…` while playback loaded `7zzo…`.

Sending `market` everywhere would make the Web API consistently return alternatives, and
therefore consistently disagree with the source that drives playback and the queue. Albums,
which work today, would start failing the same way playlists can.

The alternative id is not a stable identity either. It is the result of a market-specific
lookup: the same logical track maps to different substitutes in different markets, and
`from_token` follows the account's market. Keying the store by it would mean the cache key
for a track changes when the user's market does.

## Why not drop `market` instead

Also wrong, in the other direction. `market` is what makes availability true for this user:
without it there is no `is_playable` and no `restrictions`, so the app cannot tell a
playable track from one it will fail to start. Dropping it trades a latent identity bug for
a real availability blindness.

`market` is not the problem. Leaving `linked_from` unread is.

## Design

### 1. Decode `linked_from` and prefer it as the identity

Add `linkedFrom` to `TrackCodable` — it carries the same shape as a track reference, and
only `id` and `uri` are needed.

Normalise inside `TrackCodable.toAPITrack()`: when `linkedFrom` is present, the entity's
`id` and `uri` come from it, while every other field continues to describe the object
Spotify returned.

That split is the identity rule this codebase already runs on, applied one layer up: the
logical track owns identity, the playable item supplies playback facts. The bridge does the
same thing for the stream — `CURRENT_TRACK_URI` from `Loading`/`Playing`, duration from
`TrackChanged`.

### 2. Normalise at that one seam, not per call site

`toAPITrack()` is the single funnel every track response passes through — tracks, album
tracks, playlist items, search results, saved tracks. Fixing it there covers endpoints that
send `market` today, endpoints that gain it later, and endpoints nobody has written yet.
Per-call-site handling would have to be remembered each time, which is the failure mode
that produced this hazard in the first place.

Nothing wants the alternative id from the Web API. Playback gets it from librespot, which
is the only place it is meaningful.

### 3. Retire the mismatch warning it makes redundant

`fetchTrackBatch` currently warns when a returned id differs from the requested one. That
guard exists precisely because the condition was unhandled. Once `toAPITrack()` normalises,
the condition is handled and the warning would fire on correct behaviour — remove it in the
same change rather than leave a diagnostic that cries wolf.

### 4. Out of scope

`is_playable` and `restrictions` become available for free once `market` responses are
being read properly. Surfacing unplayable tracks in the UI is a separate feature with its
own design questions (grey them out? hide them? what about a whole unplayable album?) and
should not ride along here.

## Verification

### Confirm the mechanism first

Before implementing, confirm the response shape against the one track known to relink for
this account — logical `3CCyVdprlcXui4ZwMw1hNS`, playable `7zzoxJbgjme3366mOp5UnH`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.spotify.com/v1/tracks/3CCyVdprlcXui4ZwMw1hNS?market=from_token" \
  | jq '{id, uri, is_playable, linked_from}'
```

Expected: `id`/`uri` name the alternative, `linked_from.id` is `3CCy…`. The same request
without `market` should return `3CCy…` and no `linked_from`.

If that is not what comes back, this plan's premise is wrong and nothing here should be
built — the documented behaviour and the observed behaviour would have to be reconciled
first.

### Automated

A decoding test on `TrackCodable`, in the style of `APITypesTests`: a payload carrying
`linked_from` yields an entity whose `id` and `uri` are the linked-from ones while `name`
and `durationMs` stay those of the returned object. A payload without `linked_from` is
unchanged.

Then the usual gates:

```text
xcodebuild -scheme Spotifly -configuration Debug build
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' \
  -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES
```

Two `NavigationCoordinator` assertions fail on this branch and are a known baseline.

### Runtime

Needs a playlist containing a track that relinks for this market — the same album track is
the easiest way to obtain one.

1. Open that playlist. Its rows show the track normally.
2. Play the relinked track from the playlist context. The Now Playing bar resolves title,
   artist and artwork immediately, with no `[GET] …/tracks/…` recovery fetch behind it.
3. Favorite it from the bar, then un-favorite it. Both must succeed — this is the call the
   documentation warns returns an error on a relinked id — and the heart must match the
   row in the playlist, since both have to act on the same id.
4. Remove it from a playlist you own, the other write the documentation names.
5. Search for the same track and play it from the search results; same expectations.

## Acceptance criteria

- A relinked track fetched with `market` is stored under the id that was requested.
- One entity per context item — no second entity appearing under an alternative id.
- Favorites, queue lookup, and Now Playing all resolve the same track from a playlist and
  from search.
- Every write reaching Spotify — save, remove from library, contains-check, remove from
  playlist — carries the original id, as the relinking documentation requires.
- Fields other than `id` and `uri` still describe what Spotify returned.
- The `fetchTrackBatch` mismatch warning is gone.
- Build and the Swift test suite pass, baseline failures excepted.
- Add a concise entry under `CHANGELOG.md` → `[Unreleased]` → `Fixed` when implementing.
- Update `AGENTS.md` → "Track relinking and the `market` parameter": the table's last two
  rows stop being a hazard, and the rule becomes "normalisation is automatic, do not
  bypass `toAPITrack()`".
