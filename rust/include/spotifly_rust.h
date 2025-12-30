#ifndef SPOTIFLY_RUST_H
#define SPOTIFLY_RUST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initiates the Spotify OAuth flow. Opens the browser for user authentication.
/// Returns 0 on success, -1 on error.
/// After successful authentication, use spotifly_get_access_token() to retrieve the token.
///
/// @param client_id Spotify API client ID as a C string
/// @param redirect_uri OAuth redirect URI as a C string
int32_t spotifly_start_oauth(const char* client_id, const char* redirect_uri);

/// Returns the access token as a C string. Caller must free the string with spotifly_free_string().
/// Returns NULL if no token is available.
char* spotifly_get_access_token(void);

/// Returns the refresh token as a C string. Caller must free the string with spotifly_free_string().
/// Returns NULL if no refresh token is available.
char* spotifly_get_refresh_token(void);

/// Returns the token expiration time in seconds.
/// Returns 0 if no token is available.
uint64_t spotifly_get_token_expires_in(void);

/// Checks if an OAuth result is available.
/// Returns 1 if available, 0 otherwise.
int32_t spotifly_has_oauth_result(void);

/// Clears the stored OAuth result.
void spotifly_clear_oauth_result(void);

/// Frees a C string allocated by this library.
void spotifly_free_string(char* s);

// ============================================================================
// Playback functions
// ============================================================================

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
int32_t spotifly_init_player(const char* access_token);

/// Plays a track by its Spotify URI (e.g., "spotify:track:4iV5W9uYEdYUVa79Axb7Rh").
/// Returns 0 on success, -1 on error.
int32_t spotifly_play_track(const char* track_uri);

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

/// Cleans up the player resources.
void spotifly_cleanup_player(void);

#ifdef __cplusplus
}
#endif

#endif // SPOTIFLY_RUST_H
