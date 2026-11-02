# Spotify refuses the audio key: "Audio key error: 1"

Status: **Open**, fix proposed, 2026-11-02, #223. Not reproduced on Ralph's account in these runs
Components: `Spotifly/SwiftLibrespot/Audio/AudioKeyProvider.swift`,
`Spotifly/SwiftLibrespot/Core/Errors.swift`, the `Localizable.strings`
Found: 2026-10-31, issue #223 (ThierDev, Premium, macOS 27.2, Spotifly 1.4.0): every key for
"MOON MUSiC" refused with code 1, while the official desktop app plays it on the same account

## Summary

The accesspoint refuses the AES key for a file, and the track cannot be decrypted. Relinking is not
the cause. On Ralph's account (DE, Premium) the same track id and the very same file ids get their
keys. The web player plays the exact id it was given, with `linked_from_uri: null`. So the refusal
comes from the account (or how Spotify treats it), not from the track or the request.

That matches librespot#1649, where librespot and go-librespot see the same refusals. There are two
kinds:

- **Persistent:** every key refused, whatever the pacing, mostly on newer accounts. Spotify's own
  clients do not use this key path, and no other path is open to a client like this one without
  getting around DRM.
- **Passing storms:** older accounts after bursts of requests. Pacing and backing off made them stop.

Spotifly can do two things:

- Ride out the passing storms with session-wide pacing and back-off.
- Fail fast and say plainly what happened when the refusal persists, instead of "Audio key error: 1".

## Problem

### The report

ThierDev's Debug captures: the login is Premium, the metadata names four files of the track's own
(`own=4, alternative=0`), and the key request for file `01f0dc78a71513e0…` under gid
`41FNZsY7w7KaTQ2bjxdR6w` is refused with code 1 in 182 ms. The same happens on the 96 kbit/s file
`06193cac53dc2509…`, in retries after 3, 5 and 10 s, and with the accesspoint logged into with the
OAuth token instead of the stored login. Two other tracks failed the same way in the release app.

### What the Debug build was given to measure

Commit `d3b5e2e` logs, in Debug builds only:

- What the extended-metadata answer says about the track: gid, ISRC, restrictions, sale periods,
  availability, each file with its format, and the same for each alternative.
- The header the answer was asked under.
- Every key request with its file and gid, and every refusal with its raw payload.

`SPOTIFLY_DEBUG_KEY_MATRIX` asks for every file's key under every gid the metadata names, and the
first file under an all-zero gid, 1.5 s apart. A comma-separated list of track uris runs the matrix
on those tracks first, as controls.

### Run 1: the reported track, with a relinked pair as control (2026-11-02 17:14 UTC)

`SPOTIFLY_DEBUG_AUTOPLAY=spotify:track:41FNZsY7w7KaTQ2bjxdR6w`, with the matrix on "The Letter",
whose original `459GknUJgpky3io0y482bi` is relinked in DE to `7FcObTmCbQYyC8qzlTL2SE`
(`CLAUDE.md`, "Track identity is the market id"). Login: country DE, Premium. Metadata asked
under country DE, catalogue premium, answered 200.

"MOON MUSiC" `41FNZsY7w7KaTQ2bjxdR6w` (gid `8450911c…`, ISRC GBAYE2400882):

- No restriction, no alternative, and four files of its own: `46e29d7f…` (format 2, Ogg 320),
  `01f0dc78…` (1, Ogg 160), `06193cac…` (0, Ogg 96) and `657781d7…` (8, AAC 24). These are the
  reporter's file ids.
- Every one of the four keys was given under the track's gid, and the 320 file's under the zero gid
  too.
- The track played: the key in 50 ms, the file downloaded, decrypted and decoded.

"The Letter", the relinked control:

| Asked as | Metadata | Keys |
|---|---|---|
| `7FcObTmCbQYyC8qzlTL2SE` (DE id) | 4 files of its own | all 4 given |
| `459GknUJgpky3io0y482bi` (original) | restriction `countries_allowed: ""`, no files, 1 alternative = `7FcOb…` with the same 4 files | all 4 given under the original's gid, under the alternative's, and under zero |

So the key server does not check the gid against the file: a key comes under the original's gid,
the substitute's or none. A relinked track with its alternative's files is not refused for being
asked under the original gid.

### Run 2: the Full Moon Edition (17:20 UTC)

Before run 1 the account's cluster was paused on "Man in The Moon", which is on
"Moon Music (Full Moon Edition)". That album lists MOON MUSiC under its own id,
`4mEWgqYOEiygF1mzEn901R` (same ISRC, other files). Autoplaying the album with the matrix: all four
keys given, the track played, and the next track's key, fetched ahead, was given too.

### The web player (Chrome, same account, 17:16–17:19 UTC)

The `track-playback/v1/devices/…/state` answers were captured in the page, since they carry the
state machine with each track's `metadata` and `manifest`.

- `open.spotify.com/track/41FNZsY7w7KaTQ2bjxdR6w` plays `uri: spotify:track:41FNZsY7w7KaTQ2bjxdR6w`
  with `linked_from_uri: null`, album "Moon Music" (`5SGtrmYbIo0Dsg4kJ4qjM6`). Its manifest names
  MP4 files only (`file_ids_mp4`: `9a3916c7…` format 11, `1f5af1d4…` format 10), decrypted through
  `widevine-license/v1/audio/license`. No accesspoint key is asked for.
- `…/track/4mEWgqYOEiygF1mzEn901R` plays as itself too, `linked_from_uri: null`, from its own MP4
  files.

The web player does not relink either id in DE, and it uses another key path altogether. So it
playing a track says nothing about whether the accesspoint gives that track's keys. The same holds
for the desktop app, which does not use AES keys from the accesspoint either.

### Upstream (librespot#1649, librespot#1844)

- librespot#1649 (since 2025-11, 163 comments): "error audio key 0 1" for whole accounts, with
  librespot and go-librespot alike, while the official clients play. Swapping accounts between
  working and failing setups moves the failure with the account.
- The thread's summary (2026-10-07, endorsed by a maintainer) names two problems:
  - New accounts cannot use AES keys at all.
  - Old accounts get storms of refusals that a 3/5/10 s back-off stops; skipping tracks quickly
    sets them off.
- 2026-10-30: an account (IT, Premium) refused every key by librespot with #1844 and by
  go-librespot alike, "it never recovers". Same as #223.
- Spotify's answer for third-party playback is Spotify Soloist (2026-08-13), an SDK under its own
  licence, whose builds expire every 90 days.
- librespot#1844 (open): one key request at a time, at least 200 ms apart; after a refusal the whole
  session waits 3 s, then 5 s, then 10 s; a refused key is asked again after each wait, up to three
  times.

### What this rules out

- **Relinking:** neither id is relinked in DE, and the reporter's metadata has no alternative.
  Relinked or not, the key server ignores the gid.
- **The request:** the same payload layout gets keys on Ralph's account, for the reporter's own
  file ids.
- **The file or format:** every file of the track is given here and refused there.
- **The login:** the reporter's OAuth login refuses the same way, and Ralph's stored login gets
  keys.

### What is left open

- The reporter's market. Their file ids match DE's, so they are probably asking for the same
  recording.
- Ralph reproduced the refusal the same day, but neither run here did. Whether that was a passing
  storm or something else is not recorded.

## Solution

Proposed. No playback for a persistently refused account: the alternatives are getting around DRM
(PlayPlay, Widevine) or Soloist, which is a different player under different terms and its own plan
if ever.

### 1. Pacing and back-off, session-wide (`AudioKeyProvider`)

After librespot#1844, smaller:

- **Pacing:** a request starts at least 200 ms after the one before, so a burst of skips cannot
  fire its requests together.
- **Back-off:** a refusal holds back every request until 3 s after it, then 5 s after a second in a
  row, then 10 s. A request already waiting wakes and checks again, so it is held back too. A key
  that arrives resets the count.
- **Retries:** a refused key is asked again after each wait, up to three times, so a passing storm
  costs the track a few seconds instead of failing it.
- **Fail fast:** once a refusal has outlasted all three retries, later requests are asked once,
  until a key arrives. A persistently refused account then learns in seconds instead of waiting
  18 s per track.
- A timeout or a lost connection starts no back-off: it says nothing about whether Spotify would
  give the key. A cancelled request stops waiting.

### 2. Say what it is (`LibrespotError.audioKeyError`)

"Audio key error: 1" becomes a localized sentence that names the refusal and keeps the code:
"Spotify refused the key to play this track (error 1)", in en, de and fr.

### Left as is

- The Debug diagnostics, which are what a reporter can run: `SPOTIFLY_DEBUG_KEY_MATRIX` with a
  control track tells a refused account from a refused track in one run.
- `StoredLogin.authType`, which the reporter flagged: the OAuth login refuses the same way, so it is
  not this.

## Verification

Planned:

- **Unit tests for the provider:** pacing, the back-off steps and the reset, the retries, failing
  fast, a waiting request honouring a refusal that came later, and timeouts starting no back-off.
  Run against a fake accesspoint, on a test clock or on short durations.
- **Debug run on Ralph's account:** autoplay with `SPOTIFLY_DEBUG_NEXT_AFTER` to skip quickly. Keys
  are still given and requests come at least 200 ms apart.
- **The reporter's account:** run the Debug build with
  `SPOTIFLY_DEBUG_KEY_MATRIX=spotify:track:7FcObTmCbQYyC8qzlTL2SE`. If the control is refused too,
  the account is refused, not the track, and the new message shows after one retry cycle.
