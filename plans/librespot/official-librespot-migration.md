# Official Librespot Migration

## Goal

Move Spotifly to an unmodified, pinned official librespot revision after replacing
the patched soft-reconnect design with a deterministic full
Player/Session/Spirc rebuild and playback rehydration.

## Plan

1. **Correct lifecycle semantics**
   - Separate Connect device active/inactive events from real network
     connected/disconnected state.
   - Keep Rust as the single owner of librespot lifecycle and recovery.

2. **Replace soft reconnect**
   - Before recovery, capture the latest playback intent: context URI, track URI,
     position, playing/paused state, and any pending explicit play request.
   - Invalidate the old reconnect generation.
   - Rebuild Session, Player, Mixer, and Spirc together.
   - If Spotifly was locally active, restore playback with one deterministic
     `LoadRequest`; otherwise remain passive.
   - Remove the Player-preserving soft reconnect, `Player::set_session` usage, and
     its pending-play watchdog.

3. **Verify recovery**
   - Test normal device handoff, another client taking control, short network
     outages, an outage during a play request, and sleep/wake.
   - Accept a short audible interruption during recovery in exchange for simpler,
     deterministic state.

4. **Switch to official librespot**
   - Confirm the unchanged Rust wrapper builds against the selected official source.
   - Pin an official commit or release containing `Spirc::add_to_queue` and opt-in
     `PlayerEvent::SetQueue`; do not track a moving branch.
   - Delete the `spotifly-dev` dependency requirement and update build/contributor
     documentation.

## Completion criteria

- Spotifly contains no integration behavior that requires a patched librespot.
- Only one reconnect/restart generation can mutate Rust player state.
- Playback state is rehydrated after a short outage and accurately reflected in
  Swift.
- Device transfers do not trigger network recovery.
- The project builds and passes the recovery test matrix against pinned, unmodified
  official librespot sources.
