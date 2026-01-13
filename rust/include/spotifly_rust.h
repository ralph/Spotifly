#ifndef SPOTIFLY_RUST_H
#define SPOTIFLY_RUST_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Frees a C string allocated by this library.
void spotifly_free_string(char* s);

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
int32_t spotifly_init_player(const char* access_token);

/// Plays multiple tracks in sequence.
/// Returns 0 on success, -1 on error.
///
/// @param track_uris_json JSON array of track URIs as a C string
int32_t spotifly_play_tracks(const char* track_uris_json);

/// Plays content by its Spotify URI or URL.
/// Supports tracks, albums, playlists, and artists.
/// Returns 0 on success, -1 on error.
int32_t spotifly_play_uri(const char* uri_or_url);

/// Pauses playback.
/// Returns 0 on success, -1 on error.
int32_t spotifly_pause(void);

/// Resumes playback.
/// Returns 0 on success, -1 on error.
int32_t spotifly_resume(void);

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
int32_t spotifly_stop(void);

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
int32_t spotifly_shutdown(void);

/// Returns 1 if currently playing, 0 otherwise.
int32_t spotifly_is_playing(void);

/// Returns 1 if Spirc is initialized and connected, 0 otherwise.
int32_t spotifly_is_spirc_ready(void);

/// Returns the current playback position in milliseconds.
/// If playing, interpolates from last known position.
/// Returns 0 if not playing or no position available.
uint32_t spotifly_get_position_ms(void);

/// Callback function type for queue updates.
/// Receives a JSON string containing the queue state.
typedef void (*QueueCallback)(const char* queue_json);

/// Registers a callback to receive queue updates.
void spotifly_register_queue_callback(QueueCallback callback);

/// Callback function type for playback state updates.
/// Receives a JSON string containing playback state (is_playing, is_paused, track_uri, etc.).
typedef void (*PlaybackStateCallback)(const char* state_json);

/// Registers a callback to receive playback state updates from Mercury/Spirc.
void spotifly_register_playback_state_callback(PlaybackStateCallback callback);

/// Callback function type for state update notifications.
/// Called when a track change occurs and the queue should be refreshed.
typedef void (*StateUpdateCallback)(void);

/// Registers a callback to receive state update notifications.
/// This fires on track changes to signal Swift to fetch updated queue state.
void spotifly_register_state_update_callback(StateUpdateCallback callback);

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error or if at end of queue.
int32_t spotifly_next(void);

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error or if at start of queue.
int32_t spotifly_previous(void);

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error.
int32_t spotifly_seek(uint32_t position_ms);

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
int32_t spotifly_play_radio(const char* track_uri);

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error.
///
/// @param volume Volume level (0 = muted, 65535 = max)
int32_t spotifly_set_volume(uint16_t volume);

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
int32_t spotifly_transfer_to_local(void);

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
/// Returns 0 on success, -1 on error.
///
/// @param to_device_id The target device ID to transfer playback to
int32_t spotifly_transfer_playback(const char* to_device_id);

// ============================================================================
// Playback settings (take effect on next player initialization)
// ============================================================================

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization.
///
/// @param bitrate Bitrate level (0, 1, or 2)
void spotifly_set_bitrate(uint8_t bitrate);

/// Gets the current bitrate setting.
/// 0 = 96 kbps, 1 = 160 kbps, 2 = 320 kbps
uint8_t spotifly_get_bitrate(void);

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization.
///
/// @param enabled Whether gapless playback is enabled
void spotifly_set_gapless(bool enabled);

/// Gets the current gapless playback setting.
bool spotifly_get_gapless(void);

#ifdef __cplusplus
}
#endif

#endif // SPOTIFLY_RUST_H
