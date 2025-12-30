use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::cache::Cache;
use librespot_core::spotify_id::SpotifyId;
use librespot_core::SpotifyUri;
use librespot_oauth::{OAuthClientBuilder, OAuthError};
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use once_cell::sync::Lazy;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
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

struct OAuthResult {
    access_token: String,
    refresh_token: Option<String>,
    expires_in: u64,
    #[allow(dead_code)]
    scopes: Vec<String>,
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

/// Plays a track by its Spotify URI (e.g., "spotify:track:4iV5W9uYEdYUVa79Axb7Rh").
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_track(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        eprintln!("Play error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Play error: invalid track_uri string");
                return -1;
            }
        }
    };

    // Parse the track ID from URI
    let track_id = if uri_str.starts_with("spotify:track:") {
        uri_str.strip_prefix("spotify:track:").unwrap().to_string()
    } else {
        uri_str.clone()
    };

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Play error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        let spotify_id = SpotifyId::from_base62(&track_id)
            .map_err(|e| format!("Invalid track ID: {:?}", e))?;
        
        let track_uri = SpotifyUri::Track { id: spotify_id };

        player.load(track_uri, true, 0);
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
