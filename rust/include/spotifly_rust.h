#ifndef SPOTIFLY_RUST_H
#define SPOTIFLY_RUST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Frees a C string allocated by this library.
void spotifly_free_string(char* s);

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player with the given access token and device information.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
///
/// @param access_token OAuth access token
/// @param device_name Device name (e.g., "iPhone 15 Pro" or "MacBook Pro")
/// @param device_type Device type (0 = Computer/macOS, 1 = Smartphone/iOS)
int32_t spotifly_init_player(const char* access_token, const char* device_name, int32_t device_type);

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

/// Returns all queue items as a JSON string.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL on error.
char* spotifly_get_all_queue_items(void);

/// Cleans up the player resources.
void spotifly_cleanup_player(void);

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error.
///
/// @param volume Volume level (0 = muted, 65535 = max)
int32_t spotifly_set_volume(uint16_t volume);

/// Gets the current playback volume (0-65535).
/// Returns the volume on success, 0 on error.
uint16_t spotifly_get_volume(void);

#ifdef __cplusplus
}
#endif

#endif // SPOTIFLY_RUST_H
