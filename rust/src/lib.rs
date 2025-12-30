use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::cache::Cache;
use librespot_core::SpotifyUri;
use librespot_metadata::{Album, Artist, Metadata, Playlist, Track};
use librespot_oauth::{OAuthClientBuilder, OAuthError};
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use once_cell::sync::Lazy;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

// Global tokio runtime for async operations
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

// Thread-safe storage for OAuth result
static OAUTH_RESULT: Lazy<Mutex<Option<OAuthResult>>> = Lazy::new(|| Mutex::new(None));

// Player state
static PLAYER: Lazy<Mutex<Option<Arc<Player>>>> = Lazy::new(|| Mutex::new(None));
static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
static IS_PLAYING: AtomicBool = AtomicBool::new(false);
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> = Lazy::new(|| Mutex::new(None));

// Queue state
static QUEUE: Lazy<Mutex<Vec<QueueItem>>> = Lazy::new(|| Mutex::new(Vec::new()));
static CURRENT_INDEX: AtomicUsize = AtomicUsize::new(0);

struct OAuthResult {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: u64,
    #[allow(dead_code)]
    scopes: Vec<String>,
}

#[derive(Clone)]
struct QueueItem {
    uri: String,
    track_name: String,
    artist_name: String,
    album_art_url: String,
}

// Helper function to convert URL to URI
fn url_to_uri(input: &str) -> String {
    // If already a URI, return as-is
    if input.starts_with("spotify:") {
        return input.to_string();
    }

    // If it's a URL, parse it
    if input.starts_with("http://") || input.starts_with("https://") {
        if let Some(marker_pos) = input.find("open.spotify.com/") {
            let after_marker = &input[marker_pos + "open.spotify.com/".len()..];
            let parts: Vec<&str> = after_marker.split('/').collect();

            // Filter out locale prefixes like "intl-de"
            let filtered: Vec<&str> = parts.iter()
                .filter(|p| !p.starts_with("intl-"))
                .copied()
                .collect();

            if filtered.len() >= 2 {
                let content_type = filtered[0];
                let mut id = filtered[1];

                // Remove query parameters
                if let Some(query_pos) = id.find('?') {
                    id = &id[..query_pos];
                }

                return format!("spotify:{}:{}", content_type, id);
            }
        }
    }

    // Return original if can't parse
    input.to_string()
}

// Helper function to parse Spotify URI from string
fn parse_spotify_uri(uri_str: &str) -> Result<SpotifyUri, String> {
    SpotifyUri::from_uri(uri_str)
        .map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}

// Helper function to extract album art URL from track
fn get_album_art_url(_track: &Track) -> String {
    // Album art URL can be fetched from Spotify Web API if needed
    // For now, return empty string as the metadata doesn't include covers
    String::new()
}

// Load album tracks into queue
async fn load_album(session: &Session, album_uri: SpotifyUri) -> Result<Vec<QueueItem>, String> {
    let album = Album::get(session, &album_uri).await
        .map_err(|e| format!("Failed to load album: {:?}", e))?;

    let mut queue_items = Vec::new();

    // Get track URIs from album
    let track_uris: Vec<SpotifyUri> = album.tracks()
        .cloned()
        .collect();

    // Fetch metadata for each track
    for track_uri in track_uris {
        if let Ok(track) = Track::get(session, &track_uri).await {
            let track_name = track.name.clone();
            let artist_name = track.artists.iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            let album_art_url = get_album_art_url(&track);

            queue_items.push(QueueItem {
                uri: track_uri.to_string(),
                track_name,
                artist_name,
                album_art_url,
            });
        }
    }

    Ok(queue_items)
}

// Load playlist tracks into queue
async fn load_playlist(session: &Session, playlist_uri: SpotifyUri) -> Result<Vec<QueueItem>, String> {
    let playlist = Playlist::get(session, &playlist_uri).await
        .map_err(|e| format!("Failed to load playlist: {:?}", e))?;

    let mut queue_items = Vec::new();

    for item_uri in playlist.tracks() {
        // Only handle track URIs, skip episodes
        if matches!(item_uri, SpotifyUri::Track { .. }) {
            let track_uri = item_uri.clone();

            // Fetch track metadata
            if let Ok(track) = Track::get(session, &track_uri).await {
                let track_name = track.name.clone();
                let artist_name = track.artists.iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                let album_art_url = get_album_art_url(&track);

                queue_items.push(QueueItem {
                    uri: track_uri.to_string(),
                    track_name,
                    artist_name,
                    album_art_url,
                });
            }
        }
    }

    Ok(queue_items)
}

// Load artist top tracks into queue
async fn load_artist(session: &Session, artist_uri: SpotifyUri) -> Result<Vec<QueueItem>, String> {
    let artist = Artist::get(session, &artist_uri).await
        .map_err(|e| format!("Failed to load artist: {:?}", e))?;

    let mut queue_items = Vec::new();

    // Get top tracks - artist.top_tracks is a CountryTopTracks iterator
    // Each item has a tracks field which is Tracks(Vec<SpotifyUri>), access with .0
    let track_uris: Vec<SpotifyUri> = artist.top_tracks
        .iter()
        .flat_map(|top_track| top_track.tracks.0.clone())
        .collect();

    // Fetch metadata for each track
    for track_uri in track_uris {
        if let Ok(track) = Track::get(session, &track_uri).await {
            let track_name = track.name.clone();
            let artist_name = track.artists.iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            let album_art_url = get_album_art_url(&track);

            queue_items.push(QueueItem {
                uri: track_uri.to_string(),
                track_name,
                artist_name,
                album_art_url,
            });
        }
    }

    Ok(queue_items)
}

/// Initiates the Spotify OAuth flow. Opens the browser for user authentication.
/// Returns 0 on success, -1 on error.
/// After successful authentication, use spotifly_get_access_token() to retrieve the token.
///
/// # Parameters
/// - client_id: Spotify API client ID as a C string
/// - redirect_uri: OAuth redirect URI as a C string
#[no_mangle]
pub extern "C" fn spotifly_start_oauth(client_id: *const c_char, redirect_uri: *const c_char) -> i32 {
    // Validate and convert C strings to Rust strings
    if client_id.is_null() || redirect_uri.is_null() {
        eprintln!("OAuth error: client_id or redirect_uri is null");
        return -1;
    }

    let client_id_str = unsafe {
        match CStr::from_ptr(client_id).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("OAuth error: invalid client_id string");
                return -1;
            }
        }
    };

    let redirect_uri_str = unsafe {
        match CStr::from_ptr(redirect_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("OAuth error: invalid redirect_uri string");
                return -1;
            }
        }
    };

    let result = RUNTIME.block_on(async {
        perform_oauth(&client_id_str, &redirect_uri_str).await
    });

    match result {
        Ok(oauth_result) => {
            let mut guard = OAUTH_RESULT.lock().unwrap();
            *guard = Some(oauth_result);
            0
        }
        Err(e) => {
            eprintln!("OAuth error: {:?}", e);
            -1
        }
    }
}

async fn perform_oauth(client_id: &str, redirect_uri: &str) -> Result<OAuthResult, OAuthError> {
    let scopes = vec![
        "user-read-private",
        "user-read-email",
        "streaming",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
    ];

    // Load HTML from external file at compile time
    let success_message = include_str!("oauth_success.html");

    let client = OAuthClientBuilder::new(client_id, redirect_uri, scopes)
        .open_in_browser()
        .with_custom_message(success_message)
        .build()?;

    let token = client.get_access_token()?;

    let now = Instant::now();
    let expires_in_secs = if token.expires_at > now {
        token.expires_at.duration_since(now).as_secs()
    } else {
        0
    };

    Ok(OAuthResult {
        access_token: token.access_token,
        refresh_token: Some(token.refresh_token),
        expires_in: expires_in_secs,
        scopes: token.scopes,
    })
}

/// Returns the access token as a C string. Caller must free the string with spotifly_free_string().
/// Returns NULL if no token is available.
#[no_mangle]
pub extern "C" fn spotifly_get_access_token() -> *mut c_char {
    let guard = OAUTH_RESULT.lock().unwrap();
    match guard.as_ref() {
        Some(result) => {
            match CString::new(result.access_token.clone()) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

/// Returns the refresh token as a C string. Caller must free the string with spotifly_free_string().
/// Returns NULL if no refresh token is available.
#[no_mangle]
pub extern "C" fn spotifly_get_refresh_token() -> *mut c_char {
    let guard = OAUTH_RESULT.lock().unwrap();
    match guard.as_ref() {
        Some(result) => {
            match &result.refresh_token {
                Some(token) => {
                    match CString::new(token.clone()) {
                        Ok(cstr) => cstr.into_raw(),
                        Err(_) => ptr::null_mut(),
                    }
                }
                None => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

/// Returns the token expiration time in seconds.
/// Returns 0 if no token is available.
#[no_mangle]
pub extern "C" fn spotifly_get_token_expires_in() -> u64 {
    let guard = OAUTH_RESULT.lock().unwrap();
    match guard.as_ref() {
        Some(result) => result.expires_in,
        None => 0,
    }
}

/// Checks if an OAuth result is available.
/// Returns 1 if available, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_has_oauth_result() -> i32 {
    let guard = OAUTH_RESULT.lock().unwrap();
    if guard.is_some() { 1 } else { 0 }
}

/// Clears the stored OAuth result.
#[no_mangle]
pub extern "C" fn spotifly_clear_oauth_result() {
    let mut guard = OAUTH_RESULT.lock().unwrap();
    *guard = None;
}

/// Frees a C string allocated by this library.
#[no_mangle]
pub extern "C" fn spotifly_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_init_player(access_token: *const c_char) -> i32 {
    if access_token.is_null() {
        eprintln!("Player init error: access_token is null");
        return -1;
    }

    let token_str = unsafe {
        match CStr::from_ptr(access_token).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Player init error: invalid access_token string");
                return -1;
            }
        }
    };

    // Check if we already have a session
    {
        let session_guard = SESSION.lock().unwrap();
        if session_guard.is_some() {
            // Already initialized
            return 0;
        }
    }

    let result = RUNTIME.block_on(async {
        init_player_async(&token_str).await
    });

    match result {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("Player init error: {}", e);
            -1
        }
    }
}

async fn init_player_async(access_token: &str) -> Result<(), String> {
    let session_config = SessionConfig {
        device_id: format!("spotifly_{}", std::process::id()),
        ..Default::default()
    };

    // Create session with access token
    let credentials = librespot_core::authentication::Credentials::with_access_token(access_token);
    
    let cache = Cache::new(None::<std::path::PathBuf>, None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;

    let session = Session::new(session_config, Some(cache));
    session.connect(credentials, true).await
        .map_err(|e| format!("Session connect error: {}", e))?;

    // Create mixer
    let mixer_config = MixerConfig::default();
    let mixer = SoftMixer::open(mixer_config)
        .map_err(|e| format!("Mixer error: {}", e))?;

    // Create player
    let player_config = PlayerConfig::default();
    let audio_format = AudioFormat::default();
    
    let backend = audio_backend::find(None).ok_or("No audio backend found")?;
    
    let player = Player::new(
        player_config,
        session.clone(),
        mixer.get_soft_volume(),
        move || backend(None, audio_format),
    );

    // Get event channel from player
    let mut event_channel = player.get_player_event_channel();

    // Create channel for stopping event listener
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    // Spawn event listener task
    let player_clone = Arc::clone(&player);
    RUNTIME.spawn(async move {
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    break;
                }
                event = event_channel.recv() => {
                    match event {
                        Some(PlayerEvent::Playing { .. }) => {
                            IS_PLAYING.store(true, Ordering::SeqCst);
                        }
                        Some(PlayerEvent::Paused { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                        }
                        Some(PlayerEvent::Stopped { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                        }
                        Some(PlayerEvent::EndOfTrack { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            // Auto-advance to next track if available
                            let queue_guard = QUEUE.lock().unwrap();
                            let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);
                            if current_idx + 1 < queue_guard.len() {
                                let next_track = queue_guard[current_idx + 1].clone();
                                drop(queue_guard);
                                CURRENT_INDEX.store(current_idx + 1, Ordering::SeqCst);

                                // Parse and load next track
                                if let Ok(spotify_uri) = parse_spotify_uri(&next_track.uri) {
                                    player_clone.load(spotify_uri, true, 0);
                                    IS_PLAYING.store(true, Ordering::SeqCst);
                                }
                            } else {
                                drop(queue_guard);
                            }
                        }
                        None => break,
                        _ => {}
                    }
                }
            }
        }
        drop(player_clone);
    });

    // Store everything
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = Some(player);
    }
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = Some(session);
    }
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        *tx_guard = Some(tx);
    }

    Ok(())
}

/// Plays content by its Spotify URI or URL.
/// Supports tracks, albums, playlists, and artists.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_track(uri_or_url: *const c_char) -> i32 {
    if uri_or_url.is_null() {
        eprintln!("Play error: uri_or_url is null");
        return -1;
    }

    let input_str = unsafe {
        match CStr::from_ptr(uri_or_url).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Play error: invalid uri_or_url string");
                return -1;
            }
        }
    };

    // Convert URL to URI if needed
    let uri_str = url_to_uri(&input_str);

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Play error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            eprintln!("Play error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        // Parse the URI to determine type
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        match spotify_uri {
            SpotifyUri::Track { .. } => {
                // Single track - create queue with one item
                let track = Track::get(&session, &spotify_uri).await
                    .map_err(|e| format!("Failed to load track: {:?}", e))?;

                let track_name = track.name.clone();
                let artist_name = track.artists.first()
                    .map(|a| a.name.clone())
                    .unwrap_or_default();
                let album_art_url = get_album_art_url(&track);

                let queue_item = QueueItem {
                    uri: uri_str.clone(),
                    track_name,
                    artist_name,
                    album_art_url,
                };

                let mut queue_guard = QUEUE.lock().unwrap();
                queue_guard.clear();
                queue_guard.push(queue_item);
                drop(queue_guard);

                CURRENT_INDEX.store(0, Ordering::SeqCst);
                player.load(spotify_uri, true, 0);
            }
            SpotifyUri::Album { .. } => {
                // Load album tracks
                let queue_items = load_album(&session, spotify_uri.clone()).await?;

                if queue_items.is_empty() {
                    return Err("Album has no tracks".to_string());
                }

                let mut queue_guard = QUEUE.lock().unwrap();
                queue_guard.clear();
                queue_guard.extend(queue_items);
                drop(queue_guard);

                CURRENT_INDEX.store(0, Ordering::SeqCst);

                // Load first track
                let first_uri = parse_spotify_uri(&QUEUE.lock().unwrap()[0].uri)?;
                player.load(first_uri, true, 0);
            }
            SpotifyUri::Playlist { .. } => {
                // Load playlist tracks
                let queue_items = load_playlist(&session, spotify_uri.clone()).await?;

                if queue_items.is_empty() {
                    return Err("Playlist has no tracks".to_string());
                }

                let mut queue_guard = QUEUE.lock().unwrap();
                queue_guard.clear();
                queue_guard.extend(queue_items);
                drop(queue_guard);

                CURRENT_INDEX.store(0, Ordering::SeqCst);

                // Load first track
                let first_uri = parse_spotify_uri(&QUEUE.lock().unwrap()[0].uri)?;
                player.load(first_uri, true, 0);
            }
            SpotifyUri::Artist { .. } => {
                // Load artist top tracks
                let queue_items = load_artist(&session, spotify_uri.clone()).await?;

                if queue_items.is_empty() {
                    return Err("Artist has no top tracks".to_string());
                }

                let mut queue_guard = QUEUE.lock().unwrap();
                queue_guard.clear();
                queue_guard.extend(queue_items);
                drop(queue_guard);

                CURRENT_INDEX.store(0, Ordering::SeqCst);

                // Load first track
                let first_uri = parse_spotify_uri(&QUEUE.lock().unwrap()[0].uri)?;
                player.load(first_uri, true, 0);
            }
            _ => {
                return Err(format!("Unsupported URI type: {}", uri_str));
            }
        }

        Ok(())
    });

    match result {
        Ok(_) => {
            IS_PLAYING.store(true, Ordering::SeqCst);
            0
        }
        Err(e) => {
            eprintln!("Play error: {}", e);
            -1
        }
    }
}

/// Pauses playback.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_pause() -> i32 {
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.pause();
            IS_PLAYING.store(false, Ordering::SeqCst);
            0
        }
        None => {
            eprintln!("Pause error: player not initialized");
            -1
        }
    }
}

/// Resumes playback.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_resume() -> i32 {
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.play();
            IS_PLAYING.store(true, Ordering::SeqCst);
            0
        }
        None => {
            eprintln!("Resume error: player not initialized");
            -1
        }
    }
}

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_stop() -> i32 {
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.stop();
            IS_PLAYING.store(false, Ordering::SeqCst);
            0
        }
        None => {
            eprintln!("Stop error: player not initialized");
            -1
        }
    }
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_playing() -> i32 {
    if IS_PLAYING.load(Ordering::SeqCst) { 1 } else { 0 }
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error or if at end of queue.
#[no_mangle]
pub extern "C" fn spotifly_next() -> i32 {
    let queue_guard = QUEUE.lock().unwrap();
    let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

    if current_idx + 1 >= queue_guard.len() {
        drop(queue_guard);
        eprintln!("Next error: already at last track");
        return -1;
    }

    let next_track = queue_guard[current_idx + 1].clone();
    drop(queue_guard);

    CURRENT_INDEX.store(current_idx + 1, Ordering::SeqCst);

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Next error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let result = RUNTIME.block_on(async {
        parse_spotify_uri(&next_track.uri)
    });

    match result {
        Ok(uri) => {
            player.load(uri, true, 0);
            IS_PLAYING.store(true, Ordering::SeqCst);
            0
        }
        Err(e) => {
            eprintln!("Next error: {}", e);
            -1
        }
    }
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error or if at start of queue.
#[no_mangle]
pub extern "C" fn spotifly_previous() -> i32 {
    let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

    if current_idx == 0 {
        eprintln!("Previous error: already at first track");
        return -1;
    }

    let queue_guard = QUEUE.lock().unwrap();
    let prev_track = queue_guard[current_idx - 1].clone();
    drop(queue_guard);

    CURRENT_INDEX.store(current_idx - 1, Ordering::SeqCst);

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Previous error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let result = RUNTIME.block_on(async {
        parse_spotify_uri(&prev_track.uri)
    });

    match result {
        Ok(uri) => {
            player.load(uri, true, 0);
            IS_PLAYING.store(true, Ordering::SeqCst);
            0
        }
        Err(e) => {
            eprintln!("Previous error: {}", e);
            -1
        }
    }
}

/// Returns the number of tracks in the queue.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_length() -> usize {
    let queue_guard = QUEUE.lock().unwrap();
    queue_guard.len()
}

/// Returns the current track index in the queue (0-based).
#[no_mangle]
pub extern "C" fn spotifly_get_current_index() -> usize {
    CURRENT_INDEX.load(Ordering::SeqCst)
}

/// Returns the track name at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_track_name(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match CString::new(queue_guard[index].track_name.clone()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Returns the artist name at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_artist_name(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match CString::new(queue_guard[index].artist_name.clone()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Returns the album art URL at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_album_art_url(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match CString::new(queue_guard[index].album_art_url.clone()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Returns the URI at the given index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_uri(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match CString::new(queue_guard[index].uri.clone()) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => ptr::null_mut(),
    }
}

/// Cleans up the player resources.
#[no_mangle]
pub extern "C" fn spotifly_cleanup_player() {
    // Signal event listener to stop
    {
        let tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        if let Some(tx) = tx_guard.as_ref() {
            let _ = tx.send(());
        }
    }

    // Clear player
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = None;
    }

    // Clear session
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    // Clear event sender
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        *tx_guard = None;
    }

    IS_PLAYING.store(false, Ordering::SeqCst);
}
