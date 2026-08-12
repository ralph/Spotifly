# Playback dies at login5 because the streaming session uses a third-party client id

Spotify changed a server-side rule on or around 2026-08-11. Spotifly's Rust layer can no
longer initialise Spirc, so nothing plays locally. Browsing is unaffected.

This plan records what broke, why no local change can be blamed for it, and the design
agreed for the fix.

## Symptom

Every playback attempt ends the same way:

```
Player init error: Spirc initialization failed: Spirc init failed:
Error { kind: FailedPrecondition, error: FaultyRequest(INVALID_CREDENTIALS) }
```

Everything before it succeeds. The AP accepts our token, hands back stored credentials,
and reports `Authenticated as 'qixixbr0ox…'` with `Country: "DE"`. All Web API traffic —
`/v1/me`, top artists, recently-played, album and playlist fetches — returns normally
throughout. Only local playback is dead.

Signing out and back in does not help, because it mints a fresh token with the same
client id.

## Mechanism

`Spirc::new` pre-acquires an access token before returning:

```rust
// librespot connect/src/spirc.rs:225
let _ = session.login5().auth_token().await?;
```

That calls `Login5Manager::auth_token`, which POSTs `Login_method::StoredCredential` to
`login5.spotify.com/v3/login`. Spotify answers `INVALID_CREDENTIALS`, mapped to
`FailedPrecondition` at `core/src/login5.rs:112`.

The stored credentials in that request come from the AP, which derived them from the
access token we passed in. That token is minted by the Swift side with **the user's own
dashboard client id** (`SpotifyConfig.getClientId()`), while `create_session` in
`rust/src/lib.rs` leaves `SessionConfig::client_id` at librespot's keymaster default:

```rust
let session_config = SessionConfig {
    device_id: device_id.to_string(),
    ..Default::default()          // client_id = 65b708073fc0480ea92a077233ca87bd
};
let credentials = Credentials::with_access_token(access_token);  // minted with 044db036…
```

librespot documents the constraint at `core/src/login5.rs:163` — "This request will only
work when the store credentials match the client-id" — but Spotify did not enforce the
binding until now.

Upstream librespot users never hit this: their OAuth flow mints the token with the same
keymaster id the session uses, so both sides match. Only clients that bring their own
client id are affected.

**This is not a regression in our code.** The librespot checkout has not moved since
2026-07-30 (`9c7d756`, clean on `dev`), the retired `spotifly-dev` fork never touched
auth, and no auth-related change landed in `spotifly-code` after 2026-07-31.

Confirmed externally by the go-librespot maintainer in
[devgianlu/go-librespot#364](https://github.com/devgianlu/go-librespot/issues/364),
2026-08-12:

> It seems like Spotify killed the authentication flow via Login5 when using stored
> credentials produced by the AP with an access token with a different client ID than the
> desktop one. […] This seems a structural and definitive change

## Evidence

Two probes were run against the live service on 2026-08-12. Both are reproducible; see
"To reproduce".

**Probe 1 — can we keep our own client id?** No. Making `SessionConfig::client_id` match
the token's client id fails earlier and harder, because client tokens are first-party
only:

| Step | keymaster client id (today's config) | dashboard client id |
|---|---|---|
| `clienttoken.spotify.com` | OK | **400 Bad Request** |
| AP connect | OK | OK |
| `login5` auth_token | **INVALID_CREDENTIALS** | **400** (no client token to send) |

login5 requires the `Client-Token` header (`core/src/login5.rs:62`), so a client id that
cannot obtain one cannot drive Connect at all. No librespot configuration fixes this.

**Probe 2 — does a keymaster-minted token work?** Yes:

```
client_id = 65b708073fc0480ea92a077233ca87bd (keymaster)
OAuth: OK (token len=435, 26 scopes granted)
client_token:      OK
AP connect:        OK
login5 auth_token: OK
```

Same account, same machine, twenty minutes after the failing run.

**Probe 3 — can keymaster serve the Web API too?** No. Same fresh keymaster token,
straight at the API, against a dashboard-token control on the same machine and IP
seconds later:

| Endpoint | keymaster | dashboard |
|---|---|---|
| `/v1/me` | **429** | 200 |
| `/v1/me/top/artists` | **429** | 200 |
| `/v1/me/player/devices` | **429** | 200 |
| `/v1/browse/new-releases` | **429** | 200 |

Not a warm-up effect — that is the first call on a new token. psst documents the same
finding at `psst-gui/src/ui/preferences.rs:668`: a separate Web API client id "avoiding
429 rate-limit errors from Spotify's official Client ID". spotify-player reaches the
same shape from the other side, using ncspot's extended-quota id for the Web API and
keymaster for streaming.

## What this forces

The two halves cannot share a client id in either direction:

- The **streaming session** must use keymaster. A dashboard id gets no client token.
- The **Web API** must use the dashboard id. Keymaster is rate-limited into uselessness.

So Spotifly grows a second, independent grant. This also preserves a property worth
keeping: today's outage took out playback while browsing stayed healthy, precisely
because the two halves are separate. Merging them would have taken down the whole app.

## Design

### Login — two explicit steps — **taken**

Step 1 is today's screen, unchanged: client id field, Connect, `de.rvdh.spotifly://`
callback, tokens to the keychain, `SpotifySession` refreshing as it does now.

Step 2 appears once step 1 succeeds: **Enable playback**, running the keymaster grant.
Naming each grant for what it does makes a failure obvious and locally retryable.

Step 2 is skippable. Skipping is not an error state — see "No streaming credentials".

### Credential storage — librespot's cache — **taken**

`Cache::new` currently receives `None` for every path, so nothing persists.

```rust
let cache = Cache::new(None::<std::path::PathBuf>, None, None, None)
```

Give it a real `credentials_path` under the app container. `session.connect(creds, true)`
already passes `store_credentials = true`, so persistence needs no other change.

The first init after step 2 passes the OAuth token. Every init after that connects from
stored credentials with **no token, no refresh, and no network round-trip beforehand** —
which matters most on the wake-from-sleep path that already has two plans of its own.

Logout wipes the directory alongside the keychain items.

Accepted tradeoff: credentials become a file in the sandboxed container rather than a
keychain item. The alternative — a second refresh-token lifecycle mirroring
`SpotifySession.validAccessToken()`, with its own coalescing, backoff and death-latch —
is more machinery in the subtlest file in the auth layer, to protect a secret that
librespot is designed to persist itself.

### The grant — Rust, via librespot-oauth — **taken**

`OAuthClientBuilder` already does PKCE, the loopback listener, browser opening, and the
code exchange; probe 2 used exactly this path. In Swift it would be roughly a hundred
lines of new PKCE and HTTP code, because `ASWebAuthenticationSession` cannot take a
loopback callback.

Cost: a blocking, browser-opening call behind the FFI, so it needs a cancel path and a
progress signal for the UI.

**There is no in-flight cancellation, deliberately.** An earlier draft required one, and
it does not survive contact with the API: `get_authcode_listener` blocks in
`listener.incoming().flatten().next()` with no timeout and no handle
(`oauth/src/lib.rs:182`), `get_access_token()` is synchronous, and even a listener handle
would not help once execution has moved into `read_line()` on an accepted stream. Every
mechanism that fixes that adds machinery.

It also buys nothing the UI asked for. **Cancel** in the alert declines the grant *before*
the flow starts; nothing in the design cancels a browser authorization already under way.
So the flow is self-terminating instead: a bounded timeout on the listener and on reads
from accepted streams, after which it reports failure and the user can press **Enable this
Mac** again. The UI shows progress, not a cancel button.

### FFI changes — **taken**

Two:

1. **New `spotifly_authorize_streaming()`** — opens the browser, listens on loopback,
   exchanges the code, connects, persists credentials. Reports success or failure.
   It must **not persist for a superseded run**: the token exchange and connect are
   network steps a logout can outlive, and writing afterwards would restore the previous
   account's credentials into a cache logout has already wiped. Carry the session
   generation through the call and check it immediately before saving — the same rule
   services follow in `AGENTS.md` ("A superseded run must not write").
2. **`spotifly_init_player` accepts a null token**, meaning "use cached credentials".
   The three Swift call sites — `PlaybackViewModel.swift:259`,
   `LoggedInLifecycleModifier.swift:137`, `SpeakersView.swift:108` — stop passing a Web
   API token, which was never the right credential for this call.
3. **The Rust reconnect loop stops asking Swift for a token.** `spawn_reconnection_loop`
   currently fires `request_token_from_swift()`, waits on the `PENDING_TOKEN` oneshot with
   a ten-second timeout, and hands the result to `init_player_async`
   (`rust/src/lib.rs:1146`). That is a dashboard token, so the first automatic reconnect
   after a cluster outage would reproduce the login5 mismatch even once login works.
   Rebuilding from cached credentials removes the request, the channel, the timeout, and
   the re-check that exists only because the round-trip can take ten seconds — the wake
   path gets shorter, not longer. Retire `request_token_from_swift` and its callback once
   nothing else needs it.

### Loopback port — **taken**

Pick a free port at runtime rather than hardcoding one. Spotify accepts arbitrary
loopback ports for keymaster: librespot takes any `--oauth-port`, psst uses 8888,
spotify-player 8989, probe 2 used 8898. Scanning avoids conflicts for free.

`com.apple.security.network.server` is already in the entitlements, so the listener needs
no new sandbox capability.

### Patch librespot-oauth rather than replace it — **taken**

Two defects sit in the same function and share a fix. Beyond the missing cancellation
above, **the callback is not validated**: `set_auth_url` generates `CsrfToken::new_random`
and discards it (`oauth/src/lib.rs:243`, `let (auth_url, _)`), and `get_code` looks only
for `code`, never `state`. The listener terminates on the *first* connection to reach the
port, whatever it is. PKCE still prevents a third party from stealing our code, but
nothing prevents an injected callback — worst case exchanging an attacker's code and
binding the session to their account, cheapest case killing the flow by connecting first.

Both are fixed by one upstream patch: retain the `CsrfToken`, validate `state` against it,
ignore non-matching callbacks instead of terminating, and bound the wait with timeouts —
on the listener *and* on reads from accepted streams, since a connection that never sends
a complete request line parks in `BufReader::read_line()` where a listener timeout cannot
reach it. Carry it locally until it lands — the workspace builds whatever
librespot is checked out, which is what that arrangement is for.

Taking this route deliberately: these findings would otherwise argue for hand-writing the
flow in Swift, which trades a bounded upstream patch for a hundred lines of PKCE and HTTP
that every other librespot client would still be missing.

### No streaming credentials — **taken**

The state is not "playback disabled". It is **"this Mac is not available as a playback
device"** — everything else still works, including playing to other devices over the Web
API (`SpotifyAPI+Player.swift`, plus device transfer).

That distinction is self-maintaining in the UI. Without Spirc the Mac never registers
with Spotify Connect, so it simply is not in `/v1/me/player/devices`: Spotifly is missing
from its own Speakers list, which is exactly true and needs no hiding logic. The
affordance lives where the user is already looking — an **Enable this Mac** row in
Speakers that runs step 2.

Pressing play raises an **Auth / Cancel** alert only when no device anywhere can serve
the request. If another device is active, play proceeds over the Web API and no alert
appears; there is no reason to nag about local streaming while a remote device is
playing.

That last part needs work the app does not have yet. `SpotifyAPI+Player.swift` covers
transport only — pause, resume, next, previous, seek, volume, shuffle — with no
start-with-URI call, and `play`/`playTracks` hard-gate on `isInitialized` before routing
to `SpotifyPlayer` (`PlaybackViewModel.swift:327`). So today, with no local device, a
remote device can be paused but an album cannot be started on it.

Add **`startPlayback(contextUri:uris:offset:deviceId:)`** to `SpotifyAPI+Player`,
mirroring `resumePlayback` on the same `/me/player/play` endpoint with a JSON body, and
route `play`/`playTracks` to it when local playback is unavailable. This is worth having
beyond this feature: it also lets the user start something on a remote device without
transferring to local first.

**A remote start has to refresh the store itself.** With no Spirc session there are no
playback or queue callbacks, so nothing tells the UI what happened and the now-playing bar
keeps showing whatever it showed before. `fetchInitialPlaybackState` runs only at startup
and after a local reconnect. Route a successful remote start through the same
playback-and-queue refresh, after a short delay so Spotify has settled — services updating
`AppStore` on success is the established pattern.

The now-playing bar always renders. It is the control surface for remote playback, and in
mini-player mode it *is* the window (`LoggedInView.swift:132`) — hiding it would empty
the frame and delete working functionality.

### Stale credentials, and migration — **taken**

Cached credentials will eventually stop working: revoked, aged out, or Spotify changing
the rules again as it just did. Init failing that way flips the local device to
unavailable and offers step 2 again. Browsing continues on the Web API token.

Migration falls out for free. Existing users upgrade into a valid Web API session with no
streaming credentials, land in exactly that state, and click **Enable this Mac** once. No
migration code, no forced re-login.

## Rejected

- **Match `SessionConfig::client_id` to the dashboard id.** Disproved by probe 1: client
  tokens are first-party only.
- **Keymaster everywhere, one grant.** Disproved by probe 3: every Web API endpoint 429s.
  It would also couple browsing to the first-party client id whose rules just changed,
  and require the loopback listener to replace the custom-scheme callback for both halves.
- **Skip or soften the login5 call.** Not optional — `spclient` (`core/src/spclient.rs:494`)
  and the dealer (`core/src/dealer/manager.rs:87`) both need that token, and the dealer is
  Connect.
- **Swift-side refresh of a keymaster token.** A second lifecycle in `SpotifySession` for
  a secret librespot already persists.
- **Hide the now-playing bar as the indicator.** Loses remote control, empties the
  mini-player window, and overloads a signal the bar already uses for "nothing playing".
- **Full logout on stale credentials.** Throws away a healthy Web API session and the
  entire browsing UI.

## Risks

- The loopback listener may draw a firewall prompt on first use despite the entitlement.
- Stored credentials are file-protected, not keychain-protected — accepted above.
- Two authorizations at first login is a real UX cost. It is what psst and spotify-player
  both settled on, and Spotify leaves no third option.
- Nothing prevents Spotify from tightening the keymaster path next. The split keeps that
  blast radius on playback alone, as it was today.

## Testing

The Swift state machine — unavailable, re-grant, playing — is unit-testable against the
existing `SpotiflyTests` suite, which is green on `main`. The grant itself is not; the probe
binaries stay as manual verification, since they are what established the fix works.

## To reproduce

Both probes live in the session scratchpad and build against the local librespot checkout
with `librespot-core` and `librespot-oauth` path dependencies:

- Probe 1 reads the current access token and dashboard client id from the keychain
  (`com.spotifly.oauth` / `spotify_access_token`, `com.spotifly.config` /
  `spotify_custom_client_id`), then runs `connect` + `login5().auth_token()` twice — once
  with the keymaster default, once with the dashboard id.
- Probe 2 runs `OAuthClientBuilder` against keymaster on `http://127.0.0.1:8898/login`
  with librespot's 26 scopes, then the same connect and login5 sequence.

Probe 3 is `curl` with each token against the endpoints in the table above.

## Related

- [devgianlu/go-librespot#364](https://github.com/devgianlu/go-librespot/issues/364) —
  maintainer confirmation, 2026-08-12
- [Volumio thread](https://community.volumio.com/t/new-2023-spotify-plugin/63381/757) —
  same break, users switching to Zeroconf auth
- [librespot#1732](https://github.com/librespot-org/librespot/issues/1732) — OAuth drops
  the refresh token when Spotify's response omits it; only relevant if a refresh path is
  ever added
- `psst-gui/src/ui/preferences.rs:668` and spotify-player's README — both reference
  clients use the same split
- Nothing is filed upstream at librespot-org/librespot yet; worth reporting.
