/// Debug-only println! macro - compiles to nothing in release builds
macro_rules! debug_println {
    ($($arg:tt)*) => {
        #[cfg(debug_assertions)]
        println!($($arg)*);
    };
}

use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, Spirc};
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::cache::Cache;
use librespot_core::SpotifyUri;
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use librespot_protocol::connect::ClusterUpdate;
use librespot_protocol::player::PlayerState;
use once_cell::sync::Lazy;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;
use futures_util::StreamExt;

// Global tokio runtime for async operations
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

// Player state
static PLAYER: Lazy<Mutex<Option<Arc<Player>>>> = Lazy::new(|| Mutex::new(None));
static SESSION: Lazy<Mutex<Option<Session>>> = Lazy::new(|| Mutex::new(None));
static MIXER: Lazy<Mutex<Option<Arc<SoftMixer>>>> = Lazy::new(|| Mutex::new(None));
static SPIRC: Lazy<Mutex<Option<Arc<Spirc>>>> = Lazy::new(|| Mutex::new(None));
static DEVICE_ID: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static IS_PLAYING: AtomicBool = AtomicBool::new(false);
static SPIRC_READY: AtomicBool = AtomicBool::new(false);
static IS_ACTIVE_DEVICE: AtomicBool = AtomicBool::new(false);
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> = Lazy::new(|| Mutex::new(None));
static QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> = Lazy::new(|| Mutex::new(None));
static PLAYBACK_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> = Lazy::new(|| Mutex::new(None));
static STATE_UPDATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> = Lazy::new(|| Mutex::new(None));

// Position tracking - updated from player events
static POSITION_MS: AtomicU32 = AtomicU32::new(0);
static POSITION_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

// Playback settings (applied on player init)
// Bitrate: 0 = 96kbps, 1 = 160kbps (default), 2 = 320kbps
static BITRATE_SETTING: AtomicU8 = AtomicU8::new(1);
// Gapless playback: true by default (matches librespot default)
static GAPLESS_SETTING: AtomicBool = AtomicBool::new(true);

#[derive(Serialize)]
struct QueueItem {
    uri: String,
    name: String,
    artist: String,
    image_url: String,
    duration_ms: u32,
    album_name: String,
}

#[derive(Serialize)]
struct QueueState {
    track: Option<QueueItem>,
    next_tracks: Vec<QueueItem>,
    prev_tracks: Vec<QueueItem>,
}

#[derive(Serialize)]
struct PlaybackStateUpdate {
    is_playing: bool,
    is_paused: bool,
    track_uri: String,
    position_ms: i64,
    duration_ms: i64,
    shuffle: bool,
    repeat_track: bool,
    repeat_context: bool,
}

/// Get current timestamp in milliseconds since UNIX epoch
fn current_timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or(Duration::ZERO)
        .as_millis() as u64
}

/// Update position from player event
fn update_position(position_ms: u32) {
    POSITION_MS.store(position_ms, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(current_timestamp_ms(), Ordering::SeqCst);
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

/// Frees a C string allocated by this library.
#[no_mangle]
pub extern "C" fn spotifly_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            let _ = CString::from_raw(s);
        }
    }
}

/// Registers a callback to receive queue updates (as JSON string).
#[no_mangle]
pub extern "C" fn spotifly_register_queue_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = QUEUE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive playback state updates (as JSON string).
#[no_mangle]
pub extern "C" fn spotifly_register_playback_state_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = PLAYBACK_STATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive state update notifications.
/// This fires on track changes to signal Swift to fetch updated queue state.
#[no_mangle]
pub extern "C" fn spotifly_register_state_update_callback(callback: extern "C" fn()) {
    let mut cb = STATE_UPDATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_init_player(access_token: *const c_char) -> i32 {
    if access_token.is_null() {
        debug_println!("Player init error: access_token is null");
        return -1;
    }

    let token_str = unsafe {
        match CStr::from_ptr(access_token).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug_println!("Player init error: invalid access_token string");
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
        Err(_e) => {
            debug_println!("Player init error: {}", e);
            -1
        }
    }
}

async fn init_player_async(access_token: &str) -> Result<(), String> {
    let device_id = format!("spotifly_{}", std::process::id());
    let session_config = SessionConfig {
        device_id: device_id.clone(),
        ..Default::default()
    };

    // Store device ID for later use in transfers
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = Some(device_id);
    }

    // Create credentials - will be used by Spirc to connect
    let credentials = librespot_core::authentication::Credentials::with_access_token(access_token);

    let cache = Cache::new(None::<std::path::PathBuf>, None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;

    // Create session but DON'T connect yet - let Spirc handle the connection
    // This is important for Spirc to work properly with OAuth tokens
    let session = Session::new(session_config, Some(cache));

    // Create mixer
    let mixer_config = MixerConfig::default();
    let mixer = Arc::new(SoftMixer::open(mixer_config)
        .map_err(|e| format!("Mixer error: {}", e))?);

    // Store mixer globally
    {
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = Some(Arc::clone(&mixer));
    }

    // Create player with user settings
    let bitrate_setting = BITRATE_SETTING.load(Ordering::SeqCst);
    let bitrate = match bitrate_setting {
        0 => Bitrate::Bitrate96,
        2 => Bitrate::Bitrate320,
        _ => Bitrate::Bitrate160, // default
    };
    let gapless = GAPLESS_SETTING.load(Ordering::SeqCst);

    let _bitrate_kbps = match bitrate_setting {
        0 => 96,
        2 => 320,
        _ => 160,
    };
    debug_println!("[Spotifly] Player initialized: bitrate={}kbps, gapless={}", _bitrate_kbps, gapless);

    let player_config = PlayerConfig {
        bitrate,
        gapless,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
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
                        Some(PlayerEvent::Playing { position_ms, .. }) => {
                            IS_PLAYING.store(true, Ordering::SeqCst);
                            IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Paused { position_ms, .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            // Still active when paused - just not playing
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::PositionChanged { position_ms, .. }) => {
                            // Periodic position update (every 200ms)
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Seeked { position_ms, .. }) => {
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Stopped { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::EndOfTrack { .. }) => {
                            // Spirc handles auto-advance to next track automatically
                            // We just update local state here
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::TrackChanged { .. }) => {
                            // Notify Swift that track changed - it should fetch updated queue
                            debug_println!("[Spotifly] TrackChanged event - triggering state update callback");
                            let cb_guard = STATE_UPDATE_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                drop(cb_guard);
                                callback();
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

    // Store session, player, mixer, and event channel first
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = Some(Arc::clone(&player));
    }
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = Some(session.clone());
    }
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        *tx_guard = Some(tx);
    }

    // Setup Mercury Queue Listener
    // Subscribe to cluster updates which contain player state (queue)
    let queue_stream = session.dealer().listen_for(
        "hm://connect-state/v1/cluster",
        librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>
    ).map_err(|e| format!("Failed to subscribe to queue: {}", e))?;

    // Spawn task to process cluster updates (queue + playback state)
    RUNTIME.spawn(async move {
        debug_println!("[Spotifly] Cluster listener task started");
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            debug_println!("[Spotifly] Received cluster update message");
            match msg_result {
                Ok(cluster_update) => {
                    debug_println!("[Spotifly] ClusterUpdate parsed successfully");
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        debug_println!("[Spotifly] Cluster present");
                        if let Some(player_state) = cluster.player_state.into_option() {
                            debug_println!("[Spotifly] PlayerState present");
                            // Send playback state update
                            send_playback_state(&player_state);
                            // Send queue update
                            process_and_send_queue(player_state);
                        } else {
                            debug_println!("[Spotifly] No player_state in cluster");
                        }
                    } else {
                        debug_println!("[Spotifly] No cluster in update");
                    }
                }
                Err(_e) => {
                    debug_println!("[Spotifly] Failed to parse cluster update: {:?}", e);
                }
            }
        }
        debug_println!("[Spotifly] Cluster listener task ended");
    });

    // Create Spirc for Spotify Connect support (makes this app appear as a Connect device)
    // Spirc::new() will connect the session - this is the proper way per librespot examples
    let connect_config = ConnectConfig {
        name: "Spotifly".to_string(),
        device_type: DeviceType::Computer,
        initial_volume: 65535 / 2, // 50% volume
        ..Default::default()
    };

    match Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player,
        mixer as Arc<dyn Mixer>,
    )
    .await
    {
        Ok((spirc, spirc_task)) => {
            // Spawn Spirc background task
            let spirc_arc = Arc::new(spirc);
            RUNTIME.spawn(spirc_task);

            let mut spirc_guard = SPIRC.lock().unwrap();
            *spirc_guard = Some(spirc_arc);
            SPIRC_READY.store(true, Ordering::SeqCst);
            debug_println!("[Spotifly] Spirc ready - connected to Spotify Connect");
        }
        Err(_e) => {
            // Spirc failed - fall back to manual session connection for basic playback
            debug_println!("[Spotifly] Spirc init failed: {:?}", e);
            debug_println!("[Spotifly] Falling back to basic playback (Connect won't be available)");

            // Connect session manually so basic playback works
            if let Err(connect_err) = session.connect(credentials, true).await {
                return Err(format!("Session connect error: {}", connect_err));
            }
        }
    }

    Ok(())
}

fn send_playback_state(player_state: &PlayerState) {
    debug_println!("[Spotifly] send_playback_state called");
    let cb_guard = PLAYBACK_STATE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);

        // Extract track URI
        let track_uri = player_state
            .track
            .as_ref()
            .map(|t| t.uri.clone())
            .unwrap_or_default();

        // Extract playback options (shuffle, repeat)
        let options = player_state.options.as_ref();
        let shuffle = options.map(|o| o.shuffling_context).unwrap_or(false);
        let repeat_track = options
            .map(|o| o.repeating_track)
            .unwrap_or(false);
        let repeat_context = options
            .map(|o| o.repeating_context)
            .unwrap_or(false);

        let update = PlaybackStateUpdate {
            is_playing: player_state.is_playing,
            is_paused: player_state.is_paused,
            track_uri,
            position_ms: player_state.position_as_of_timestamp,
            duration_ms: player_state.duration,
            shuffle,
            repeat_track,
            repeat_context,
        };

        debug_println!(
            "[Spotifly] PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, shuffle={}, repeat_track={}, repeat_context={}",
            update.is_playing, update.is_paused, update.position_ms, update.duration_ms,
            update.shuffle, update.repeat_track, update.repeat_context
        );

        if let Ok(json) = serde_json::to_string(&update) {
            debug_println!("[Spotifly] Sending playback state JSON ({} bytes) to Swift callback", json.len());
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug_println!("[Spotifly] Playback state callback returned");
        } else {
            debug_println!("[Spotifly] Failed to serialize playback state to JSON");
        }
    } else {
        debug_println!("[Spotifly] No playback state callback registered, skipping update");
    }
}

fn process_and_send_queue(player_state: PlayerState) {
    debug_println!("[Spotifly] process_and_send_queue called");
    let cb_guard = QUEUE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        debug_println!("[Spotifly] Callback is registered, processing queue");
        let cb = callback;
        drop(cb_guard);

        // Helper to convert ProvidedTrack to QueueItem
        let to_queue_item = |t: &librespot_protocol::player::ProvidedTrack| -> QueueItem {
            QueueItem {
                uri: t.uri.clone(),
                name: String::new(),
                artist: String::new(),
                image_url: String::new(),
                duration_ms: 0,
                album_name: String::new(),
            }
        };

        // Process current track
        let current_track = player_state.track.into_option().and_then(|t| {
            debug_println!("[Spotifly] current track[0] uri='{}' provider='{}'", t.uri, t.provider);
            if t.uri.starts_with("spotify:track:") {
                Some(to_queue_item(&t))
            } else {
                None
            }
        });

        // Process next_tracks - stop at first delimiter (autoplay boundary)
        let mut next_tracks: Vec<QueueItem> = Vec::new();
        for (i, t) in player_state.next_tracks.iter().enumerate() {
            if i < 3 || !t.uri.starts_with("spotify:track:") {
                debug_println!("[Spotifly] next track[{}] uri='{}' provider='{}'", i, t.uri, t.provider);
            }

            // Stop at first delimiter - everything after is autoplay content
            if t.uri == "spotify:delimiter" {
                debug_println!("[Spotifly] Stopping at delimiter (index {}), hiding {} autoplay tracks", i, player_state.next_tracks.len() - i - 1);
                break;
            }

            if t.uri.starts_with("spotify:track:") {
                next_tracks.push(to_queue_item(t));
            }
        }

        // Process prev_tracks - also stop at delimiter (in reverse, it marks context boundary)
        let mut prev_tracks: Vec<QueueItem> = Vec::new();
        for (i, t) in player_state.prev_tracks.iter().enumerate() {
            if i < 3 || !t.uri.starts_with("spotify:track:") {
                debug_println!("[Spotifly] prev track[{}] uri='{}' provider='{}'", i, t.uri, t.provider);
            }

            // Stop at delimiter
            if t.uri == "spotify:delimiter" {
                debug_println!("[Spotifly] Stopping prev at delimiter (index {})", i);
                break;
            }

            if t.uri.starts_with("spotify:track:") {
                prev_tracks.push(to_queue_item(t));
            }
        }

        debug_println!("[Spotifly] Queue counts: current={}, next={}, prev={}",
            if current_track.is_some() { 1 } else { 0 },
            next_tracks.len(),
            prev_tracks.len()
        );

        let queue_state = QueueState {
            track: current_track,
            next_tracks,
            prev_tracks,
        };

        if let Ok(json) = serde_json::to_string(&queue_state) {
            debug_println!("[Spotifly] Sending queue JSON ({} bytes) to Swift callback", json.len());
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug_println!("[Spotifly] Swift callback returned");
        } else {
            debug_println!("[Spotifly] Failed to serialize queue state to JSON");
        }
    } else {
        debug_println!("[Spotifly] No callback registered, skipping queue update");
    }
}


/// Plays multiple tracks in sequence.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - track_uris_json: JSON array of track URIs as a C string (e.g., "[\"spotify:track:xxx\", \"spotify:track:yyy\"]")
#[no_mangle]
pub extern "C" fn spotifly_play_tracks(track_uris_json: *const c_char) -> i32 {
    debug_println!("[Spotifly] spotifly_play_tracks called");
    if track_uris_json.is_null() {
        debug_println!("Play tracks error: track_uris_json is null");
        return -1;
    }

    let track_uris_str = unsafe {
        match CStr::from_ptr(track_uris_json).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug_println!("Play tracks error: invalid track_uris_json string");
                return -1;
            }
        }
    };

    // Parse JSON array of track URIs
    let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
        Ok(uris) => uris,
        Err(_e) => {
            debug_println!("Play tracks error: failed to parse JSON: {:?}", e);
            return -1;
        }
    };

    if track_uris.is_empty() {
        debug_println!("Play tracks error: empty track URIs array");
        return -1;
    }

    // Use Spirc.load() for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            let load_request = LoadRequest::from_tracks(
                track_uris,
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => {
                    debug_println!("[Spotifly] Spirc.load(tracks) succeeded");
                    0
                }
                Err(_e) => {
                    debug_println!("Play tracks error: Spirc.load() failed: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Play tracks error: Spirc not initialized");
            -1
        }
    }
}

/// Plays content by its Spotify URI or URL.
/// Supports tracks, albums, playlists, and artists.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_uri(uri_or_url: *const c_char) -> i32 {
    if uri_or_url.is_null() {
        debug_println!("Play error: uri_or_url is null");
        return -1;
    }

    let input_str = unsafe {
        match CStr::from_ptr(uri_or_url).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug_println!("Play error: invalid uri_or_url string");
                return -1;
            }
        }
    };

    // Convert URL to URI if needed
    let uri_str = url_to_uri(&input_str);
    debug_println!("[Spotifly] spotifly_play_uri called: {}", uri_str);

    // Use Spirc.load() with LoadRequest for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Create LoadRequest - use from_context_uri for albums/playlists/artists,
            // from_tracks for single tracks
            let load_request = if uri_str.starts_with("spotify:track:") {
                debug_println!("[Spotifly] Spirc.load(LoadRequest::from_tracks([{}]))", uri_str);
                LoadRequest::from_tracks(
                    vec![uri_str.clone()],
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        ..Default::default()
                    },
                )
            } else {
                debug_println!("[Spotifly] Spirc.load(LoadRequest::from_context_uri({}))", uri_str);
                LoadRequest::from_context_uri(
                    uri_str.clone(),
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        ..Default::default()
                    },
                )
            };

            match spirc.load(load_request) {
                Ok(_) => {
                    debug_println!("[Spotifly] Spirc.load() succeeded");
                    IS_PLAYING.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug_println!("Play error: Spirc.load() failed: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Play error: Spirc not initialized");
            -1
        }
    }
}

/// Pauses playback.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_pause() -> i32 {
    debug_println!("[Spotifly] spotifly_pause called");
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.pause() {
                Ok(_) => {
                    IS_PLAYING.store(false, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug_println!("Pause error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Pause error: Spirc not initialized");
            -1
        }
    }
}

/// Resumes playback.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_resume() -> i32 {
    debug_println!("[Spotifly] spotifly_resume called");
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.play() {
                Ok(_) => {
                    IS_PLAYING.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug_println!("Resume error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Resume error: Spirc not initialized");
            -1
        }
    }
}

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_stop() -> i32 {
    debug_println!("[Spotifly] spotifly_stop called");
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.stop();
            IS_PLAYING.store(false, Ordering::SeqCst);
            0
        }
        None => {
            debug_println!("Stop error: player not initialized");
            -1
        }
    }
}

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_shutdown() -> i32 {
    debug_println!("[Spotifly] spotifly_shutdown called");
    let spirc_guard = SPIRC.lock().unwrap();
    if let Some(spirc) = spirc_guard.as_ref() {
        if spirc.shutdown().is_ok() {
            return 0;
        }
    }
    -1
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_playing() -> i32 {
    if IS_PLAYING.load(Ordering::SeqCst) { 1 } else { 0 }
}

/// Returns the current playback position in milliseconds.
/// If playing, interpolates from last known position.
/// Returns 0 if not playing or no position available.
#[no_mangle]
pub extern "C" fn spotifly_get_position_ms() -> u32 {
    let stored_position = POSITION_MS.load(Ordering::SeqCst);
    let stored_timestamp = POSITION_TIMESTAMP_MS.load(Ordering::SeqCst);

    if stored_timestamp == 0 {
        return 0;
    }

    // If playing, interpolate position from last update
    if IS_PLAYING.load(Ordering::SeqCst) {
        let now = current_timestamp_ms();
        let elapsed_since_update = now.saturating_sub(stored_timestamp);
        // Cap interpolation at 5 seconds - librespot events can be delayed
        // but if we haven't heard anything in 5s, something is wrong
        let capped_elapsed = elapsed_since_update.min(5000) as u32;
        stored_position.saturating_add(capped_elapsed)
    } else {
        stored_position
    }
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error or if at end of queue.
#[no_mangle]
pub extern "C" fn spotifly_next() -> i32 {
    debug_println!("[Spotifly] spotifly_next called");
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.next() {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Next error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Next error: Spirc not initialized");
            -1
        }
    }
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error or if at start of queue.
#[no_mangle]
pub extern "C" fn spotifly_previous() -> i32 {
    debug_println!("[Spotifly] spotifly_previous called");
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.prev() {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Previous error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Previous error: Spirc not initialized");
            -1
        }
    }
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_seek(position_ms: u32) -> i32 {
    debug_println!("[Spotifly] spotifly_seek called: {}ms", position_ms);
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.set_position_ms(position_ms) {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Seek error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Seek error: Spirc not initialized");
            -1
        }
    }
}

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_radio(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        debug_println!("Play radio error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug_println!("Play radio error: invalid track_uri string");
                return -1;
            }
        }
    };

    debug_println!("[Spotifly] spotifly_play_radio called: {}", uri_str);

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug_println!("Play radio error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    // Get the radio playlist URI
    let playlist_uri: Result<String, String> = RUNTIME.block_on(async {
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        let response = session.spclient().get_radio_for_track(&spotify_uri).await
            .map_err(|e| format!("Failed to get radio: {:?}", e))?;

        let json: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| format!("Failed to parse radio response: {:?}", e))?;

        // The API returns a playlist URI in mediaItems
        // Format: { "mediaItems": [{ "uri": "spotify:playlist:xxx" }] }
        json.get("mediaItems")
            .and_then(|items| items.as_array())
            .and_then(|items| items.first())
            .and_then(|item| item.get("uri"))
            .and_then(|u| u.as_str())
            .filter(|uri| uri.starts_with("spotify:playlist:"))
            .map(|s| s.to_string())
            .ok_or_else(|| "No radio playlist found in response".to_string())
    });

    let playlist_uri = match playlist_uri {
        Ok(uri) => uri,
        Err(_e) => {
            debug_println!("Play radio error: {}", e);
            return -1;
        }
    };

    debug_println!("[Spotifly] Loading radio playlist: {}", playlist_uri);

    // Load the radio playlist via Spirc
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            let load_request = LoadRequest::from_context_uri(
                playlist_uri,
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Play radio error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Play radio error: Spirc not initialized");
            -1
        }
    }
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_set_volume(volume: u16) -> i32 {
    debug_println!("[Spotifly] spotifly_set_volume called: {}", volume);
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            match spirc.set_volume(volume) {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Set volume error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Set volume error: Spirc not initialized");
            -1
        }
    }
}

/// Sets the streaming bitrate.
/// 0 = 96 kbps, 1 = 160 kbps (default), 2 = 320 kbps
/// Note: Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn spotifly_set_bitrate(bitrate: u8) {
    let value = bitrate.min(2); // Clamp to valid range
    let old_value = BITRATE_SETTING.swap(value, Ordering::SeqCst);
    if old_value != value {
        let _kbps = match value { 0 => 96, 2 => 320, _ => 160 };
        debug_println!("[Spotifly] Bitrate changed to {}kbps (restart playback to apply)", _kbps);
    }
}

/// Gets the current bitrate setting.
/// 0 = 96 kbps, 1 = 160 kbps, 2 = 320 kbps
#[no_mangle]
pub extern "C" fn spotifly_get_bitrate() -> u8 {
    BITRATE_SETTING.load(Ordering::SeqCst)
}

/// Sets gapless playback (true = enabled, false = disabled).
/// Enabled by default. Takes effect on next player initialization (restart playback to apply).
#[no_mangle]
pub extern "C" fn spotifly_set_gapless(enabled: bool) {
    let old_value = GAPLESS_SETTING.swap(enabled, Ordering::SeqCst);
    if old_value != enabled {
        debug_println!("[Spotifly] Gapless playback changed to {} (restart playback to apply)", enabled);
    }
}

/// Gets the current gapless playback setting.
#[no_mangle]
pub extern "C" fn spotifly_get_gapless() -> bool {
    GAPLESS_SETTING.load(Ordering::SeqCst)
}

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_transfer_to_local() -> i32 {
    debug_println!("[Spotifly] spotifly_transfer_to_local called");
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Pass None to transfer from whatever device is currently playing
            match spirc.transfer(None) {
                Ok(_) => 0,
                Err(_e) => {
                    debug_println!("Transfer error: {:?}", e);
                    -1
                }
            }
        }
        None => {
            debug_println!("Transfer error: Spirc not initialized");
            -1
        }
    }
}

/// Transfers playback from this local player to another device.
/// Uses the native Spotify Connect protocol via SpClient.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - to_device_id: The target device ID to transfer playback to
#[no_mangle]
pub extern "C" fn spotifly_transfer_playback(to_device_id: *const c_char) -> i32 {
    if to_device_id.is_null() {
        debug_println!("Transfer playback error: to_device_id is null");
        return -1;
    }

    let to_device_str = unsafe {
        match CStr::from_ptr(to_device_id).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug_println!("Transfer playback error: invalid to_device_id string");
                return -1;
            }
        }
    };

    debug_println!("[Spotifly] spotifly_transfer_playback called: {}", to_device_str);

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug_println!("Transfer playback error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let device_id_guard = DEVICE_ID.lock().unwrap();
    let from_device_id = match device_id_guard.as_ref() {
        Some(id) => id.clone(),
        None => {
            debug_println!("Transfer playback error: device ID not initialized");
            return -1;
        }
    };
    drop(device_id_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        session.spclient()
            .transfer(&from_device_id, &to_device_str, None)
            .await
            .map_err(|e| format!("Transfer failed: {:?}", e))?;
        Ok(())
    });

    match result {
        Ok(_) => {
            // Pause local playback after successful transfer
            let player_guard = PLAYER.lock().unwrap();
            if let Some(player) = player_guard.as_ref() {
                player.pause();
            }
            IS_PLAYING.store(false, Ordering::SeqCst);
            IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
            0
        }
        Err(_e) => {
            debug_println!("Transfer playback error: {}", e);
            -1
        }
    }
}

/// Returns 1 if Spirc is initialized and connected to Spotify Connect, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_spirc_ready() -> i32 {
    if SPIRC_READY.load(Ordering::SeqCst) { 1 } else { 0 }
}
