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
// Error codes
// ============================================================================
//
// Most functions return:
//   0  = success
//  -1  = general error
//  -2  = session disconnected, needs reinitialization
//        (call spotifly_init_player again with a fresh token)
//  -3  = session not connected (command rejected, wait for session to connect)
//
// When you receive -2, the Spirc channel has closed (e.g., due to idle timeout).
// Get a fresh access token and call spotifly_init_player() to reconnect.
//
// When you receive -3, the session is not yet connected. Wait for the
// session_connected callback before retrying the command.

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
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
/// Returns 0 on success, -1 on error.
int32_t spotifly_play_uri(const char* uri_or_url, int32_t track_index);

/// Pauses playback.
/// Returns 0 on success, -1 on error, -2 if session disconnected.
int32_t spotifly_pause(void);

/// Clears any buffered audio samples.
/// Call this before sleep to prevent stale audio playing on wake.
void spotifly_clear_audio_buffer(void);

/// Resumes playback.
/// Returns 0 on success, -1 on error, -2 if session disconnected.
int32_t spotifly_resume(void);

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
int32_t spotifly_stop(void);

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
int32_t spotifly_shutdown(void);

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT block auto-reconnect.
/// Returns 0 on success, -1 on error.
int32_t spotifly_disconnect(void);

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before spotifly_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
void spotifly_cleanup(void);

/// Returns 1 if currently playing, 0 otherwise.
int32_t spotifly_is_playing(void);

/// Returns 1 if this device is the active Spotify Connect device, 0 otherwise.
/// When not active, playback controls should use Web API instead of Spirc.
int32_t spotifly_is_active_device(void);

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

/// Callback function type for volume change notifications.
/// Receives the new volume (0-65535).
typedef void (*VolumeCallback)(uint16_t volume);

/// Registers a callback to receive volume change notifications.
/// Called when the volume is changed remotely (e.g., from another Spotify Connect device).
void spotifly_register_volume_callback(VolumeCallback callback);

/// Callback function type for loading notifications.
/// Receives a JSON string containing track_uri and position_ms.
/// This fires earlier than TrackChanged (~180ms vs ~620ms after remote command).
typedef void (*LoadingCallback)(const char* loading_json);

/// Registers a callback to receive loading notifications.
/// Called when a new track starts loading (before metadata is fetched).
void spotifly_register_loading_callback(LoadingCallback callback);

/// Callback function type for queue change notifications.
/// Receives a JSON string containing track_uri of the added track.
typedef void (*QueueChangedCallback)(const char* queue_changed_json);

/// Registers a callback to receive queue change notifications.
/// Called when a remote device adds a track to the queue.
void spotifly_register_queue_changed_callback(QueueChangedCallback callback);

/// Callback function type for session disconnection notifications.
typedef void (*SessionDisconnectedCallback)(void);

/// Registers a callback to receive session disconnection notifications.
/// Called when the Spotify session is disconnected (e.g., idle timeout).
/// When this fires, reinitialize the player with a fresh token.
void spotifly_register_session_disconnected_callback(SessionDisconnectedCallback callback);

/// Callback function type for session connection notifications.
typedef void (*SessionConnectedCallback)(void);

/// Registers a callback to receive session connection notifications.
/// Called when the Spotify session is connected and ready for playback commands.
void spotifly_register_session_connected_callback(SessionConnectedCallback callback);

/// Callback function type for session client changed notifications.
/// Receives a JSON string containing client_id, client_name, client_brand_name, client_model_name.
typedef void (*SessionClientChangedCallback)(const char* client_json);

/// Registers a callback to receive session client changed notifications.
/// Called when the controlling Spotify client changes (e.g., which app initiated playback).
void spotifly_register_session_client_changed_callback(SessionClientChangedCallback callback);

/// Returns 1 if session is connected and ready for commands, 0 otherwise.
/// Use this to check if playback commands will be accepted.
int32_t spotifly_is_session_connected(void);

/// Callback function type for token request notifications.
/// Called when Rust's reconnection loop needs a fresh access token.
typedef void (*TokenRequestCallback)(void);

/// Registers a callback to receive token request notifications.
/// When Rust needs a fresh token to reconnect, it calls this callback.
/// Swift should respond by calling spotifly_set_token() with a fresh access token.
void spotifly_register_token_request_callback(TokenRequestCallback callback);

/// Provides a fresh access token for reconnection.
/// Called by Swift in response to the token request callback.
/// The token is passed to the pending reconnection attempt.
void spotifly_set_token(const char* token);

/// Forces a reconnection to Spotify servers.
/// Use this after system wake to ensure a fresh connection before playback.
/// Returns:
///   0 = Reconnection triggered
///   1 = Reconnection already in progress
///   2 = No session initialized (nothing to reconnect)
int32_t spotifly_force_reconnect(void);

/// Callback function type for context loaded notifications.
/// Receives a JSON string containing context_uri, current track, next tracks, and previous tracks.
typedef void (*ContextLoadedCallback)(const char* context_json);

/// Registers a callback to receive context loaded notifications.
/// Called when a context (playlist, album, etc.) is loaded with the list of track URIs.
/// This fires immediately when context is loaded locally (before Spotify servers acknowledge).
void spotifly_register_context_loaded_callback(ContextLoadedCallback callback);

/// Callback function type for added to queue notifications.
/// Receives a JSON string containing track_uri of the queued track.
typedef void (*AddedToQueueCallback)(const char* added_json);

/// Registers a callback to receive added to queue notifications.
/// Called when a track is manually added to the queue (via add_to_queue).
void spotifly_register_added_to_queue_callback(AddedToQueueCallback callback);

/// Callback function type for set queue notifications.
/// Receives a JSON string containing next_tracks and prev_tracks arrays with uri and provider.
typedef void (*SetQueueCallback)(const char* set_queue_json);

/// Registers a callback to receive set queue notifications.
/// Called when the queue is set/modified (via set_queue command from mobile app).
void spotifly_register_set_queue_callback(SetQueueCallback callback);

/// Callback function type for connection state change notifications.
/// Receives a JSON string containing full connection state.
typedef void (*ConnectionStateCallback)(const char* state_json);

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
void spotifly_register_connection_state_callback(ConnectionStateCallback callback);

/// Returns the current connection state as a JSON string.
/// Caller must free the returned string using spotifly_free_string().
char* spotifly_get_connection_state(void);

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error, -2 if session disconnected.
int32_t spotifly_next(void);

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if session disconnected.
int32_t spotifly_previous(void);

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if session disconnected.
int32_t spotifly_seek(uint32_t position_ms);

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
int32_t spotifly_play_radio(const char* track_uri);

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error, -2 if session disconnected.
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

/// Adds content to the queue.
/// Supports tracks, episodes, albums, playlists, artists, and shows.
/// For albums/playlists/artists/shows, all tracks/episodes are resolved and queued.
/// Returns 0 on success, -1 on error.
///
/// @param uri Spotify URI (e.g., "spotify:track:xxx", "spotify:album:xxx")
int32_t spotifly_add_to_queue(const char* uri);

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

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before spotifly_init_player() to take effect.
///
/// @param volume Initial volume level (0 = muted, 65535 = max)
void spotifly_set_initial_volume(uint16_t volume);

#ifdef __cplusplus
}
#endif

#endif // SPOTIFLY_RUST_H
