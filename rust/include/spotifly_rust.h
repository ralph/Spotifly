#ifndef SPOTIFLY_RUST_H
#define SPOTIFLY_RUST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Pointer parameters and return values are non-null by default within this
// region. The few that may be null are marked explicitly with `_Nullable`.
#pragma clang assume_nonnull begin

/// Frees a C string allocated by this library. Tolerates NULL (e.g. the result
/// of a function that returned NULL on error).
void spotifly_free_string(char* _Nullable s);

// ============================================================================
// Error codes
// ============================================================================
//
// Command functions return a SpotiflyResult:
//   SpotiflyResultOk                   ( 0) = success
//   SpotiflyResultError                (-1) = general error
//   SpotiflyResultSessionDisconnected  (-2) = session disconnected, needs reinitialization
//                                             (call spotifly_init_player again with a fresh token)
//   SpotiflyResultSessionNotConnected  (-3) = session not connected (command rejected,
//                                             wait for session to connect)
//
// On SpotiflyResultSessionDisconnected, the Spirc channel has closed (e.g., due
// to idle timeout). Get a fresh access token and call spotifly_init_player() to
// reconnect.
//
// On SpotiflyResultSessionNotConnected, the session is not yet connected. Wait
// for the session_connected callback before retrying the command.
typedef enum __attribute__((enum_extensibility(open))) SpotiflyResult : int32_t {
    SpotiflyResultOk = 0,
    SpotiflyResultError = -1,
    SpotiflyResultSessionDisconnected = -2,
    SpotiflyResultSessionNotConnected = -3,
} SpotiflyResult;

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player.
/// Must be called before play/pause operations.
///
/// @param access_token A token minted with librespot's client id, or NULL to connect from
///                     the credentials cached by spotifly_authorize_streaming(). NULL is the
///                     normal case: only the first init after a grant carries a token.
SpotiflyResult spotifly_init_player(const char* _Nullable access_token);

/// Completes the one-time streaming authorization with a token Swift has already minted:
/// connects once and persists the credentials every later init connects from.
///
/// Swift owns the OAuth flow itself (see KeymasterAuth), because the same token also
/// authorizes pathfinder and spclient.
///
/// @param access_token A token minted with Spotify's desktop client id. Must not be NULL.
///
/// Returns:
///    0 = Authorized, credentials cached
///   -1 = Failed
///   -2 = Superseded by a logout; any credentials written were removed again
int32_t spotifly_authorize_streaming(const char* _Nonnull access_token);

/// Whether a streaming grant has already been completed on this machine.
/// Returns 1 when credentials are cached, 0 otherwise.
int32_t spotifly_has_streaming_credentials(void);

/// The Spotify account id the last successful grant authenticated as, or NULL.
/// The caller owns the string and must free it with spotifly_free_string().
char* _Nullable spotifly_last_grant_account(void);

/// Removes the cached streaming credentials.
/// Call on logout, after the session teardown, so the next launch cannot connect the
/// account that just logged out. Removing credentials that are not there is not an error.
void spotifly_clear_streaming_credentials(void);

/// Plays multiple tracks in sequence.
///
/// @param track_uris_json JSON array of track URIs as a C string
SpotiflyResult spotifly_play_tracks(const char* track_uris_json);

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
SpotiflyResult spotifly_play_uri(const char* uri_or_url, int32_t track_index);

/// Pauses playback.
SpotiflyResult spotifly_pause(void);

/// Clears any buffered audio samples.
/// Call this before sleep to prevent stale audio playing on wake.
void spotifly_clear_audio_buffer(void);

/// Resumes playback.
SpotiflyResult spotifly_resume(void);

/// Stops playback completely.
SpotiflyResult spotifly_stop(void);

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
SpotiflyResult spotifly_shutdown(void);

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT block auto-reconnect.
SpotiflyResult spotifly_disconnect(void);

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

/// Callback function type for Connect device deactivation notifications.
typedef void (*BecameInactiveCallback)(void);

/// Registers a callback fired when this device stops being the active Connect device.
///
/// This reports *activity*, not health: it fires on an explicit disconnect, on shutdown,
/// and whenever another device takes over playback. Do not treat it as a connection
/// failure — read the connection snapshot (spotifly_get_connection_state) for that.
void spotifly_register_became_inactive_callback(BecameInactiveCallback callback);

/// Callback function type for Connect device activation notifications.
typedef void (*BecameActiveCallback)(void);

/// Registers a callback fired when this device becomes the active Connect device.
///
/// Also activity, not readiness: the session was already connected beforehand. Use the
/// connection snapshot to decide when playback commands can be sent.
void spotifly_register_became_active_callback(BecameActiveCallback callback);

/// Callback function type for session client changed notifications.
/// Receives a JSON string containing client_id, client_name, client_brand_name, client_model_name.
typedef void (*SessionClientChangedCallback)(const char* client_json);

/// Registers a callback to receive session client changed notifications.
/// Called when the controlling Spotify client changes (e.g., which app initiated playback).
void spotifly_register_session_client_changed_callback(SessionClientChangedCallback callback);

/// Returns 1 if session is connected and ready for commands, 0 otherwise.
/// Use this to check if playback commands will be accepted.
int32_t spotifly_is_session_connected(void);

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

/// Callback function type for active device change notifications.
/// Receives the device ID string of the currently active Spotify Connect device.
typedef void (*ActiveDeviceCallback)(const char* device_id);

/// Registers a callback to receive active device ID changes from cluster updates.
/// Called on every cluster update — use this to track which device is active
/// without polling the Web API.
void spotifly_register_active_device_callback(ActiveDeviceCallback callback);

/// Callback function type for Connect device-list updates.
/// Receives the JSON array `/me/player/devices` used to return, so the same decoder serves both.
typedef void (*DevicesCallback)(const char* devices_json);

/// Registers a callback to receive the Connect device list from cluster updates.
/// Fires only when the list actually changes, not on every cluster tick.
void spotifly_register_devices_callback(DevicesCallback callback);

/// Callback function type for connection state change notifications.
/// Receives a JSON string containing full connection state.
typedef void (*ConnectionStateCallback)(const char* state_json);

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
void spotifly_register_connection_state_callback(ConnectionStateCallback callback);

// ============================================================================
// Audio output callbacks
// ============================================================================

/// Audio playback control event, delivered to AudioControlCallback.
typedef enum __attribute__((enum_extensibility(open))) SpotiflyAudioControlEvent : uint8_t {
    SpotiflyAudioControlEventStop = 0,
    SpotiflyAudioControlEventStart = 1,
    SpotiflyAudioControlEventClear = 2,
} SpotiflyAudioControlEvent;

/// Callback function type for receiving raw PCM audio data.
/// Audio format: 44100 Hz, 2 channels (stereo), Float32, interleaved.
/// Called from a background thread - must be thread-safe.
///
/// @param samples Pointer to interleaved f32 samples
/// @param sample_count Number of f32 values (frames * 2 for stereo)
typedef void (*AudioDataCallback)(const float* _Nullable samples, size_t sample_count);

/// Callback function type for audio control events (start/stop/clear).
/// Called from a background thread - must be thread-safe.
typedef void (*AudioControlCallback)(SpotiflyAudioControlEvent event);

/// Registers a callback to receive raw PCM audio data from the decoder.
/// The callback is called for each decoded audio chunk (~4096 samples).
void spotifly_register_audio_data_callback(AudioDataCallback callback);

/// Registers a callback for audio playback control events (start/stop/clear).
void spotifly_register_audio_control_callback(AudioControlCallback callback);

/// Returns the current connection state as a JSON string, or NULL on error.
/// Caller must free the returned string using spotifly_free_string().
char* _Nullable spotifly_get_connection_state(void);

/// Skips to the next track in the queue.
SpotiflyResult spotifly_next(void);

/// Skips to the previous track in the queue.
SpotiflyResult spotifly_previous(void);

/// Seeks to the given position in milliseconds.
SpotiflyResult spotifly_seek(uint32_t position_ms);

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
SpotiflyResult spotifly_play_radio(const char* track_uri);

/// Sets the playback volume (0-65535).
///
/// @param volume Volume level (0 = muted, 65535 = max)
SpotiflyResult spotifly_set_volume(uint16_t volume);

/// Sets shuffle mode for the current playback context.
///
/// @param enabled true to enable shuffle, false to disable it
SpotiflyResult spotifly_set_shuffle(bool enabled);

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
SpotiflyResult spotifly_transfer_to_local(void);

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
///
/// @param to_device_id The target device ID to transfer playback to
SpotiflyResult spotifly_transfer_playback(const char* to_device_id);

/// Adds content to the queue.
/// Supports tracks, episodes, albums, playlists, artists, and shows.
/// For albums/playlists/artists/shows, all tracks/episodes are resolved and queued.
///
/// @param uri Spotify URI (e.g., "spotify:track:xxx", "spotify:album:xxx")
SpotiflyResult spotifly_add_to_queue(const char* uri);

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

#pragma clang assume_nonnull end

#ifdef __cplusplus
}
#endif

#endif // SPOTIFLY_RUST_H
