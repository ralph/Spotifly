# Streaming Auth Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore local playback by minting the librespot session credential with Spotify's
first-party client id, while the Web API keeps using the user's own dashboard client id.

**Architecture:** Two independent grants. Step 1 (unchanged) authorizes the Web API with the
dashboard client id over the custom URL scheme. Step 2 authorizes streaming with the keymaster
client id over a loopback redirect, and librespot persists the resulting AP credentials to a
cache directory — so every later player init connects from cache with no token at all. Without
streaming credentials the Mac simply never registers as a Connect device, and playback routes
to remote devices over the Web API.

**Tech Stack:** Rust (librespot-core, librespot-oauth, tokio) behind a C FFI; Swift 6 /
SwiftUI; Swift Testing (`import Testing`) for Swift tests; `#[cfg(test)]` modules for Rust.

The design and its evidence live in
[streaming-auth-needs-a-first-party-client-id.md](streaming-auth-needs-a-first-party-client-id.md).
Read it first — it records why each decision is what it is, and which alternatives were
disproved against the live service.

## Global Constraints

- **Never mint a librespot credential with the dashboard client id.** `clienttoken.spotify.com`
  returns 400 for it, and login5 cannot proceed without a client token.
- **Never send a keymaster token to `api.spotify.com`.** Every endpoint returns 429.
- Keymaster client id is `SessionConfig::default().client_id`
  (`65b708073fc0480ea92a077233ca87bd`). Never hardcode it in Spotifly.
- **A superseded run must not write** (`AGENTS.md`). Both new async paths capture the
  lifecycle generation at start and recheck before touching shared state.
- Rust edition 2021. `cargo clippy` has **9 pre-existing `not_unsafe_ptr_arg_deref` errors** on
  the FFI surface by design — compare counts against that baseline, never expect zero.
- Swift formatting: `swiftformat --swiftversion 6.3`. The tree is clean; format touched files.
- Swift tests: `xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES`
  (the `GENERATE_INFOPLIST_FILE=YES` is required for the test target to launch). Treat the exit
  code and `** TEST SUCCEEDED **` as authoritative — the log is racily written, so never count
  tests by unique name.
- Rust tests: `cargo test --manifest-path rust/Cargo.toml <name>` from `spotifly-code/`.
- One commit per problem.

## File Structure

**`librespot/` (separate repo — see the optional appendix, which nothing here depends on):**
- `oauth/src/lib.rs` — add `state` validation and bounded waits to the callback listener.

**`spotifly-code/rust/src/lib.rs`** — the FFI layer. Already large; these changes keep to its
existing shape rather than restructuring it:
- `create_session` — takes an optional token, gains a credentials cache.
- `spotifly_init_player` — accepts a null token, meaning "use cached credentials".
- `spotifly_authorize_streaming` — new; runs the grant, persists, honours the generation.
- `spawn_reconnection_loop` — stops asking Swift for a token.

**`spotifly-code/Spotifly/`:**
- `SpotifyAPI/SpotifyAPI+Player.swift` — add `startPlayback`.
- `ViewModels/PlaybackViewModel.swift` — route play to local or remote; refresh after remote.
- `SpotifyPlayer.swift` — bridge the new FFI call.
- `Views/ContentView.swift`, `Views/SpeakersView.swift` — step 2 and its re-run affordance.

**Tests:** `SpotiflyTests/StreamingAuthTests.swift` (new), plus Rust `mod tests` in
`rust/src/lib.rs` (already exists at the bottom of the file).

---

### Task 1: Persist credentials, and init from them

**Files:**
- Modify: `spotifly-code/rust/src/lib.rs` — `create_session`, `spotifly_init_player`
- Test: `spotifly-code/rust/src/lib.rs`, in the existing `mod tests`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `fn credentials_cache_dir() -> std::path::PathBuf`
  - `fn create_session(device_id: &str, access_token: Option<&str>) -> Result<(Session, Option<Credentials>), String>`
    — `None` credentials means "connect from cache", which `Session::connect` supports because
    the cache now has a credentials directory.
  - `spotifly_init_player(access_token: *const c_char)` accepts NULL for the same meaning.
    Tasks 2, 3 and 5 rely on both.

- [ ] **Step 1: Write the failing test**

Add to the `mod tests` block at the bottom of `rust/src/lib.rs`:

```rust
    #[test]
    fn credentials_cache_dir_is_absolute_and_app_scoped() {
        let dir = credentials_cache_dir();
        assert!(dir.is_absolute(), "cache dir must be absolute: {dir:?}");
        assert!(
            dir.ends_with("Spotifly/credentials"),
            "cache dir must be app-scoped: {dir:?}"
        );
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml credentials_cache_dir`
Expected: FAIL — `cannot find function 'credentials_cache_dir' in this scope`.

- [ ] **Step 3: Implement**

Add above `create_session`:

```rust
/// Where librespot persists the AP credentials produced by the streaming grant.
///
/// Under the sandbox `HOME` is already the app container, so this stays inside it.
fn credentials_cache_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    std::path::Path::new(&home)
        .join("Library")
        .join("Application Support")
        .join("Spotifly")
        .join("credentials")
}
```

Replace `create_session` with:

```rust
/// Creates a new (unconnected) Session with the given device ID.
///
/// `access_token` is `Some` only for the first connect after the streaming grant. Every
/// later init passes `None` and connects from the credentials librespot cached then — which
/// is the whole point of the cache: no token, no refresh, no round-trip before connecting.
fn create_session(
    device_id: &str,
    access_token: Option<&str>,
) -> Result<(Session, Option<librespot_core::authentication::Credentials>), String> {
    let session_config = SessionConfig {
        device_id: device_id.to_string(),
        ..Default::default()
    };
    let cache = Cache::new(Some(credentials_cache_dir()), None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;
    let credentials = access_token
        .map(librespot_core::authentication::Credentials::with_access_token);

    if credentials.is_none() && cache.credentials().is_none() {
        return Err("No streaming credentials: authorization required".to_string());
    }

    let session = Session::new(session_config, Some(cache));
    Ok((session, credentials))
}
```

`Cache::new` is generic over one path type, so pass `Some(credentials_cache_dir())` and let the
other three be `None` of the same type — if inference complains, annotate as
`Cache::new::<std::path::PathBuf>(Some(credentials_cache_dir()), None, None, None)`.

In `build_player_async`, the call site becomes:

```rust
    let (session, credentials) = create_session(&device_id, access_token)?;
```

with its signature changed to `access_token: Option<&str>`, threaded through `init_player_async`
the same way. Where `Spirc::new` is called, pass the cached credentials when we have none of our
own — `Session::connect` accepts credentials from the cache, so hand `Spirc::new` whatever
`credentials` holds, falling back to the session's cache:

```rust
    let credentials = match credentials {
        Some(c) => c,
        None => session
            .cache()
            .and_then(|c| c.credentials())
            .ok_or_else(|| "No cached streaming credentials".to_string())?,
    };
```

Finally, let the FFI accept NULL:

```rust
    // A null token means "use the cached streaming credentials", which is the normal case
    // after the one-time grant. Only the first connect after authorization passes a token.
    let token_arg = unsafe { c_string_arg(access_token) };
    let result =
        RUNTIME.block_on(async { init_player_async(token_arg.as_deref(), false, false).await });
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: PASS, including the new test and the 28 existing ones.

Run: `cargo clippy --manifest-path rust/Cargo.toml 2>&1 | grep -c "^error"`
Expected: `9` — the FFI baseline, unchanged.

- [ ] **Step 5: Commit**

```bash
cd /Users/ralph/code/spotifly/spotifly-code
git add rust/src/lib.rs
git commit -m "Connect from cached streaming credentials"
```

---

### Task 2: The streaming grant behind the FFI

**Files:**
- Modify: `spotifly-code/rust/Cargo.toml` — add `librespot-oauth`
- Modify: `spotifly-code/rust/src/lib.rs`
- Test: `spotifly-code/rust/src/lib.rs`, in `mod tests`

**Interfaces:**
- Consumes: `credentials_cache_dir()` and `create_session` from Task 1; `OAuthClientBuilder`
  from stock `librespot-oauth`.
- Produces: `spotifly_authorize_streaming() -> i32` (0 success, -1 failure, -2 superseded), and
  `fn run_is_superseded(started_generation: u64) -> bool`. Task 6 calls the FFI through Swift.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn a_run_is_superseded_when_the_generation_moves() {
        let started = SESSION_GENERATION.load(Ordering::SeqCst);
        assert!(!run_is_superseded(started));
        SESSION_GENERATION.fetch_add(1, Ordering::SeqCst);
        assert!(run_is_superseded(started));
    }

    #[test]
    fn picks_a_bindable_loopback_port() {
        let port = pick_free_loopback_port().expect("a free port");
        assert!(port >= 1024, "must not need root: {port}");
        // Proves it is actually bindable, which is what the OAuth listener will do next.
        let listener = std::net::TcpListener::bind(("127.0.0.1", port)).expect("bindable");
        drop(listener);
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test --manifest-path rust/Cargo.toml superseded`
Expected: FAIL — `cannot find function 'run_is_superseded'`.

- [ ] **Step 3: Implement**

Add the dependency to `rust/Cargo.toml`:

```toml
librespot-oauth = { path = "../../librespot/oauth" }
```

Add to `rust/src/lib.rs`:

```rust
/// Scopes requested for the streaming session. Mirrors librespot's own list; these are
/// granted to the first-party client id, and are unrelated to the Web API scopes Swift asks
/// for with the dashboard client id.
static STREAMING_SCOPES: &[&str] = &[
    "app-remote-control",
    "playlist-modify",
    "playlist-modify-private",
    "playlist-modify-public",
    "playlist-read",
    "playlist-read-collaborative",
    "playlist-read-private",
    "streaming",
    "ugc-image-upload",
    "user-follow-modify",
    "user-follow-read",
    "user-library-modify",
    "user-library-read",
    "user-modify",
    "user-modify-playback-state",
    "user-modify-private",
    "user-personalized",
    "user-read-birthdate",
    "user-read-currently-playing",
    "user-read-email",
    "user-read-play-history",
    "user-read-playback-position",
    "user-read-playback-state",
    "user-read-private",
    "user-read-recently-played",
    "user-top-read",
];

/// Whether the run that started at `started_generation` has been superseded — by a logout, a
/// teardown, or a replacement session. See AGENTS.md: a superseded run must not write.
fn run_is_superseded(started_generation: u64) -> bool {
    SESSION_GENERATION.load(Ordering::SeqCst) != started_generation
}

/// Ask the OS for a free loopback port by binding port 0 and reading back the assignment.
///
/// Spotify accepts any loopback port for the first-party client id, so nothing has to be
/// registered. There is an unavoidable gap between releasing this and the OAuth listener
/// binding it; losing that race fails the grant, and the user retries.
fn pick_free_loopback_port() -> Result<u16, String> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("Could not reserve a loopback port: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("Could not read the reserved port: {e}"))?
        .port();
    drop(listener);
    Ok(port)
}

/// Runs the one-time streaming authorization: opens the browser, waits for the loopback
/// callback, exchanges the code, connects, and lets librespot persist the AP credentials.
///
/// Returns 0 on success, -1 on failure, -2 if the run was superseded (logout landed while it
/// was in flight). There is no in-flight cancellation: the flow is bounded by the listener's
/// own deadline, and the alert's Cancel declines before this is ever called.
#[no_mangle]
pub extern "C" fn spotifly_authorize_streaming() -> i32 {
    let started_generation = SESSION_GENERATION.load(Ordering::SeqCst);

    let port = match pick_free_loopback_port() {
        Ok(p) => p,
        Err(e) => {
            debug!("Streaming authorization error: {e}");
            return -1;
        }
    };

    let config = SessionConfig::default();
    let client = match librespot_oauth::OAuthClientBuilder::new(
        &config.client_id,
        &format!("http://127.0.0.1:{port}/login"),
        STREAMING_SCOPES.to_vec(),
    )
    .open_in_browser()
    .build()
    {
        Ok(c) => c,
        Err(e) => {
            debug!("Streaming authorization error: {e}");
            return -1;
        }
    };

    let token = match client.get_access_token() {
        Ok(t) => t,
        Err(e) => {
            debug!("Streaming authorization failed: {e}");
            return -1;
        }
    };
    debug!("Streaming authorization: token obtained, connecting");

    // Connect once so librespot writes the AP credentials into the cache. Everything after
    // this init connects from that cache.
    let result = RUNTIME.block_on(async {
        let device_id = format!("spotifly_{}", std::process::id());
        let (session, credentials) = create_session(&device_id, Some(&token.access_token))?;
        let credentials = credentials.ok_or_else(|| "No credentials to connect".to_string())?;
        session
            .connect(credentials, true)
            .await
            .map_err(|e| format!("Connect failed: {e}"))?;
        session.shutdown();
        Ok::<(), String>(())
    });

    if let Err(e) = result {
        debug!("Streaming authorization connect error: {e}");
        return -1;
    }

    // Recheck *after* the write, not before it: librespot persists from inside
    // Session::connect, so a logout landing mid-connect would wipe the cache and this run
    // would recreate it behind logout's back.
    if run_is_superseded(started_generation) {
        debug!("Streaming authorization superseded; removing the credentials it wrote");
        let _ = std::fs::remove_dir_all(credentials_cache_dir());
        return -2;
    }

    debug!("Streaming authorization complete");
    0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: PASS.

Run: `cargo clippy --manifest-path rust/Cargo.toml 2>&1 | grep -c "^error"`
Expected: `9`.

- [ ] **Step 5: Commit**

```bash
git add rust/Cargo.toml rust/src/lib.rs
git commit -m "Add the streaming authorization FFI call"
```

---

### Task 3: Stop asking Swift for a token on reconnect

`spawn_reconnection_loop` fires `request_token_from_swift()`, waits on `PENDING_TOKEN` with a
ten-second timeout, then rechecks state *because* that round-trip is slow. With cached
credentials none of it is needed, and the first automatic reconnect would otherwise reproduce
the login5 mismatch with a dashboard token.

**Files:**
- Modify: `spotifly-code/rust/src/lib.rs:1146-1199` and the token plumbing at lines 93-96,
  722-745, 1057
- Modify: `spotifly-code/Spotifly/SpotifyPlayer.swift` — the token-request callback registration

**Interfaces:**
- Consumes: `init_player_async(None, ...)` from Task 1.
- Produces: nothing new. Removes `spotifly_register_token_request_callback` and
  `spotifly_provide_token` from the FFI surface.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn reconnect_does_not_depend_on_a_swift_token() {
        // The reconnect path must not reach for a token callback any more: with credentials
        // cached there is nothing for Swift to provide, and what it *would* provide is a Web
        // API token that login5 rejects.
        let source = include_str!("lib.rs");
        assert!(
            !source.contains("request_token_from_swift"),
            "the reconnect loop still requests a token from Swift"
        );
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml reconnect_does_not_depend`
Expected: FAIL — the assertion fires, because the function is still there.

- [ ] **Step 3: Implement**

In `spawn_reconnection_loop`, delete the oneshot channel, the `request_token_from_swift()` call,
the `tokio::time::timeout` block, and the "Re-check after the token round-trip" guard that only
existed to cover those ten seconds. What remains is:

```rust
            // One recovery strategy: tear everything down and rebuild Session, Player,
            // Mixer and Spirc as a single generation, then restore the captured intent.
            do_reconnect_cleanup();

            match init_player_async(None, intent.was_active, intent.should_resume()).await {
                Ok(_) => {
```

Then delete, in `rust/src/lib.rs`:
- `static TOKEN_REQUEST_CALLBACK` (line 93) and `static PENDING_TOKEN` (line 96)
- `spotifly_register_token_request_callback` (line 722) and the `spotifly_provide_token` entry
  point that fills `PENDING_TOKEN` (line 742)
- `fn request_token_from_swift` (line 1057)

And in `Spotifly/SpotifyPlayer.swift`, delete the matching registration and its callback
function. Search for `spotifly_register_token_request_callback` and `spotifly_provide_token` and
remove both call sites.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: PASS.

Run: `xcodebuild -scheme Spotifly -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` — proves no Swift call site still references the deleted
symbols.

- [ ] **Step 5: Commit**

```bash
git add rust/src/lib.rs Spotifly/SpotifyPlayer.swift
git commit -m "Rebuild the reconnect from cached credentials"
```

---

### Task 4: `SpotifyAPI.startPlayback`

`SpotifyAPI+Player.swift` has transport controls only — pause, resume, next, previous, seek,
volume, shuffle. Starting content on a remote device needs `/me/player/play` with a body.

**Files:**
- Modify: `spotifly-code/Spotifly/SpotifyAPI/SpotifyAPI+Player.swift`
- Create: `spotifly-code/SpotiflyTests/StreamingAuthTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `static func makeStartPlaybackRequest(contextUri: String?, uris: [String]?, offsetIndex: Int?, deviceId: String?, accessToken: String) throws -> URLRequest`
  - `static func startPlayback(contextUri: String?, uris: [String]?, offsetIndex: Int?, deviceId: String?, accessToken: String) async throws`
    Task 5 calls the latter.

- [ ] **Step 1: Write the failing test**

Create `SpotiflyTests/StreamingAuthTests.swift`:

```swift
//
//  StreamingAuthTests.swift
//  SpotiflyTests
//
//  Playback routing when this Mac is not a Connect device.
//

import Foundation
@testable import Spotifly
import Testing

struct StartPlaybackRequestTests {
    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func `a context start sends context_uri and an offset`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: "spotify:album:a1",
            uris: nil,
            offsetIndex: 3,
            deviceId: nil,
            accessToken: "tok",
        )

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/v1/me/player/play")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let json = try body(request)
        #expect(json["context_uri"] as? String == "spotify:album:a1")
        #expect((json["offset"] as? [String: Any])?["position"] as? Int == 3)
        #expect(json["uris"] == nil)
    }

    @Test func `a track start sends uris and no context`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: nil,
            uris: ["spotify:track:t1", "spotify:track:t2"],
            offsetIndex: nil,
            deviceId: nil,
            accessToken: "tok",
        )

        let json = try body(request)
        #expect(json["uris"] as? [String] == ["spotify:track:t1", "spotify:track:t2"])
        #expect(json["context_uri"] == nil)
        #expect(json["offset"] == nil)
    }

    @Test func `a device id goes in the query, never the body`() throws {
        let request = try SpotifyAPI.makeStartPlaybackRequest(
            contextUri: "spotify:album:a1",
            uris: nil,
            offsetIndex: nil,
            deviceId: "dev123",
            accessToken: "tok",
        )

        let query = try #require(request.url?.query)
        #expect(query.contains("device_id=dev123"))
        #expect(try body(request)["device_id"] == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: build failure — `type 'SpotifyAPI' has no member 'makeStartPlaybackRequest'`.

- [ ] **Step 3: Implement**

Add to `SpotifyAPI+Player.swift`, after `resumePlayback`:

```swift
    /// Builds the request that starts new content on a device via Web API.
    ///
    /// Split out from `startPlayback` so the body and query construction can be tested without
    /// a network round-trip. `deviceId` belongs in the query string, not the body.
    static func makeStartPlaybackRequest(
        contextUri: String?,
        uris: [String]?,
        offsetIndex: Int?,
        deviceId: String?,
        accessToken: String,
    ) throws -> URLRequest {
        var components = URLComponents(string: "\(baseURL)/me/player/play")
        if let deviceId {
            components?.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        }

        guard let url = components?.url else {
            throw SpotifyAPIError.invalidURI
        }

        var payload: [String: Any] = [:]
        if let contextUri {
            payload["context_uri"] = contextUri
        }
        if let uris, !uris.isEmpty {
            payload["uris"] = uris
        }
        if let offsetIndex {
            payload["offset"] = ["position": offsetIndex]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return request
    }

    /// Starts content on a device via Web API.
    ///
    /// Used when this Mac is not a Connect device — either because streaming was never
    /// authorized, or because its credentials went stale. `resumePlayback` only resumes what is
    /// already loaded; this is what starts an album or a set of tracks.
    static func startPlayback(
        contextUri: String?,
        uris: [String]? = nil,
        offsetIndex: Int? = nil,
        deviceId: String? = nil,
        accessToken: String,
    ) async throws {
        let request = try makeStartPlaybackRequest(
            contextUri: contextUri,
            uris: uris,
            offsetIndex: offsetIndex,
            deviceId: deviceId,
            accessToken: accessToken,
        )

        #if DEBUG
            debugLog("SpotifyAPI", "[PUT] \(request.url?.absoluteString ?? "")")
        #endif

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200, 204:
            return
        case 401:
            throw SpotifyAPIError.unauthorized
        case 404:
            throw SpotifyAPIError.noActiveDevice
        default:
            try throwAPIError(data: data, statusCode: httpResponse.statusCode)
        }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`, exit code 0.

- [ ] **Step 5: Commit**

```bash
swiftformat --swiftversion 6.3 Spotifly/SpotifyAPI/SpotifyAPI+Player.swift SpotiflyTests/StreamingAuthTests.swift
git add Spotifly/SpotifyAPI/SpotifyAPI+Player.swift SpotiflyTests/StreamingAuthTests.swift
git commit -m "Add Web API start-playback"
```

---

### Task 5: Route play to local or remote, and refresh after remote

**Files:**
- Modify: `spotifly-code/Spotifly/ViewModels/PlaybackViewModel.swift:321-380`
- Modify: `spotifly-code/SpotiflyTests/StreamingAuthTests.swift`

**Interfaces:**
- Consumes: `SpotifyAPI.startPlayback` (Task 4).
- Produces: `enum PlaybackTarget { case local, remote(deviceId: String), needsAuthorization }`
  and `static func playbackTarget(isInitialized: Bool, activeDeviceId: String?) -> PlaybackTarget`.
  Task 6 shows its alert on `.needsAuthorization`.

- [ ] **Step 1: Write the failing test**

Append to `SpotiflyTests/StreamingAuthTests.swift`:

```swift
@MainActor
struct PlaybackTargetTests {
    @Test func `a local player takes precedence`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: true, activeDeviceId: "dev1")
                == .local,
        )
    }

    @Test func `no local player routes to the active remote device`() {
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: false, activeDeviceId: "dev1")
                == .remote(deviceId: "dev1"),
        )
    }

    @Test func `nothing anywhere asks for authorization`() {
        // This is the only case that may nag: no local device, and nothing remote to serve it.
        #expect(
            PlaybackViewModel.playbackTarget(isInitialized: false, activeDeviceId: nil)
                == .needsAuthorization,
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: build failure — `type 'PlaybackViewModel' has no member 'playbackTarget'`.

- [ ] **Step 3: Implement**

Add to `PlaybackViewModel`:

```swift
    /// Where a play request should go.
    enum PlaybackTarget: Equatable {
        case local
        case remote(deviceId: String)
        case needsAuthorization
    }

    /// Decides where to play. Local wins when it exists; otherwise an active remote device
    /// serves the request over the Web API. Only when neither exists is there anything to ask
    /// the user about — nagging about local streaming while a phone is playing would be noise.
    static func playbackTarget(isInitialized: Bool, activeDeviceId: String?) -> PlaybackTarget {
        if isInitialized {
            return .local
        }
        if let activeDeviceId {
            return .remote(deviceId: activeDeviceId)
        }
        return .needsAuthorization
    }
```

Rewrite `play(uriOrUrl:trackIndex:accessToken:)` to route through it. The existing body keeps
its local branch verbatim; the new branches wrap it:

```swift
    func play(uriOrUrl: String, trackIndex: Int = -1, accessToken: String) async {
        if !isInitialized {
            await initializeIfNeeded(accessToken: accessToken)
        }

        switch Self.playbackTarget(
            isInitialized: isInitialized,
            activeDeviceId: store.activeDeviceId,
        ) {
        case .local:
            isLoading = true
            errorMessage = nil
            do {
                try await SpotifyPlayer.play(uriOrUrl: uriOrUrl, trackIndex: trackIndex)
                handlePlaybackStarted(trackId: uriOrUrl)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false

        case let .remote(deviceId):
            await startRemotely(
                contextUri: uriOrUrl,
                uris: nil,
                offsetIndex: trackIndex >= 0 ? trackIndex : nil,
                deviceId: deviceId,
                accessToken: accessToken,
            )

        case .needsAuthorization:
            needsStreamingAuthorization = true
        }
    }
```

Give `playTracks` the same shape, passing `uris: trackUris` and `contextUri: nil`.

Add the shared remote path and the flag the UI observes:

```swift
    /// Set when a play request arrived with nowhere to serve it. The view presents the
    /// Auth / Cancel alert on this and clears it either way.
    var needsStreamingAuthorization = false

    /// Starts content on a remote device and then resyncs, because nothing else will.
    ///
    /// With no Spirc session there are no playback or queue callbacks — a successful start
    /// would otherwise leave the now-playing bar showing whatever it showed before.
    private func startRemotely(
        contextUri: String?,
        uris: [String]?,
        offsetIndex: Int?,
        deviceId: String,
        accessToken: String,
    ) async {
        isLoading = true
        errorMessage = nil

        // Capture the lifecycle generation before any awaiting: a logout can land during the
        // request or the settle delay, and a superseded run must not write (AGENTS.md).
        let generationAtStart = store.liveStateRevision

        do {
            try await SpotifyAPI.startPlayback(
                contextUri: contextUri,
                uris: uris,
                offsetIndex: offsetIndex,
                deviceId: deviceId,
                accessToken: accessToken,
            )
            // Let Spotify settle before asking what it thinks is playing.
            try? await Task.sleep(for: .milliseconds(600))

            guard store.liveStateRevision == generationAtStart else {
                isLoading = false
                return
            }
            _ = await queueService.fetchInitialPlaybackState(accessToken: accessToken)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
```

`PlaybackViewModel` is a singleton (`PlaybackViewModel.shared`) and does not hold a
`QueueService`. Rather than giving it a global one, pass the service in as a parameter to
`play`/`playTracks` from the call sites — the views already have it via
`@Environment(QueueService.self)` — and thread it through to `startRemotely`.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`, exit code 0.

- [ ] **Step 5: Commit**

```bash
swiftformat --swiftversion 6.3 Spotifly/ViewModels/PlaybackViewModel.swift SpotiflyTests/StreamingAuthTests.swift
git add Spotifly/ViewModels/PlaybackViewModel.swift SpotiflyTests/StreamingAuthTests.swift
git commit -m "Route playback to a remote device when this Mac is not one"
```

---

### Task 6: Step 2 in the UI, and the way back to it

**Files:**
- Modify: `spotifly-code/Spotifly/SpotifyPlayer.swift` — bridge `spotifly_authorize_streaming`
- Modify: `spotifly-code/Spotifly/Views/ContentView.swift` — step 2 on the login screen
- Modify: `spotifly-code/Spotifly/Views/SpeakersView.swift` — "Enable this Mac" row
- Modify: `spotifly-code/Spotifly/Views/LoggedInView.swift` — the Auth / Cancel alert
- Modify: `spotifly-code/SpotiflyTests/StreamingAuthTests.swift`

**Interfaces:**
- Consumes: `spotifly_authorize_streaming()` (Task 2), `PlaybackTarget` and
  `needsStreamingAuthorization` (Task 5).
- Produces: `SpotifyPlayer.authorizeStreaming() async -> StreamingAuthResult`.

- [ ] **Step 1: Write the failing test**

Append to `SpotiflyTests/StreamingAuthTests.swift`:

```swift
struct StreamingAuthResultTests {
    @Test func `the FFI codes map to outcomes`() {
        #expect(StreamingAuthResult(code: 0) == .authorized)
        #expect(StreamingAuthResult(code: -1) == .failed)
        // -2 means a logout landed mid-flight and the credentials were removed again. The UI
        // must not report success, and must not report an error either — nothing went wrong.
        #expect(StreamingAuthResult(code: -2) == .superseded)
        #expect(StreamingAuthResult(code: 99) == .failed)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: build failure — `cannot find 'StreamingAuthResult' in scope`.

- [ ] **Step 3: Implement**

Add to `SpotifyPlayer.swift`:

```swift
/// Outcome of the one-time streaming authorization.
enum StreamingAuthResult: Equatable {
    case authorized
    case failed
    /// A logout landed while the grant was in flight; the credentials it wrote were removed.
    case superseded

    init(code: Int32) {
        switch code {
        case 0: self = .authorized
        case -2: self = .superseded
        default: self = .failed
        }
    }
}

extension SpotifyPlayer {
    /// Runs the streaming grant: opens the browser, waits for the loopback callback, and lets
    /// librespot persist the credentials. Blocks on a human, so it must never run on the main
    /// actor. There is no cancellation — the Rust side bounds its own wait.
    static func authorizeStreaming() async -> StreamingAuthResult {
        await Task.detached(priority: .userInitiated) {
            StreamingAuthResult(code: spotifly_authorize_streaming())
        }.value
    }
}
```

In `ContentView.swift`, add step 2 below the existing Connect button. Step 1 keeps its label;
give it a number so the pair reads as a sequence:

```swift
            // Step 2 — the streaming grant. Separate from step 1 because it uses Spotify's
            // first-party client id: the Web API rate-limits that id into uselessness, and a
            // dashboard id cannot get a client token at all. Skippable — without it the app
            // browses and drives other devices, it just is not a Connect device itself.
            if viewModel.authResult != nil, !viewModel.hasStreamingCredentials {
                VStack(alignment: .leading, spacing: 8) {
                    Text("auth.enable_playback_label")
                        .font(.headline)
                    Text("auth.enable_playback_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 280, alignment: .leading)
                }
                .frame(width: 280, alignment: .leading)

                Button {
                    Task { await viewModel.authorizeStreaming() }
                } label: {
                    HStack {
                        if viewModel.isAuthorizingStreaming {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        }
                        Text(
                            viewModel.isAuthorizingStreaming
                                ? "auth.enable_playback_waiting"
                                : "auth.enable_playback_button",
                        )
                    }
                    .frame(minWidth: 200)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isAuthorizingStreaming)
            }
```

Add the matching state and action to `AuthViewModel`:

```swift
    var isAuthorizingStreaming = false
    var hasStreamingCredentials = SpotifyPlayer.hasCachedStreamingCredentials()

    func authorizeStreaming() async {
        isAuthorizingStreaming = true
        defer { isAuthorizingStreaming = false }

        switch await SpotifyPlayer.authorizeStreaming() {
        case .authorized:
            hasStreamingCredentials = true
        case .superseded:
            // A logout won the race; leave the flag alone and say nothing.
            break
        case .failed:
            errorMessage = String(localized: "auth.enable_playback_failed")
        }
    }
```

`hasCachedStreamingCredentials()` is a small addition to the FFI in the same style as the rest —
`spotifly_has_streaming_credentials() -> i32`, returning 1 when `credentials_cache_dir()`
contains a credentials file. Add it to `rust/src/lib.rs` alongside the Task 2 work:

```rust
/// Whether a streaming grant has already been completed on this machine.
#[no_mangle]
pub extern "C" fn spotifly_has_streaming_credentials() -> i32 {
    let cache = Cache::new(Some(credentials_cache_dir()), None, None, None).ok();
    match cache.and_then(|c| c.credentials()) {
        Some(_) => 1,
        None => 0,
    }
}
```

In `SpeakersView.swift`, add the row that runs the same grant, shown only when this Mac is
absent from the device list:

```swift
            // Without a streaming grant this Mac never registers with Spotify Connect, so it is
            // genuinely not in the device list. That absence is the indicator; this row is the
            // way back.
            if !authViewModel.hasStreamingCredentials {
                Button {
                    Task { await authViewModel.authorizeStreaming() }
                } label: {
                    Label("speakers.enable_this_mac", systemImage: "laptopcomputer.slash")
                }
                .disabled(authViewModel.isAuthorizingStreaming)
            }
```

In `LoggedInView.swift`, present the alert on the flag from Task 5:

```swift
        .alert(
            "playback.needs_authorization_title",
            isPresented: $playbackViewModel.needsStreamingAuthorization,
        ) {
            Button("playback.needs_authorization_authorize") {
                Task { await authViewModel.authorizeStreaming() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("playback.needs_authorization_message")
        }
```

Add the new keys to `Localizable.xcstrings` alongside the existing `auth.*` entries:
`auth.enable_playback_label`, `auth.enable_playback_note`, `auth.enable_playback_button`,
`auth.enable_playback_waiting`, `auth.enable_playback_failed`, `speakers.enable_this_mac`,
`playback.needs_authorization_title`, `playback.needs_authorization_message`,
`playback.needs_authorization_authorize`.

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`, exit code 0.

- [ ] **Step 5: Commit**

```bash
swiftformat --swiftversion 6.3 Spotifly/
git add Spotifly SpotiflyTests rust/src/lib.rs
git commit -m "Add the enable-playback step and the way back to it"
```

---

### Task 7: Logout clears the streaming credentials

`logout()` tears down the librespot session and clears the keychain, but the credentials
directory is new and nothing removes it. Leaving it behind means the next launch can connect the
account that just logged out.

**Files:**
- Modify: `spotifly-code/rust/src/lib.rs`
- Modify: `spotifly-code/Spotifly/SpotifyPlayer.swift`
- Modify: `spotifly-code/Spotifly/ViewModels/AuthViewModel.swift:65-85`
- Test: `spotifly-code/rust/src/lib.rs`, in `mod tests`

**Interfaces:**
- Consumes: `credentials_cache_dir()` (Task 1).
- Produces: `spotifly_clear_streaming_credentials()` and
  `SpotifyPlayer.clearStreamingCredentials()`.

- [ ] **Step 1: Write the failing test**

```rust
    #[test]
    fn clearing_streaming_credentials_removes_the_directory() {
        let dir = credentials_cache_dir();
        std::fs::create_dir_all(&dir).expect("create cache dir");
        std::fs::write(dir.join("credentials.json"), b"{}").expect("write credentials");
        assert!(dir.exists());

        clear_streaming_credentials();

        assert!(!dir.exists(), "logout must not leave credentials behind");
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path rust/Cargo.toml clearing_streaming_credentials`
Expected: FAIL — `cannot find function 'clear_streaming_credentials'`.

- [ ] **Step 3: Implement**

```rust
/// Removes the cached streaming credentials. Split from the FFI entry point so it can be
/// tested directly.
fn clear_streaming_credentials() {
    let dir = credentials_cache_dir();
    if let Err(e) = std::fs::remove_dir_all(&dir) {
        if e.kind() != std::io::ErrorKind::NotFound {
            debug!("Could not remove streaming credentials: {e}");
        }
    }
}

/// Called on logout, after the session teardown.
#[no_mangle]
pub extern "C" fn spotifly_clear_streaming_credentials() {
    clear_streaming_credentials();
}
```

In `SpotifyPlayer.swift`:

```swift
    /// Removes the cached streaming credentials so the next launch cannot connect the account
    /// that just logged out.
    static func clearStreamingCredentials() async {
        await Task.detached(priority: .userInitiated) {
            spotifly_clear_streaming_credentials()
        }.value
    }
```

In `AuthViewModel.logout()`, after the existing `shutdownForLogout()` await and before the
keychain is cleared:

```swift
        await PlaybackViewModel.shared.shutdownForLogout()

        // The streaming credentials are a file, not a keychain item, so clearing the keychain
        // does not touch them. Removed after the teardown so no live session rewrites them.
        await SpotifyPlayer.clearStreamingCredentials()
        hasStreamingCredentials = false

        SpotifyAuth.clearAuthResult()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust/Cargo.toml`
Expected: PASS.

Run:
```bash
xcodebuild -scheme Spotifly -configuration Debug test -destination 'platform=macOS' -only-testing:SpotiflyTests GENERATE_INFOPLIST_FILE=YES 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`, exit code 0.

- [ ] **Step 5: Commit**

```bash
swiftformat --swiftversion 6.3 Spotifly/SpotifyPlayer.swift Spotifly/ViewModels/AuthViewModel.swift
git add rust/src/lib.rs Spotifly/SpotifyPlayer.swift Spotifly/ViewModels/AuthViewModel.swift
git commit -m "Clear the streaming credentials on logout"
```

---

## Manual verification

The grant cannot be unit-tested — it needs a browser and a human. Run this once the tasks are
done, since it is what proves the whole plan:

1. Delete `~/Library/Application Support/Spotifly/credentials` to simulate a fresh install.
2. Launch. Confirm the app reaches the logged-in UI on step 1 alone, that browsing works, and
   that Spotifly is **absent** from Speakers.
3. With another device playing, press play on an album. It should start there, and the
   now-playing bar should follow within a second — no alert.
4. With no device active, press play. The alert appears; choose Authorize.
5. Approve in the browser. Spotifly appears in Speakers, and playback works locally.
6. Check the log for `login5 auth_token` succeeding — no `INVALID_CREDENTIALS`.
7. Sleep the Mac, wake it, and confirm the reconnect rebuilds with no token request in the log.
8. Log out and back in; confirm the credentials directory is gone after logout.

## Notes for the implementer

- **The two client ids are never interchangeable.** If a step ever tempts you to pass the Swift
  access token to a librespot call, or a keymaster token to `api.spotify.com`, the design is
  being violated — both were measured to fail.
- **The appendix is in a different repository and optional.** It commits in `librespot/`, not
  `spotifly-code/`, and nothing in Tasks 1-7 waits for it.
- **Do not add a cancel button** to the authorization UI. The Rust side bounds its own wait, and
  in-flight cancellation was deliberately cut — see the design doc.

---

## Appendix: upstream hardening (optional)

Playback is restored by Tasks 1-7 on **stock librespot** — that is the exact code path the
probe in the design doc validated. The work below fixes two real defects in librespot-oauth,
but neither blocks the fix, and landing it upstream keeps CLAUDE.md's "no fork or patch is
required" property intact. Open it as its own PR; the checkout tracks `dev` with no pin, so
adopting it later is a pull.

Until it lands, Spotifly runs with the stock behaviour: the callback listener accepts the first
connection that reaches the port whatever it is, and waits indefinitely for one. A wedged grant
needs an app restart — the same position every other librespot client is in today.

### Upstream hardening for librespot-oauth — *not on the critical path*

Two defects in one function. The listener terminates on the first connection to reach the port
whatever it is, and `state` is generated then thrown away. Fixing both here keeps the flow in
librespot instead of hand-rolling PKCE in Swift, and is upstreamable on its own.

**Files:**
- Modify: `/Users/ralph/code/spotifly/librespot/oauth/src/lib.rs`
- Test: same file, in a `#[cfg(test)] mod tests` block at the end

**Interfaces:**
- Consumes: nothing.
- Produces: `OAuthClientBuilder::new(client_id, redirect_uri, scopes).open_in_browser().build()?`
  and `client.get_access_token() -> Result<OAuthToken, OAuthError>`, unchanged in signature but
  now returning `OAuthError::AuthCodeListenerTimeout` instead of blocking forever, and ignoring
  callbacks whose `state` does not match. Task 2 calls this once it lands.

Work on a branch in the librespot repo:

```bash
cd /Users/ralph/code/spotifly/librespot && git checkout -b oauth-validate-state-and-timeout dev
```

- [ ] **Step 1: Write the failing test**

Add at the end of `oauth/src/lib.rs`:

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_code_and_state() {
        let (code, state) =
            get_code_and_state("http://localhost/login?code=abc&state=xyz").unwrap();
        assert_eq!(code.secret(), "abc");
        assert_eq!(state, "xyz");
    }

    #[test]
    fn missing_state_is_an_error() {
        assert!(matches!(
            get_code_and_state("http://localhost/login?code=abc"),
            Err(OAuthError::AuthCodeStateMismatch)
        ));
    }

    #[test]
    fn callback_matches_only_the_expected_state() {
        assert!(callback_is_expected("http://localhost/login?code=a&state=s", "s"));
        assert!(!callback_is_expected("http://localhost/login?code=a&state=other", "s"));
        // An unsolicited probe with no query string at all must not end the flow.
        assert!(!callback_is_expected("http://localhost/", "s"));
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p librespot-oauth`
Expected: FAIL — `cannot find function 'get_code_and_state'` and `callback_is_expected`.

- [ ] **Step 3: Implement**

Add the error variant to `OAuthError` (after `AuthCodeNotFound`):

```rust
    /// The callback's `state` parameter was absent or did not match the request.
    #[error("Auth callback state did not match the request")]
    AuthCodeStateMismatch,

    /// No valid callback arrived before the deadline.
    #[error("Timed out waiting for the auth callback")]
    AuthCodeListenerTimeout,
```

Add the two helpers next to `get_code`:

```rust
/// Return both the code and the `state` parameter from the redirect URI.
fn get_code_and_state(redirect_url: &str) -> Result<(AuthorizationCode, String), OAuthError> {
    let code = get_code(redirect_url)?;
    let url = Url::parse(redirect_url).map_err(|e| OAuthError::AuthCodeBadUri {
        uri: redirect_url.to_string(),
        e,
    })?;
    let state = url
        .query_pairs()
        .find(|(key, _)| key == "state")
        .map(|(_, state)| state.into_owned())
        .ok_or(OAuthError::AuthCodeStateMismatch)?;

    Ok((code, state))
}

/// Whether a callback belongs to the authorization we started.
fn callback_is_expected(redirect_url: &str, expected_state: &str) -> bool {
    matches!(
        get_code_and_state(redirect_url),
        Ok((_, state)) if state == expected_state
    )
}
```

Change `set_auth_url` to keep the CSRF token — it currently discards it on the `let (auth_url, _)`
binding:

```rust
    fn set_auth_url(&self) -> (PkceCodeVerifier, CsrfToken) {
        let (pkce_challenge, pkce_verifier) = PkceCodeChallenge::new_random_sha256();
        let request_scopes: Vec<oauth2::Scope> =
            self.scopes.iter().map(|s| Scope::new(s.into())).collect();
        let (auth_url, csrf_token) = self
            .client
            .authorize_url(CsrfToken::new_random)
            .add_scopes(request_scopes)
            .set_pkce_challenge(pkce_challenge)
            .url();

        if self.should_open_url {
            open::that_in_background(auth_url.as_str());
        }
        println!("Browse to: {auth_url}");

        (pkce_verifier, csrf_token)
    }
```

Replace `get_authcode_listener` so it keeps serving until a callback matching `state` arrives or
the deadline passes. Note the read timeout on the accepted stream: a connection that never sends
a complete request line parks in `read_line()`, where a listener-level deadline cannot reach it.

```rust
/// How long the whole callback wait may take, and how long any one client may dawdle.
const CALLBACK_DEADLINE: Duration = Duration::from_secs(300);
const CALLBACK_READ_TIMEOUT: Duration = Duration::from_secs(5);

fn get_authcode_listener(
    socket_address: SocketAddr,
    message: String,
    expected_state: &str,
) -> Result<AuthorizationCode, OAuthError> {
    let listener =
        TcpListener::bind(socket_address).map_err(|e| OAuthError::AuthCodeListenerBind {
            addr: socket_address,
            e,
        })?;
    listener
        .set_nonblocking(false)
        .map_err(|_| OAuthError::AuthCodeListenerRead)?;
    info!("OAuth server listening on {socket_address:?}");

    let deadline = Instant::now() + CALLBACK_DEADLINE;

    for stream in listener.incoming() {
        if Instant::now() >= deadline {
            return Err(OAuthError::AuthCodeListenerTimeout);
        }
        let Ok(mut stream) = stream else { continue };

        // Bound the read: a client that connects and says nothing must not park us here.
        let _ = stream.set_read_timeout(Some(CALLBACK_READ_TIMEOUT));

        let mut request_line = String::new();
        if BufReader::new(&stream).read_line(&mut request_line).is_err() {
            continue;
        }

        let Some(path) = request_line.split_whitespace().nth(1) else {
            continue;
        };
        let redirect_url = "http://localhost".to_string() + path;

        // Anything that is not our callback is ignored rather than ending the flow.
        if !callback_is_expected(&redirect_url, expected_state) {
            debug!("Ignoring unexpected request on the OAuth callback port");
            continue;
        }

        let response = format!(
            "HTTP/1.1 200 OK\r\ncontent-length: {}\r\n\r\n{}",
            message.len(),
            message
        );
        stream
            .write_all(response.as_bytes())
            .map_err(|_| OAuthError::AuthCodeListenerWrite)?;

        return get_code_and_state(&redirect_url).map(|(code, _)| code);
    }

    Err(OAuthError::AuthCodeListenerTerminated)
}
```

Update the two callers in `get_access_token` and `get_access_token_async` to the new shapes —
`set_auth_url` now returns a tuple, and the listener takes the expected state:

```rust
        let (pkce_verifier, csrf_token) = self.set_auth_url();

        let code = match get_socket_address(&self.redirect_uri) {
            Some(addr) => get_authcode_listener(addr, self.message.clone(), csrf_token.secret()),
            _ => get_authcode_stdin(),
        }?;
```

Add `use std::time::Instant;` to the imports if it is not already there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test -p librespot-oauth`
Expected: PASS, 3 tests.

Then confirm nothing else broke: `cargo check -p librespot-oauth -p librespot`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/ralph/code/spotifly/librespot
git add oauth/src/lib.rs
git commit -m "oauth: validate callback state and bound the callback wait"
```

The Spotifly build picks this up automatically — `rust/Cargo.toml` uses path dependencies with
no revision pin. Open the upstream PR when convenient; the local checkout carries it meanwhile.

---

