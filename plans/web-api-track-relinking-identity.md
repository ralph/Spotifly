# Web API relinking caches tracks under the playable alternative's id

Status: **completed 2026-08-01, then reversed 2026-08-13. Historical.** The rule this plan
implemented — normalise every track back to its *original* id through a
`RelinkableTrackCodable` protocol — is no longer the rule, and no code should be written from
it. `CLAUDE.md` carries the current one under *Track identity is the market id*: the app keys
everything on the id the API returned and never rewrites it.

The reversal was forced rather than chosen. Normalising back requires `linked_from`, which
only the Web API returns; search moved to pathfinder, which returns the market recording and
carries no `linked_from` at all, so there is nothing left to trade the substitute back for.
Every file this plan names is also gone — `SpotifyAPI+Tracks.swift`, `SpotifyAPI+Player.swift`
and `APITypesTests.swift` were deleted with the Web API.

What still holds, and is the reason this is kept: **one identity per track, or the store
corrupts.** That was this plan's real finding. Which id carries the identity is what changed.
Components: `Spotifly/SpotifyAPI/APITypes.swift`,
`Spotifly/SpotifyAPI/SpotifyAPI+Tracks.swift`,
`Spotifly/SpotifyAPI/SpotifyAPI+Player.swift`,
`Spotifly/Store/Services/QueueService.swift`,
`SpotiflyTests/APITypesTests.swift`
Found: 2026-08-01, while documenting the `market` parameter after the bridge-side fix

## Implemented solution

- `TrackCodable` decodes `linked_from` as a small original-track reference and exposes
  `logicalId` / `logicalUri`. `toAPITrack()` uses those values for identity while retaining
  every other field from Spotify's market-playable response.
- Album, saved-track, and playlist field projections explicitly include
  `linked_from(id,uri)`.
- Single and batch track lookup, album tracks, saved tracks, and playback state now request
  `market=from_token`. Search and playlist items already did.
- `/me/top/tracks`, `/me/player/recently-played`, and `/me/player/queue` do not accept a
  market parameter according to Spotify's endpoint reference, so no unsupported parameter
  was added.
- The original plan missed that `/me/player` and `/me/player/queue` consume
  `TrackCodable.id` / `.uri` directly instead of passing through `toAPITrack()`. The Web API
  playback bootstrap now uses the logical accessors for queue entries, metadata recovery,
  and Now Playing URI as well.
- The obsolete batch-ID mismatch warning was removed after normalisation made a differing
  returned ID expected behavior.
- Decoder tests cover relinked and unchanged payloads. The focused `APITypesTests` suite
  and the full Debug build pass.

### Two corrections after the fact

The plan's central assumption — that `toAPITrack()` is the one funnel every track passes
through — was wrong, and both places it was wrong had to be fixed afterwards:

- **`/albums/{id}/tracks` decodes through its own type.**
  `AlbumTracksCodable.AlbumTrackItemCodable` has its own fields and its own `toAPITrack()`,
  neither of which knew about `linked_from`. Adding `market` and the projection to that
  request therefore turned relinking on while the recovery field was decoded by nobody, and
  album tracks — the path this branch had just verified end to end — began caching under
  the substitute's id. The rule now lives in a `RelinkableTrackCodable` protocol that both
  types conform to.
- **`/search` built its entities by hand.** It sends `market` and uses no projection, so
  `linked_from` had been arriving all along; the plan counted it as fixed by normalisation
  alone. But the conversion was written out field by field and read the raw `id`, so it was
  never normalised. It goes through `toAPITrack()` now.

Both were invisible to the test suite, which covered `TrackCodable` only.

Conversely, the implementation caught something this plan had missed: `/me/player` and
`/me/player/queue` consume `TrackCodable` directly rather than through `toAPITrack()`, and
now read the logical accessors.

The lesson is recorded in `AGENTS.md`: check which type a response decodes into rather than
assuming `TrackCodable`, and build entities through `toAPITrack()` rather than by hand.

## Symptom

Reproduced against the live API on 2026-08-01: a track added to a playlist as
`3CCyVdprlcXui4ZwMw1hNS` comes back as `7zzoxJbgjme3366mOp5UnH` from the exact request
shape the app uses. This is a confirmed defect on the playlist path, not a hazard.

It has gone unnoticed because it needs a track that relinks for this account's market, and
because the two surfaces where it hurts most — album playback and the Now Playing bar —
are fed by requests that send no `market`.

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

## Decision: `market` everywhere, `linked_from` as the identity

Both halves are needed, and the order matters. What follows is why neither works alone.

### `market` alone makes it worse

It is the obvious idea on its own, and it makes things worse rather than uniform.

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

### Dropping `market` is wrong in the other direction

`market` is what makes availability true for this user: without it there is no
`is_playable` and no `restrictions`, so the app cannot tell a playable track from one it
will fail to start. Dropping it trades a latent identity bug for real availability
blindness — and leaves the split rule "which endpoints may send it?" that produced this
hazard.

`market` is not the problem. Leaving `linked_from` unread is.

### Together they are the target state

With normalisation at the conversion seam, `market` becomes safe everywhere, and uniform is
better than a rule someone has to remember per endpoint. Every track the app shows is then
the one that will actually play, `is_playable` and `restrictions` become available, and
identity stays logical throughout.

`/v1/tracks` gains the least — the recovery loader asks by logical id and would normalise
straight back to it, a round trip whose only yield is `is_playable`. It still sends
`market`, because "every track request sends `market`" is a rule that holds up, and "every
track request except this one" is the kind that quietly stops holding.

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

### 1a. Ask for `linked_from` wherever a `fields` projection is used

A `fields` projection returns exactly what it lists, so a field nobody asked for never
arrives — and a projection is the one way this fix could appear to work while doing
nothing, because `linkedFrom` would simply always decode as nil.

Verified that a projection *does* pass it through when asked (see Verification), so the
seam design holds. Three requests project track fields and none of them list it today.

### 1b. The full inventory

Every request that puts a `Track` in the store, and what each needs:

| Request | `fields` | `market` today | needs |
| --- | --- | --- | --- |
| `/playlists/{id}/items` | yes | **yes** | `linked_from` in `fields` — **this is the live defect** |
| `/search` | no | **yes** | nothing; `linked_from` already arrives, only the decoding is missing |
| `/albums/{id}/tracks` | yes | no | `linked_from` in `fields`, then `market` |
| `/me/tracks` (saved) | yes | no | `linked_from` in `fields`, then `market` |
| `/tracks/{id}` | no | no | `market` |
| `/tracks?ids=` | no | no | `market`; drop the mismatch warning |
| `/me/top/tracks` | no | no | `market`, if the endpoint accepts it |
| `/me/player/recently-played` | no | no | `market`, if the endpoint accepts it |
| `/me/player` | no | no | `market`; consume logical id/uri directly |
| `/me/player/queue` | no | no | endpoint has no `market`; consume logical id/uri directly |

The endpoint reference confirms that top tracks, recently played, and queue do not take a
`market` parameter; playback state does. That is why the invariant worth stating is **not**
"everything sends `market`" but:

> Identity comes from `linked_from` when it is present. Every response passes through the
> same normalisation, whether or not its request could ask for a market.

`market` is then an availability improvement applied wherever the API allows it, and
correctness does not depend on achieving it everywhere.

Ordering constraint for the whole change: **the projections and the decoding land together,
and `market` is not added anywhere new until both are in place.** Adding `market` first
would introduce the bug this plan exists to prevent.

### 2. Normalise at that one seam, not per call site

`toAPITrack()` is the single funnel for every track entity stored by the catalog and
library services — tracks, album tracks, playlist items, search results, saved tracks, top
tracks, and recently played. `logicalId` / `logicalUri` put the identity decision one level
lower so the playback bootstrap is covered too: it intentionally consumes
`TrackCodable` directly to build queue entries rather than storing those response objects.

Nothing wants the alternative id from the Web API. Playback gets it from librespot, which
is the only place it is meaningful.

### 3. Retire the mismatch warning it makes redundant

`fetchTrackBatch` currently warns when a returned id differs from the requested one. That
guard exists precisely because the condition was unhandled. Once `toAPITrack()` normalises,
the condition is handled and the warning would fire on correct behaviour — remove it in the
same change rather than leave a diagnostic that cries wolf.

### 4. Add `market` to the remaining track requests — last

Once the projections carry `linked_from` and `toAPITrack()` normalises, add
`market=from_token` to the track requests that lack it and officially support it:
`/v1/tracks`, `/albums/{id}/tracks`, `/me/tracks`, and `/me/player`. Last, deliberately —
each catalog/library request is correct today *because* it omits `market`, so adding it
before normalisation works would break exactly what currently holds.

### 5. Out of scope

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

**Confirmed 2026-08-01** against this account, so the premise is fact rather than
documentation:

| request | `id` / `uri` | `is_playable` | `linked_from.id` |
| --- | --- | --- | --- |
| `?market=from_token` | `7zzoxJbgjme3366mOp5UnH` | `true` | `3CCyVdprlcXui4ZwMw1hNS` |
| no `market` | `3CCyVdprlcXui4ZwMw1hNS` | absent | absent |

`market` switches relinking on, and `linked_from` returns the requested identity in full
(`id`, `uri`, `href`, `type`, `external_urls`).

**Also confirmed:** the question the design hinges on — whether a `fields` projection
passes `linked_from` through. That track was put in a scratch playlist and requested the
way the app requests it, with `linked_from(id,uri)` added:

```json
{"track": {"uri": "spotify:track:7zzoxJbgjme3366mOp5UnH",
           "id": "7zzoxJbgjme3366mOp5UnH",
           "linked_from": {"id": "3CCyVdprlcXui4ZwMw1hNS",
                           "uri": "spotify:track:3CCyVdprlcXui4ZwMw1hNS"}}}
```

The projection carries it, so normalising at the conversion seam works everywhere. The same
request without `fields` returns the same thing plus `is_playable: true`.

That second check also settles the severity: a track added to a playlist as `3CCy…` comes
back as `7zzo…` from the request shape the app actually uses. The playlist row is a
**confirmed defect**, not a hazard — today the app caches that entity under `7zzo…`, and a
favorite or a playlist removal from it would carry the id Spotify's documentation says will
fail.

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
