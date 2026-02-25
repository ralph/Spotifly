# Network + Session Stability Plan

Status: Active
Review mode: Step-by-step (one numbered item at a time, user review before commit)

## Problem Summary

After an overnight session disconnect, clicking play resumes the current track
(via reconnect + auto-resume), but when that track ends the next track loads
**paused** instead of continuing playback. The queue is full — the issue is that
Spirc's `handle_next` checks `connect_state.is_playing()` (the remote-facing
state) which can be `false` during buffering/loading transitions, even though
the local intent is to keep playing.

### Root Cause (from log analysis)

1. Session dies at 17:36 (idle timeout). App looks alive but is a zombie.
2. User clicks play at 08:21. Old Player happily reports Playing, but Spirc
   hits `unexpected shutdown` because Session is invalid.
3. Reconnection loop fires: full cleanup → new Session/Player/Spirc →
   `transfer(None)` → reloads track as paused → auto-resume kicks in → plays.
4. Track plays to end. `handle_next` calls `connect_state.is_playing()` which
   returns `false` (connect state is `playing:true, paused:true, buffering:true`
   at that moment). Next track loads with `start_playing = false`. Playback
   stops.

## Plan

### Step 1: Fix "next track loads paused" bug in Spirc

**File:** `librespot/connect/src/spirc.rs` — `handle_next()`

The function currently does:
```rust
let continue_playing = self.connect_state.is_playing();
```

`connect_state.is_playing()` returns `player.is_playing && !player.is_paused`,
which reflects the remote-facing status (used for other Connect devices). During
loading/buffering transitions this can be `false` even when local playback
intent is "playing".

**Fix:** Use the local `play_status` field instead:
```rust
let continue_playing = matches!(
    self.play_status,
    SpircPlayStatus::Playing { .. } | SpircPlayStatus::LoadingPlay { .. }
);
```

This is a one-line change that directly fixes the observed bug. The same issue
likely affects `handle_prev` (line ~1759) — fix it there too.

### Step 2: Detect stale session before acting on user commands

**File:** `repos/rust/src/lib.rs` — `spotifly_resume`, `spotifly_play_uri`, etc.

Currently, when the user clicks play on a zombie session, the old Player
accepts the Play command and fires a Playing event, then the dead Spirc
crashes and triggers a reconnect. This creates a confusing sequence.

**Fix:** In the FFI play/resume functions, check whether the session is valid
before forwarding the command. If invalid, trigger a reconnect-then-resume
flow instead of playing on the dead session. This avoids the "play → crash →
reconnect → transfer → reload track" dance and goes straight to reconnect.

Alternatively (simpler): check `session.is_invalid()` on the periodic session
ping (already runs every 2 minutes in the log). If the session is dead and we
aren't already reconnecting, proactively trigger reconnection so the app is
ready when the user comes back.

### Step 3: Make transfer(None) conditional on reconnect

**File:** `repos/rust/src/lib.rs` — `init_player_async`

Currently `transfer(None)` is called unconditionally after every reconnect.
This re-fetches the full playback state from Spotify's servers and re-loads
the current track from scratch, which:
- Causes unnecessary latency
- Can reset queue/context state
- Reloads a track that was already buffered locally

**Fix:** On reconnect (when `RECONNECTING` is true and we were the active
device), skip `transfer(None)`. Instead, just re-register the device state
with the connect-state API (the `put_connect_state` that already happens in
Spirc::new). Then issue `spirc.play()` if we were playing before disconnect.

Only call `transfer(None)` on fresh start (first connection after app launch).

### Step 4 (deferred): Soft reconnect — keep Player alive across reconnects

**Prerequisite:** Steps 1-3 working and stable.

`Player::set_session(new_session)` already exists in librespot. This means we
can keep the Player (and its audio buffers, preloaded next track, decoder
state) alive across reconnects.

**Approach:**
1. Create new Session, authenticate it.
2. Call `player.set_session(new_session)` on the existing Player.
3. Create new Spirc with the existing Player + new Session.
4. Skip `transfer(None)` — the Player is already playing.
5. Re-register device state with connect-state API.

This would give interrupt-free audio during reconnects (priority 3). Defer
until priorities 1 and 2 are solid. It requires careful handling of:
- Spirc creation with an already-playing Player (normally Spirc creates fresh)
- Avoiding duplicate event listeners on the Player
- The Mixer — can likely be reused as-is since SoftMixer is session-independent

## Execution Rules

1. Work only one numbered step at a time (`#1`, then `#2`, ...).
2. After each step, stop for user inspection before commit.
3. Keep this file current by checking off completed steps.
4. If scope changes, update this plan first, then implement.

## Checklist

- [ ] #1 Fix `handle_next` (and `handle_prev`) to use `play_status` instead of `connect_state.is_playing()`
- [ ] #2 Detect stale session proactively or before user commands
- [ ] #3 Make `transfer(None)` conditional (reconnect vs fresh start)
- [ ] #4 (deferred) Soft reconnect keeping Player alive via `set_session`
