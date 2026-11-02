# Spotify refuses the audio key: "Audio key error: 1"

Status: **Open**, 2026-11-02, #223. The refusal now has a plain message. Spotifly can do nothing
more for an account Spotify refuses. Pacing and back-off wait for a refusal that passes, captured
in a log. Not reproduced on Ralph's account.
Components: `Spotifly/SwiftLibrespot/Core/Errors.swift`, the `Localizable.strings`; the Debug
diagnostics in `SPClient.swift`, `Accesspoint.swift`, `AudioKeyProvider.swift`, `AudioPipeline.swift`
Found: 2026-10-31, issue #223 (ThierDev, Premium, macOS 27.2, Spotifly 1.4.0): every key for
"MOON MUSiC" refused with code 1, while the official desktop app plays it on the same account

## Summary

The accesspoint refuses the AES key for a file, and the track cannot be decrypted. Relinking is not
the cause. On Ralph's account (DE, Premium) the same track id and the very same file ids get their
keys, in three Debug runs, one of them Ralph's own attempt to reproduce it. The web player plays the
exact id it was given, with `linked_from_uri: null`.

So the refusal goes with the account, or with how Spotify treats it, not with the track or the
request. That matches librespot#1649, where librespot and go-librespot are refused alike. The
refusals come in two kinds:

- **Persistent:** every key refused, mostly on newer accounts. Spotify's own clients do not use this
  key path, and no other path is open to a client like this one without getting around DRM.
- **Passing:** storms on older accounts after bursts of requests, which back-off stopped.

Done: the refusal says so in words instead of "Audio key error: 1".

Not done: pacing and back-off. They would answer only the passing kind, which nobody has captured
here. Codex's review found they need cancellation in the pipeline first.

## Problem

### The report

ThierDev's Debug captures: the login is Premium, and the metadata names four files of the track's
own (`own=4, alternative=0`). The key request for file `01f0dc78a71513e0…` under gid
`41FNZsY7w7KaTQ2bjxdR6w` is refused with code 1 in 182 ms. So are:

- the 96 kbit/s file `06193cac53dc2509…`;
- retries after 3, 5 and 10 s;
- requests after logging into the accesspoint with the OAuth token instead of the stored login.

Two other tracks failed the same way in the release app.

### What the Debug build was given to measure

Commit `d3b5e2e` logs, in Debug builds only:

- What the extended-metadata answer says about the track: gid, ISRC, restrictions, sale periods,
  availability, each file with its format, and the same for each alternative.
- The header the answer was asked under.
- Every key request with its file and gid, and every refusal with its raw payload.

`SPOTIFLY_DEBUG_KEY_MATRIX` asks for every file's key under every gid the metadata names, and the
first file under an all-zero gid, 1.5 s apart and past the key cache. A comma-separated list of
track uris runs the matrix on those tracks first, as controls.

### Run 1: the reported track, with a relinked pair as control (2026-11-02 17:14 UTC)

`SPOTIFLY_DEBUG_AUTOPLAY=spotify:track:41FNZsY7w7KaTQ2bjxdR6w`, with the matrix on "The Letter",
whose original `459GknUJgpky3io0y482bi` is relinked in DE to `7FcObTmCbQYyC8qzlTL2SE`
(`CLAUDE.md`, "Track identity is the market id"). Login: country DE, Premium. Metadata asked
under country DE, catalogue premium, answered 200.

"MOON MUSiC" `41FNZsY7w7KaTQ2bjxdR6w` (gid `8450911c…`, ISRC GBAYE2400882):

- No restriction, no alternative, and four files of its own: `46e29d7f…` (format 2, Ogg 320),
  `01f0dc78…` (1, Ogg 160), `06193cac…` (0, Ogg 96) and `657781d7…` (8, AAC 24). These are the
  reporter's file ids.
- A key came back for each of the four under the track's gid, and for the 320 file under the zero
  gid too.
- The track played: the key in 50 ms, the file downloaded, decrypted and decoded.

"The Letter", the relinked control:

| Asked as | Metadata | Keys |
|---|---|---|
| `7FcObTmCbQYyC8qzlTL2SE` (DE id) | 4 files of its own | all 4 given |
| `459GknUJgpky3io0y482bi` (original) | restriction `countries_allowed: ""`, no files, 1 alternative = `7FcOb…` with the same 4 files | a key for all 4 under the original's gid, the alternative's and zero |

So the key server is not strict about the gid. A relinked track's alternative files are not refused
for being asked for under the original gid. The matrix compared the keys' lengths only. It did not
check that each answer is the same key, or one that decrypts. It also asked under the right gid
first, so the server may have had the file's key in hand by then. A gid mismatch is ruled out as
the cause of a refusal. That the gid is ignored altogether is not proven.

### Run 2: the Full Moon Edition (17:20 UTC)

Before run 1 the account's cluster was paused on "Man in The Moon", which is on
"Moon Music (Full Moon Edition)". That album lists MOON MUSiC under its own id,
`4mEWgqYOEiygF1mzEn901R` (same ISRC, other files). Autoplaying the album with the matrix:

- all four keys given;
- the track played;
- the next track's key, fetched ahead, was given too.

### Run 3: Ralph's own attempt (17:31 UTC)

Ralph had seen the track fail to play in a build earlier that day. He ran this Debug build and
played the track as he had then: searched, played `41FNZsY7…`, skipped within it and on through the
queue to `4mEWgqYO…`, "A me mi piace", "O" and MOON MUSiC again.

- Every key was given, in 15–30 ms.
- No error anywhere in the log.
- He confirmed the song plays.

What failed for him earlier was not recorded.

### The web player (Chrome, same account, 17:16–17:19 UTC)

The `track-playback/v1/devices/…/state` answers were captured in the page, since they carry the
state machine with each track's `metadata` and `manifest`.

- `open.spotify.com/track/41FNZsY7w7KaTQ2bjxdR6w` plays `uri: spotify:track:41FNZsY7w7KaTQ2bjxdR6w`
  with `linked_from_uri: null`, album "Moon Music" (`5SGtrmYbIo0Dsg4kJ4qjM6`).
  - Its manifest names MP4 files only (`file_ids_mp4`: `9a3916c7…` format 11, `1f5af1d4…`
    format 10).
  - They are decrypted through `widevine-license/v1/audio/license`. No accesspoint key is asked for.
- `…/track/4mEWgqYOEiygF1mzEn901R` plays as itself too, `linked_from_uri: null`, from its own MP4
  files.

The web player does not relink either id in DE, and it uses another key path altogether. So the web
player playing a track says nothing about whether the accesspoint gives that track's keys. The
desktop app does not use AES keys from the accesspoint either.

### Upstream (librespot#1649, librespot#1844)

- **librespot#1649** (since 2025-11, 163 comments): "error audio key 0 1" for whole accounts, in
  librespot and go-librespot alike, while the official clients play. Swapping accounts between
  working and failing setups moves the failure with the account.
- **The thread's summary** (2026-10-07, endorsed by a maintainer) names two problems:
  - New accounts cannot use AES keys at all.
  - Old accounts get storms of refusals that a 3/5/10 s back-off stops. Skipping tracks quickly
    sets them off.
- **2026-10-30:** an account (IT, Premium) is refused every key, by librespot with #1844 and by
  go-librespot alike: "it never recovers". Same as #223.
- **Spotify Soloist** (2026-08-13) is Spotify's answer for third-party playback: an SDK under its
  own licence, whose builds expire every 90 days.
- **librespot#1844** (open):
  - One key request at a time, at least 200 ms apart.
  - After a refusal the whole session waits 3 s, then 5 s, then 10 s.
  - A refused key is asked again after each wait, up to three times.
  - A comment there reports storms that passed only after 28–40 s.

### What this rules out

- **Relinking:** neither id is relinked in DE, and the reporter's metadata has no alternative. A
  key comes back under the original's gid, the substitute's and zero alike.
- **The request:** the same payload layout gets keys on Ralph's account, for the reporter's own
  file ids.
- **The files:** both files the reporter tried, the 160 and the 96, are given here.
- **The login kind:** the reporter's OAuth login is refused too, and Ralph's stored login gets keys.

### What is left open

- **The reporter's market.** Their file ids match DE's, so they are probably asking for the same
  recording.
- **Account against network or AP.** Telling these apart needs a control track on the reporter's
  account: if a track that plays here is refused there too, it is the account (or its network), not
  the track.

### Codex's review of the proposal (2026-11-02)

Verdict: the message and the pacing idea are sound, but the experiments establish no fix for #223.

- **Cancellation (the blocking gap).** `AudioPipeline.playTrack` bumps `loadGeneration` and throws
  away a stale result only after its fetch. It does not cancel the key request. So a superseded
  load's retries would go on after a skip or a stop, and add to the storm they wait out.
  - `preparedTrack` takes over a fetch-ahead task and drops its handle before awaiting it, so that
    task cannot be cancelled either.
  - `Accesspoint.requestAudioKey`'s continuation ignores cancellation and waits out its 10 s
    timeout.
- **Counting:** only an explicit refusal (`.aesKeyError`) counts. A timeout or a lost connection
  neither starts the back-off nor resets it.
- **The cache:** check it again once a request has waited its turn, so two loads of one file send
  one request.
- **Failing fast is a budget, not a proof:** the later single tries still wait out the back-off, and
  storms have lasted 28–40 s upstream.
- **The message is right:** an explicit `.aesKeyError` supports "Spotify refused the key" without
  claiming why. `playbackFailed` publishes `localizedDescription`, so localizing the case reaches
  both the bar and the play's own error.

Agreed, except for one point. Codex would drop retries from the fetch-ahead. That fetch starts
minutes before it is needed, and it is already cancelled on a skip or a stop, so paced retries cost
it nothing once cancellation works.

## Solution

### 1. Say what it is (done)

`LibrespotError.audioKeyError` reads "Spotify refused the key to play this track (error 1)" in
English, and the same in German and French (`error.audio_key_refused`). It no longer reads
"Audio key error: 1". Playback stops as before, and nothing marks the track unavailable, since a
refusal is no fact about the track.

### 2. Pacing and back-off (not done, and when to do it)

After librespot#1844, in `AudioKeyProvider`:

- 200 ms between requests.
- A session-wide back-off after a refusal (3, 5, 10 s), which requests already waiting honour too.
  A key from the server resets it.
- Up to three retries of a refused key, then a single try per request until a key arrives.

Not built now. Nobody has captured a refusal that passes, here or in #223, whose refusal holds
through retries 3, 5 and 10 s apart. It also needs, before it is safe:

- superseded loads, and a fetch-ahead a load takes over, cancelling their key requests;
- the accesspoint's key continuation honouring cancellation.

Do it when a Debug log shows refusals that stop on their own, such as a storm after fast skipping.

### Left as is

- **The Debug diagnostics**, which are what a reporter can run.
- **`StoredLogin.authType`**, which the reporter flagged: the OAuth login is refused the same way,
  so it is not this.
- **Getting around DRM** (PlayPlay, Widevine) is out. **Spotify Soloist** is a different player
  under different terms; it would get its own plan if ever.

## Verification

- `LocalizationTests`: the message's key is named by the code and translated in en, de and fr.
- Run 3 above: on an account that gets keys, playback is unchanged.
- **For the reporter**, a Debug build with
  `SPOTIFLY_DEBUG_KEY_MATRIX=spotify:track:7FcObTmCbQYyC8qzlTL2SE` (a track whose keys are given on
  Ralph's account), then playing MOON MUSiC:
  - If the control is refused too, it is the account, and the new message shows.
  - If the control's keys are given, it is the track, and this plan is wrong about why.
