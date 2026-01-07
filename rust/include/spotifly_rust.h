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
int32_t spotifly_play_track(const char* uri_or_url);

/// Pauses playback.
/// Returns 0 on success, -1 on error.
int32_t spotifly_pause(void);

/// Resumes playback.
/// Returns 0 on success, -1 on error.
int32_t spotifly_resume(void);

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
int32_t spotifly_stop(void);

/// Returns 1 if currently playing, 0 otherwise.
int32_t spotifly_is_playing(void);

/// Returns the current playback position in milliseconds.
/// If playing, interpolates from last known position.
/// Returns 0 if not playing or no position available.
uint32_t spotifly_get_position_ms(void);

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error or if at end of queue.
int32_t spotifly_next(void);

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error or if at start of queue.
int32_t spotifly_previous(void);

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error.
int32_t spotifly_seek(uint32_t position_ms);

/// Jumps to a specific track in the queue by index and starts playing.
/// Returns 0 on success, -1 on error.
int32_t spotifly_jump_to_index(size_t index);

/// Returns the number of tracks in the queue.
size_t spotifly_get_queue_length(void);

/// Returns the current track index in the queue (0-based).
size_t spotifly_get_current_index(void);

/// Returns the track name at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
char* spotifly_get_queue_track_name(size_t index);

/// Returns the artist name at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
char* spotifly_get_queue_artist_name(size_t index);

/// Returns the album art URL at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
char* spotifly_get_queue_album_art_url(size_t index);

/// Returns the URI at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
char* spotifly_get_queue_uri(size_t index);

/// Returns the track duration in milliseconds at the given index.
/// Returns 0 if index is out of bounds.
uint32_t spotifly_get_queue_duration_ms(size_t index);

/// Returns the album ID at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or album ID is not available.
char* spotifly_get_queue_album_id(size_t index);

/// Returns the artist ID at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or artist ID is not available.
char* spotifly_get_queue_artist_id(size_t index);

/// Returns the external URL (Spotify web link) at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or external URL is not available.
char* spotifly_get_queue_external_url(size_t index);

/// Returns all queue items as a JSON string.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL on error.
char* spotifly_get_all_queue_items(void);

/// Adds a track to the end of the current queue without clearing it.
/// Returns 0 on success, -1 on error.
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
int32_t spotifly_add_to_queue(const char* track_uri);

/// Adds a track to play next (after the currently playing track).
/// If nothing is playing, adds it to the queue.
/// Returns 0 on success, -1 on error.
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
int32_t spotifly_add_next_to_queue(const char* track_uri);

/// Gets radio tracks for a seed track and returns them as JSON.
/// Returns a JSON array of track URIs, or NULL on error.
/// Caller must free the string with spotifly_free_string().
///
/// @param track_uri Spotify track URI (e.g., "spotify:track:xxx")
char* spotifly_get_radio_tracks(const char* track_uri);

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error.
///
/// @param volume Volume level (0 = muted, 65535 = max)
int32_t spotifly_set_volume(uint16_t volume);

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
