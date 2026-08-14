# A playlist can skip straight through every track after the first

Status: **observed, not investigated.** Written down from a log captured while verifying
an unrelated fix; nobody has looked into the cause yet.
Components: unknown — candidates are `rust/src/lib.rs` (what is handed to librespot) and
the track identity rules in `CLAUDE.md`
Found: 2026-08-14, in `../seek-after.log`

## Symptom

Started a playlist. The first track played. Every following track failed to load and
librespot skipped through them in a fraction of a second each, so playback effectively
stopped while the app still looked like it was playing.

```
07:22:11.203 ERROR librespot_playback::player] Track should be available, but no alternatives found.
07:22:11.203 WARN  librespot_playback::player] spotify:track:<4kVIImqwUPakCujdyQ3YP2> is not available
07:22:11.203 ERROR librespot_playback::player] Skipping to next track, unable to load track <SpotifyUri("…")>: ()
07:22:11.323 ERROR librespot_playback::player] … <4771ccpHnvLwaEacV0dh9E> is not available
07:22:11.363 ERROR librespot_playback::player] … <2X7Bo34Z1c375Jo6JQaVnL> is not available
```

Eight `is not available` and six `no alternatives found` in that run. A later run on a
different playlist (`../seek-after2.log`) played through normally, with two of the same
warnings and no interruption — so this is not every playlist, and an unavailable track does
not always cascade.

## What the message means

Both lines are librespot's, from the availability check it runs before loading. The first
says the track is not playable in the account's country; the second says librespot then
looked for a substitute recording and found none. That is the same relinking machinery
`CLAUDE.md` describes under *Track identity is the market id* — Spotify substitutes a
playable recording when the requested one is not available in the market.

## Why that is a suspicious coincidence, and not yet more than that

Spotifly recently moved every read onto the client APIs with `market=from_token`, on the
rule that the app keys everything on the id the API returned and never rewrites it. A
plausible story is that the ids reaching librespot are ones the *account's* market resolved,
while librespot resolves availability through its own session and disagrees — but nothing
here has been measured, and there are at least two other stories that fit the same log:

- the tracks are genuinely unavailable in DE and simply have no substitute, in which case
  the app's job is to *say so* rather than to fix anything;
- the country or market that librespot uses for the check is not the one the ids were
  resolved against.

The log alone cannot separate these. It does not record the ids the queue held, only the
ones that failed.

## Where to start

1. Take the three failing ids above and ask spclient for each with `market=from_token`, and
   again without, and compare what comes back — playable, substituted, or neither. That
   distinguishes "genuinely unavailable" from "we sent the wrong id" in one step.
2. Check what `Country:` librespot logged for the session (`librespot_core::session`, `DE`
   in this run) against the market the ids were resolved under.
3. Only then decide whether this is an identity bug or a missing piece of UI.

## The part that is a bug either way

Even if every one of those tracks is genuinely unplayable, **skipping silently through a
whole playlist in half a second is the wrong behaviour.** Nothing in the UI said anything;
the queue simply drained. Whatever the cause turns out to be, an unavailable track should
be visible as such — greyed in the queue, or a message — rather than presenting as playback
that quietly stops.
