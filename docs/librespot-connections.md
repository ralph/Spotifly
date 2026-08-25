# Librespot Connection Architecture

This document describes the connection architecture used by librespot to communicate with Spotify servers.

## Overview

Librespot maintains multiple connections to Spotify infrastructure:

```
┌─────────────────────────────────────────────────────────────────┐
│                        Access Point (AP)                         │
│                     (TCP, Shannon-encrypted)                     │
├─────────────────────────────────────────────────────────────────┤
│  Session                                                         │
│  ├── Mercury (request-response RPC)                             │
│  ├── Channel (audio streaming)                                  │
│  ├── AudioKey (decryption keys)                                 │
│  └── Login5Manager (HTTP tokens for Dealer/spclient)            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ (Login5 token)
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Dealer (WebSocket)                            │
│              (wss://dealer.spotify.com:443)                      │
├─────────────────────────────────────────────────────────────────┤
│  Spirc (Spotify Remote Control)                                  │
│  └── Subscribes to cluster updates, player commands, volume     │
└─────────────────────────────────────────────────────────────────┘
```

## Connection Details

### Session (TCP)

**Source:** `librespot-core/src/session.rs`

The Session is the core connection to Spotify. It's a raw TCP connection to an Access Point (AP), encrypted with the Shannon cipher after an initial handshake.

**State held:**
- `session_id` - UUID generated on creation
- `connection_id` - Set by Spirc after Dealer connection
- `auth_data` - Credentials from login
- `user_data` - Country, username, account attributes
- `time_delta` - Server time offset

**Connection flow:**
1. Resolve AP via `apresolve.spotify.com` (tries up to 6 APs on failure)
2. TCP connect to AP (e.g., `ap-gae2.spotify.com:4070`)
3. Handshake: `ClientHello` → `APResponseMessage` → `ClientResponsePlaintext`
4. Key exchange (Diffie-Hellman), derive Shannon encryption keys
5. Authenticate: Send credentials → receive `APWelcome`
6. Spawn `DispatchTask` for incoming packets
7. Spawn sender task for outgoing packets

**Keep-alive protocol:**
```
Server → Ping
         (client waits 60s)
Client → Pong
Server → PongAck
         (repeat)
```

Timeouts:
- Initial ping expected within 20s of connection
- General timeout: 80s since last ping activity
- PongAck expected within 20s of sending Pong

**Auto-reconnect:** NO. Once `session.is_invalid()` returns true, the Session is dead forever. A new Session must be created.

**Disconnect detection:**
- `DispatchTask` receives I/O error → calls `session.shutdown()`
- Keep-alive timeout → returns `Err(io::Error::TimedOut)`
- Manual `session.shutdown()` call

---

### Mercury

**Source:** `librespot-core/src/mercury/mod.rs`

Mercury is a request-response RPC protocol that runs on top of the Session's TCP connection. It's used for metadata fetching and subscriptions.

**Not a separate connection** - it multiplexes on the Session transport.

**Request types:**
- `get()` - Fetch metadata (GET method)
- `send()` - Post data (SEND method)
- `subscribe()` - Subscribe to updates (SUB method)

**Protocol:**
- Requests identified by sequence number
- Multi-part responses assembled from multiple packets
- Subscriptions return `mpsc::UnboundedReceiver` for updates

**Auto-reconnect:** No. Depends entirely on Session.

---

### Dealer (WebSocket)

**Source:** `librespot-core/src/dealer/mod.rs`

The Dealer is a separate WebSocket connection used for real-time device communication. It's independent of the Session TCP connection but requires a Login5 token obtained via the Session.

**Connection:** `wss://dealer.spotify.com:443`

**Message types:**
- **Messages** (fire-and-forget): Broadcast to subscribers matching URI prefix
- **Requests** (request-reply): Expect a response with `success: bool`

**URI routing examples:**
- `hm://pusher/v1/connections/` - Connection ID updates
- `hm://connect-state/v1/cluster` - Cluster state updates (device list)
- `hm://connect-state/v1/player/command` - Playback commands
- `hm://connect-state/v1/connect/volume` - Volume changes

**Keep-alive:**
- Ping every 30 seconds
- Pong timeout: 3 seconds

**Auto-reconnect:** YES. Reconnects every 10 seconds if connection lost. However, this is useless if the Session is dead because no fresh tokens can be obtained.

---

### Spirc (Spotify Remote Control)

**Source:** `librespot-connect/src/spirc.rs`

Spirc is the device control protocol that enables Spotify Connect functionality. It's not a connection itself but a protocol layer that runs on top of Dealer.

**Dependencies:**
- Requires active Session (for tokens and authentication)
- Requires active Dealer (for message delivery)

**Subscriptions via Dealer:**
- `hm://pusher/v1/connections/` - Get connection_id
- `hm://connect-state/v1/cluster` - Device list and playback state
- `hm://connect-state/v1/player/command` - Receive play/pause/seek/etc.
- `hm://connect-state/v1/connect/volume` - Volume changes
- `spotify:user:attributes:update` - User settings changes

**Message types (from `spirc.proto`):**
- `kMessageTypeHello` (0x1) - Device introduction
- `kMessageTypeGoodbye` (0x2) - Device disconnection
- `kMessageTypeNotify` (0xa) - State update
- `kMessageTypeLoad` (0x14) - Load context/playlist
- `kMessageTypePlay/Pause/Seek/Prev/Next` - Playback control
- `kMessageTypeVolume` (0x1b) - Volume change

**Auto-reconnect:** No. The Spirc task checks `session.is_invalid()` in its main loop and exits when the Session dies.

---

### Access Point Resolution

**Source:** `librespot-core/src/apresolve.rs`

Before connecting, librespot resolves Access Point addresses via HTTP:

```
GET https://apresolve.spotify.com/?type=accesspoint&type=dealer&type=spclient
```

Response contains lists of endpoints:
- `accesspoint` - For Session TCP (e.g., `ap-gae2.spotify.com:4070`)
- `dealer` - For Dealer WebSocket (e.g., `dealer.spotify.com:443`)
- `spclient` - For HTTP API (e.g., `spclient.wg.spotify.com:443`)

Fallback defaults if resolution fails:
- `ap.spotify.com:443`
- `dealer.spotify.com:443`
- `spclient.wg.spotify.com:443`

---

## Dependency Graph

```
ApResolver (HTTP)
    │
    ▼
Session (TCP) ─────────────────────┐
    │                              │
    ├── Mercury                    │
    │   └── Metadata fetching      │
    │                              │
    ├── Channel                    │
    │   └── Audio streaming        │
    │                              │
    ├── AudioKey                   │
    │   └── Decryption keys        │
    │                              │
    └── Login5Manager (HTTP) ──────┤
            │                      │
            │ (access token)       │
            ▼                      │
        Dealer (WebSocket) ◄───────┘
            │              (checks session.is_invalid())
            │
            ▼
        Spirc (Device Control)
```

---

## Disconnect Scenarios

### Session TCP Drops

This is the most common disconnect scenario (AP disconnects, network blip, NAT timeout).

**What happens:**
1. `DispatchTask` receives I/O error from TCP stream
2. Calls `session.shutdown()` which sets `invalid = true`
3. Mercury: Pending futures fail, subscriptions dropped
4. Channel: Audio download streams error
5. Spirc: Detects `session.is_invalid()` in select!, breaks event loop
6. `PlayerEvent::SessionDisconnected` is emitted
7. Dealer: May still try to reconnect (but can't get fresh tokens)

**Recovery:**
1. Drop old Session completely
2. Create new Session with fresh credentials
3. Re-initialize Spirc
4. Resume playback from saved position

### Dealer WebSocket Drops

Less critical because Dealer auto-reconnects.

**What happens:**
1. WebSocket send/receive task fails
2. Dealer `run()` loop detects failure
3. Waits 10 seconds
4. Attempts reconnection with fresh token from Login5

**If Session is still alive:** Dealer reconnects, Spirc continues normally.

**If Session is dead:** Dealer reconnection fails (no valid token), Spirc has already exited.

### Keep-Alive Timeout

**What happens:**
1. No Ping received within 80s (or no PongAck within 20s)
2. Keep-alive task returns `Err(io::Error::TimedOut)`
3. Same flow as Session TCP drop

---

## Reconnection Strategy

Since librespot doesn't auto-reconnect the Session, the consuming application must handle this:

```
SessionDisconnected event
        │
        ▼
    Capture playback state
    (track URI, position, playing)
        │
        ▼
    Call cleanup (drop old Session/Spirc)
        │
        ▼
    Wait with exponential backoff
    (10s → 20s → 40s → 60s max)
        │
        ▼
    Create new Session
        │
        ▼
    Initialize new Spirc
        │
        ▼
    Resume playback from saved state
```

**Tips from Spotify's AP behavior:**
- APs are notorious for dropping long-lived TCP connections
- Lower keep-alive interval (30s instead of 60s) keeps NAT tables fresh
- Use `StoredCredentials` for silent re-authentication
- Buffer provides ~5 seconds of audio - fast reconnect can be seamless

---

## Debug Logging

**This is librespot's logging, not Spotifly's.** Spotifly no longer embeds librespot,
so `RUST_LOG` does nothing to it — see the Debug Logging section of `CLAUDE.md` for the
module prefixes the Swift stack logs under.

Against a librespot build, raw Spirc state transitions come from:

```bash
RUST_LOG=librespot_connect::spirc=trace ./librespot
```

which shows Mercury frames, Connect state changes, device updates and cluster
notifications.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `core/src/session.rs` | Session lifecycle, keep-alive, packet dispatch |
| `core/src/mercury/mod.rs` | Request-response RPC |
| `core/src/dealer/mod.rs` | WebSocket client with auto-reconnect |
| `core/src/apresolve.rs` | AP service discovery |
| `connect/src/spirc.rs` | Device control state machine |
| `protocol/proto/spirc.proto` | Spirc message definitions |
| `protocol/proto/connect.proto` | Cluster state definitions |
| `docs/connection.md` | Official connection documentation |
| `docs/dealer.md` | Official Dealer documentation |
