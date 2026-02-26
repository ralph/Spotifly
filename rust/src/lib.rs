mod proxy_sink;

use futures_util::StreamExt;
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
use librespot_core::SessionConfig;
use librespot_core::SpotifyUri;
use librespot_core::cache::Cache;
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use librespot_protocol::connect::ClusterUpdate;
use librespot_protocol::player::PlayerState;
use log::debug;
use once_cell::sync::Lazy;
use proxy_sink::mk_proxy_sink;
use serde::Serialize;
use std::ffi::{CStr, CString, c_char};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU16, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::runtime::Runtime;
use tokio::sync::mpsc;

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
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static PLAYBACK_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static STATE_UPDATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> = Lazy::new(|| Mutex::new(None));
static VOLUME_CALLBACK: Lazy<Mutex<Option<extern "C" fn(u16)>>> = Lazy::new(|| Mutex::new(None));
static LOADING_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CHANGED_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_DISCONNECTED_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_CONNECTED_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_CLIENT_CHANGED_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static SET_QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static LAST_VOLUME: AtomicU16 = AtomicU16::new(0);

// Token request callback - Rust requests fresh token from Swift for reconnection
static TOKEN_REQUEST_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
// Channel for receiving token from Swift (set via spotifly_set_token)
static PENDING_TOKEN: Lazy<Mutex<Option<tokio::sync::oneshot::Sender<String>>>> =
    Lazy::new(|| Mutex::new(None));
// Flag to track if reconnection is in progress
static RECONNECTING: AtomicBool = AtomicBool::new(false);
// Flag to track intentional shutdown (prevents reconnection attempts during app quit)
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
// Flag to track sleep state (prevents auto-reconnect, but allows explicit forceReconnect on wake)
static SLEEPING: AtomicBool = AtomicBool::new(false);

// Auto-resume after reconnection: if non-zero, resume playback when Paused event arrives before this timestamp
// This handles the case where we were playing before a network disconnect, reconnected, but track loaded paused
static RESUME_AFTER_RECONNECT_UNTIL_MS: AtomicU64 = AtomicU64::new(0);

// Session state tracking - guards playback commands until session is ready
struct SessionConnectionState {
    connection_id: Option<String>,
    is_connected: bool,
}

impl Default for SessionConnectionState {
    fn default() -> Self {
        Self {
            connection_id: None,
            is_connected: false,
        }
    }
}

static SESSION_CONNECTION_STATE: Lazy<Mutex<SessionConnectionState>> =
    Lazy::new(|| Mutex::new(SessionConnectionState::default()));

// Position tracking - updated from player events
static POSITION_MS: AtomicU32 = AtomicU32::new(0);
static POSITION_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

// Current track duration (ms) - updated from TrackChanged event
static CURRENT_DURATION_MS: AtomicU32 = AtomicU32::new(0);

// Current track URI - for detecting same-track reconnects
static CURRENT_TRACK_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// Connection state tracking - for transparency dashboard
static RECONNECT_ATTEMPT: AtomicU32 = AtomicU32::new(0);
static CONNECTED_SINCE_MS: AtomicU64 = AtomicU64::new(0);
static LAST_ERROR: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));
static CONNECTION_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));

// Wake timing tracking - for debugging reconnection timing issues
static WAKE_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

/// Returns milliseconds elapsed since wake was triggered (force_reconnect called).
/// Returns 0 if no wake timestamp recorded.
fn elapsed_since_wake_ms() -> u64 {
    let wake_ts = WAKE_TIMESTAMP_MS.load(Ordering::SeqCst);
    if wake_ts == 0 {
        return 0;
    }
    let now = current_timestamp_ms();
    now.saturating_sub(wake_ts)
}

// Generation counter for reconnection - prevents old cluster listeners from triggering reconnects
// Incremented each time a new session is created (in spawn_reconnection_loop or init_player)
static SESSION_GENERATION: AtomicU64 = AtomicU64::new(0);

// The generation that the current event listener belongs to. Updated on soft reconnect
// so the existing event listener accepts SessionDisconnected events from the new session.
// On hard reconnect, a new event listener is created that captures SESSION_GENERATION directly.
static EVENT_LISTENER_GENERATION: AtomicU64 = AtomicU64::new(0);

// Playback settings (applied on player init)
// Bitrate: 0 = 96kbps, 1 = 160kbps (default), 2 = 320kbps
static BITRATE_SETTING: AtomicU8 = AtomicU8::new(1);
// Gapless playback: true by default (matches librespot default)
static GAPLESS_SETTING: AtomicBool = AtomicBool::new(true);
// Initial volume (0-65535), default 50%
static INITIAL_VOLUME_SETTING: AtomicU16 = AtomicU16::new(65535 / 2);

#[derive(Serialize)]
struct QueueItem {
    uri: String,
    name: String,
    artist: String,
    image_url: String,
    duration_ms: u32,
    album_name: String,
    /// Track provider: "context", "queue", "autoplay", or "unavailable"
    provider: String,
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
    /// Timestamp (ms since epoch) when position_ms was recorded - for computing current position
    timestamp_ms: i64,
}

#[derive(Serialize)]
struct LoadingNotification {
    track_uri: String,
    position_ms: u32,
}

#[derive(Serialize)]
struct SetQueueNotification {
    context_uri: String,
    current_track: Option<QueueTrackInfo>,
    next_tracks: Vec<QueueTrackInfo>,
    prev_tracks: Vec<QueueTrackInfo>,
}

#[derive(Serialize)]
struct QueueTrackInfo {
    uri: String,
    provider: String,
}

#[derive(Serialize)]
struct ConnectionStateInfo {
    session_connected: bool,
    session_connection_id: Option<String>,
    spirc_ready: bool,
    device_id: Option<String>,
    device_name: String,
    reconnect_attempt: u32,
    last_error: Option<String>,
    connected_since_ms: Option<u64>,
}

#[derive(Serialize)]
struct SessionClientInfo {
    client_id: String,
    client_name: String,
    client_brand_name: String,
    client_model_name: String,
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
            let filtered: Vec<&str> = parts
                .iter()
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
    SpotifyUri::from_uri(uri_str).map_err(|e| format!("Invalid Spotify URI: {:?}", e))
}

/// Shuts down the Spirc instance if it exists.
/// This terminates the spirc_task and closes the dealer connection.
fn shutdown_spirc(context: &str) {
    let spirc_guard = SPIRC.lock().unwrap();
    if let Some(spirc) = spirc_guard.as_ref() {
        if let Err(e) = spirc.shutdown() {
            debug!("{}: spirc.shutdown() failed: {:?}", context, e);
        } else {
            debug!("{}: spirc.shutdown() succeeded", context);
        }
    }
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
pub extern "C" fn spotifly_register_playback_state_callback(
    callback: extern "C" fn(*const c_char),
) {
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

/// Registers a callback to receive volume change notifications.
/// Called when the volume is changed remotely (e.g., from another Spotify Connect device).
/// The callback receives the new volume (0-65535).
#[no_mangle]
pub extern "C" fn spotifly_register_volume_callback(callback: extern "C" fn(u16)) {
    let mut cb = VOLUME_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive loading notifications.
/// Called when a new track starts loading (before metadata is fetched).
/// This fires earlier than TrackChanged (~180ms vs ~620ms after command).
/// The callback receives JSON with track_uri and position_ms.
#[no_mangle]
pub extern "C" fn spotifly_register_loading_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = LOADING_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive queue change notifications.
/// Called when a remote device adds a track to the queue.
/// The callback receives JSON with track_uri.
#[no_mangle]
pub extern "C" fn spotifly_register_queue_changed_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = QUEUE_CHANGED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive session disconnection notifications.
/// Called when the Spotify session is disconnected (e.g., idle timeout).
/// When this fires, you should reinitialize the player with a fresh token.
#[no_mangle]
pub extern "C" fn spotifly_register_session_disconnected_callback(callback: extern "C" fn()) {
    let mut cb = SESSION_DISCONNECTED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive session connection notifications.
/// Called when the Spotify session is fully connected and ready for commands.
/// Wait for this callback before attempting playback operations after init/reinit.
#[no_mangle]
pub extern "C" fn spotifly_register_session_connected_callback(callback: extern "C" fn()) {
    let mut cb = SESSION_CONNECTED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive session client changed notifications.
#[unsafe(no_mangle)]
pub extern "C" fn spotifly_register_session_client_changed_callback(
    callback: extern "C" fn(*const c_char),
) {
    let mut cb = SESSION_CLIENT_CHANGED_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive set queue notifications.
/// Called when the queue is set/modified (via set_queue command from mobile app).
/// The callback receives JSON with next_tracks and prev_tracks arrays containing uri and provider.
#[no_mangle]
pub extern "C" fn spotifly_register_set_queue_callback(callback: extern "C" fn(*const c_char)) {
    let mut cb = SET_QUEUE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback for token requests during reconnection.
/// When Rust needs a fresh token to reconnect, it calls this callback.
/// Swift should respond by calling spotifly_set_token() with a fresh access token.
#[no_mangle]
pub extern "C" fn spotifly_register_token_request_callback(callback: extern "C" fn()) {
    let mut cb = TOKEN_REQUEST_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Provides a fresh access token for reconnection.
/// Called by Swift in response to the token request callback.
/// The token is passed to the pending reconnection attempt.
#[no_mangle]
pub extern "C" fn spotifly_set_token(token: *const c_char) {
    if token.is_null() {
        debug!("spotifly_set_token: token is null");
        return;
    }

    let token_str = unsafe {
        match CStr::from_ptr(token).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("spotifly_set_token: invalid token string");
                return;
            }
        }
    };

    debug!(
        "spotifly_set_token: received token ({} chars)",
        token_str.len()
    );

    // Send token to waiting reconnection task
    let mut pending = PENDING_TOKEN.lock().unwrap();
    if let Some(sender) = pending.take() {
        if sender.send(token_str).is_err() {
            debug!("spotifly_set_token: receiver dropped");
        }
    } else {
        debug!("spotifly_set_token: no pending token request");
    }
}

/// Registers a callback to receive connection state change notifications.
/// Called whenever the connection state changes (connect, disconnect, error, etc.).
/// The callback receives JSON with full connection state.
#[no_mangle]
pub extern "C" fn spotifly_register_connection_state_callback(
    callback: extern "C" fn(*const c_char),
) {
    let mut cb = CONNECTION_STATE_CALLBACK.lock().unwrap();
    *cb = Some(callback);
}

/// Registers a callback to receive raw PCM audio data (f32, 44100Hz, stereo interleaved).
/// Called from librespot's player thread for each decoded audio chunk.
/// The callback receives a pointer to f32 samples and the number of f32 values.
#[no_mangle]
pub extern "C" fn spotifly_register_audio_data_callback(
    callback: extern "C" fn(*const f32, usize),
) {
    proxy_sink::register_audio_data_callback(callback);
}

/// Registers a callback for audio control events (start/stop/clear).
/// Called from librespot's player thread.
/// Events: 0 = stop, 1 = start/resume, 2 = clear/flush
#[no_mangle]
pub extern "C" fn spotifly_register_audio_control_callback(callback: extern "C" fn(u8)) {
    proxy_sink::register_audio_control_callback(callback);
}

/// Returns the current connection state as a JSON string.
/// Caller must free the returned string using spotifly_free_string().
#[no_mangle]
pub extern "C" fn spotifly_get_connection_state() -> *mut c_char {
    let state = build_connection_state_info();
    match serde_json::to_string(&state) {
        Ok(json) => CString::new(json).unwrap().into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Builds the current connection state info struct
fn build_connection_state_info() -> ConnectionStateInfo {
    let session_state = SESSION_CONNECTION_STATE.lock().unwrap();
    let device_id = DEVICE_ID.lock().unwrap().clone();
    let last_error = LAST_ERROR.lock().unwrap().clone();
    let connected_since = CONNECTED_SINCE_MS.load(Ordering::SeqCst);

    ConnectionStateInfo {
        session_connected: session_state.is_connected,
        session_connection_id: session_state.connection_id.clone(),
        spirc_ready: SPIRC_READY.load(Ordering::SeqCst),
        device_id,
        device_name: "Spotifly".to_string(),
        reconnect_attempt: RECONNECT_ATTEMPT.load(Ordering::SeqCst),
        last_error,
        connected_since_ms: if connected_since > 0 {
            Some(connected_since)
        } else {
            None
        },
    }
}

/// Marks the session as disconnected, records the reason, and notifies the UI.
fn mark_disconnected(reason: &str) {
    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }
    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
    {
        let mut last_error = LAST_ERROR.lock().unwrap();
        *last_error = Some(reason.to_string());
    }
    notify_connection_state_change();
}

/// Sends connection state update to the registered callback
fn notify_connection_state_change() {
    let cb_guard = CONNECTION_STATE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);

        let state = build_connection_state_info();
        if let Ok(json) = serde_json::to_string(&state) {
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
        }
    }
}

/// Creates a new (unconnected) Session with the given device ID and access token.
fn create_session(device_id: &str, access_token: &str) -> Result<(Session, librespot_core::authentication::Credentials), String> {
    let session_config = SessionConfig {
        device_id: device_id.to_string(),
        ..Default::default()
    };
    let credentials =
        librespot_core::authentication::Credentials::with_access_token(access_token);
    let cache = Cache::new(None::<std::path::PathBuf>, None, None, None)
        .map_err(|e| format!("Cache error: {}", e))?;
    let session = Session::new(session_config, Some(cache));
    Ok((session, credentials))
}

/// Creates the standard ConnectConfig for Spirc.
fn create_connect_config() -> ConnectConfig {
    let initial_volume = INITIAL_VOLUME_SETTING.load(Ordering::SeqCst);
    ConnectConfig {
        name: "Spotifly".to_string(),
        device_type: DeviceType::Computer,
        initial_volume,
        emit_set_queue_events: true,
        ..Default::default()
    }
}

/// Creates Spirc, spawns its background task, and stores it globally.
/// Returns the Spirc Arc for activation by the caller.
async fn create_and_store_spirc(
    session: &Session,
    credentials: &librespot_core::authentication::Credentials,
    player: Arc<Player>,
    mixer: Arc<SoftMixer>,
) -> Result<Arc<Spirc>, String> {
    let connect_config = create_connect_config();

    let (spirc, spirc_task) = Spirc::new(
        connect_config,
        session.clone(),
        credentials.clone(),
        player,
        mixer as Arc<dyn Mixer>,
    )
    .await
    .map_err(|e| format!("Spirc init failed: {:?}", e))?;

    let spirc_arc = Arc::new(spirc);
    RUNTIME.spawn(spirc_task);

    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = Some(spirc_arc.clone());
    }
    SPIRC_READY.store(true, Ordering::SeqCst);

    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = true;
    }

    debug!(
        "[WAKE +{}ms] Spirc ready - connected to Spotify Connect",
        elapsed_since_wake_ms()
    );

    // Small delay to let librespot's initial cluster processing complete
    tokio::time::sleep(Duration::from_millis(200)).await;

    Ok(spirc_arc)
}

/// Subscribes to cluster updates on the session's dealer and spawns a task
/// to process them. When the stream ends (Spirc died), triggers reconnection
/// unless shutting down or sleeping.
fn spawn_cluster_listener(session: &Session, generation: u64) -> Result<(), String> {
    let queue_stream = session
        .dealer()
        .listen_for(
            "hm://connect-state/v1/cluster",
            librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>,
        )
        .map_err(|e| format!("Failed to subscribe to cluster updates: {}", e))?;

    RUNTIME.spawn(async move {
        debug!(
            "Cluster listener started (generation={})",
            generation
        );
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            match msg_result {
                Ok(cluster_update) => {
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        if let Some(player_state) = cluster.player_state.into_option() {
                            send_playback_state(&player_state);
                            process_and_send_queue(player_state);
                        }
                    }
                }
                Err(e) => {
                    debug!("Failed to parse cluster update: {:?}", e);
                }
            }
        }

        debug!(
            "Cluster listener ended (generation={})",
            generation
        );

        let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
        if generation != current_gen {
            debug!(
                "Cluster listener from old generation {} ended (current={}), ignoring",
                generation, current_gen
            );
            return;
        }

        if SHUTTING_DOWN.load(Ordering::SeqCst) || SLEEPING.load(Ordering::SeqCst) {
            return;
        }

        mark_disconnected("Cluster listener ended unexpectedly");
        spawn_reconnection_loop();
    });

    Ok(())
}

/// Request a fresh token from Swift via callback
fn request_token_from_swift() {
    let cb_guard = TOKEN_REQUEST_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);
        debug!("Requesting fresh token from Swift");
        cb();
    } else {
        debug!("No token request callback registered");
    }
}

/// Spawns the reconnection loop task.
/// Uses exponential backoff and requests fresh tokens from Swift.
fn spawn_reconnection_loop() {
    // Check if already reconnecting
    if RECONNECTING.swap(true, Ordering::SeqCst) {
        debug!(
            "[WAKE +{}ms] Reconnection already in progress, skipping",
            elapsed_since_wake_ms()
        );
        return;
    }

    debug!(
        "[WAKE +{}ms] spawn_reconnection_loop started",
        elapsed_since_wake_ms()
    );

    RUNTIME.spawn(async {
        let was_playing = IS_PLAYING.load(Ordering::SeqCst);

        let delays = [0u64, 2, 5, 10, 30, 30, 30, 30, 30, 30];

        for (attempt, delay) in delays.iter().enumerate() {
            if *delay > 0 {
                tokio::time::sleep(Duration::from_secs(*delay)).await;
            }

            debug!("[WAKE +{}ms] Reconnect attempt {}", elapsed_since_wake_ms(), attempt + 1);
            RECONNECT_ATTEMPT.store(attempt as u32 + 1, Ordering::SeqCst);
            {
                let mut last_error = LAST_ERROR.lock().unwrap();
                *last_error = Some(format!("Reconnecting (attempt {})", attempt + 1));
            }
            notify_connection_state_change();

            let (tx, rx) = tokio::sync::oneshot::channel::<String>();
            {
                let mut pending = PENDING_TOKEN.lock().unwrap();
                *pending = Some(tx);
            }
            request_token_from_swift();

            let token_result = tokio::time::timeout(Duration::from_secs(10), rx).await;

            let token = match token_result {
                Ok(Ok(t)) => t,
                Ok(Err(_)) => {
                    debug!("[WAKE +{}ms] Token channel closed", elapsed_since_wake_ms());
                    continue;
                }
                Err(_) => {
                    debug!("[WAKE +{}ms] Token request timed out", elapsed_since_wake_ms());
                    continue;
                }
            };

            // Try soft reconnect first (keeps Player alive), fall back to hard
            if PLAYER.lock().unwrap().is_some() {
                do_soft_reconnect_cleanup();

                match soft_reconnect_async(&token).await {
                    Ok(_) => {
                        debug!("[WAKE +{}ms] Soft reconnect successful on attempt {}", elapsed_since_wake_ms(), attempt + 1);
                        RECONNECTING.store(false, Ordering::SeqCst);
                        // No auto-resume needed — the Player is still playing
                        return;
                    }
                    Err(e) => {
                        debug!("[WAKE +{}ms] Soft reconnect failed: {}, falling back to hard reconnect", elapsed_since_wake_ms(), e);
                    }
                }
            }

            // Hard reconnect: full cleanup and rebuild
            do_reconnect_cleanup();

            match init_player_async(&token).await {
                Ok(_) => {
                    debug!("[WAKE +{}ms] Hard reconnect successful on attempt {}", elapsed_since_wake_ms(), attempt + 1);
                    RECONNECTING.store(false, Ordering::SeqCst);

                    // Auto-resume: the track will load paused via transfer(None).
                    // When we receive the Paused event, we'll auto-resume if within this window.
                    if was_playing {
                        let resume_until = current_timestamp_ms() + 5000; // 5 second window
                        RESUME_AFTER_RECONNECT_UNTIL_MS.store(resume_until, Ordering::SeqCst);
                        debug!("[WAKE +{}ms] Will auto-resume after track loads (was playing before disconnect)", elapsed_since_wake_ms());
                    }

                    return;
                }
                Err(e) => {
                    debug!("[WAKE +{}ms] Hard reconnect attempt {} failed: {}", elapsed_since_wake_ms(), attempt + 1, e);
                    {
                        let mut last_error = LAST_ERROR.lock().unwrap();
                        *last_error = Some(format!("Reconnect failed: {}", e));
                    }
                    notify_connection_state_change();
                }
            }
        }

        // All attempts exhausted
        debug!("All reconnection attempts exhausted");
        RECONNECTING.store(false, Ordering::SeqCst);
        {
            let mut last_error = LAST_ERROR.lock().unwrap();
            *last_error = Some("Reconnection failed after 10 attempts".to_string());
        }
        notify_connection_state_change();

        // Notify Swift that reconnection failed - it may want to show UI
        let cb_guard = SESSION_DISCONNECTED_CALLBACK.lock().unwrap();
        if let Some(callback) = *cb_guard {
            let cb = callback;
            drop(cb_guard);
            debug!("Notifying Swift of reconnection failure");
            cb();
        }
    });
}

/// Forces a reconnection to Spotify servers.
/// Use this after system wake to ensure a fresh connection.
/// Returns:
/// - 0: Reconnection triggered
/// - 1: Reconnection already in progress
/// - 2: No session initialized (nothing to reconnect)
#[no_mangle]
pub extern "C" fn spotifly_force_reconnect() -> i32 {
    // Clear sleeping flag - we're explicitly waking up
    SLEEPING.store(false, Ordering::SeqCst);

    // Record wake timestamp for timing analysis
    let wake_ts = current_timestamp_ms();
    WAKE_TIMESTAMP_MS.store(wake_ts, Ordering::SeqCst);
    debug!("[WAKE +0ms] spotifly_force_reconnect called at {}", wake_ts);

    // Check if we even have a session
    let has_session = {
        let session_guard = SESSION.lock().unwrap();
        session_guard.is_some()
    };

    if !has_session {
        debug!(
            "[WAKE +{}ms] Force reconnect: no session initialized",
            elapsed_since_wake_ms()
        );
        return 2;
    }

    // Check if already reconnecting
    if RECONNECTING.load(Ordering::SeqCst) {
        debug!(
            "[WAKE +{}ms] Force reconnect: reconnection already in progress",
            elapsed_since_wake_ms()
        );
        return 1;
    }

    debug!(
        "[WAKE +{}ms] Force reconnect: triggering reconnection",
        elapsed_since_wake_ms()
    );

    mark_disconnected("Reconnecting after system wake");
    spawn_reconnection_loop();

    0
}

/// Performs full cleanup for reconnection.
/// Clears Session, Spirc, Player, and Mixer because Player is tightly coupled
/// to the Session's ChannelManager for decryption key requests.
fn do_reconnect_cleanup() {
    debug!("do_reconnect_cleanup: full cleanup for reconnection");

    // Signal event listener to stop
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        if let Some(tx) = tx_guard.take() {
            let _ = tx.send(());
        }
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer,
    // which will cause the cluster listener stream to end. Without this, old tasks
    // remain alive holding references to Session/Player until the server closes the connection.
    shutdown_spirc("do_reconnect_cleanup");

    // Now clear Spirc reference
    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = None;
    }
    SPIRC_READY.store(false, Ordering::SeqCst);

    // Clear Player - must be recreated with new Session
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = None;
    }

    // Clear Mixer
    {
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = None;
    }

    // Clear Session
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    // Clear device ID (will be regenerated)
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = None;
    }

    // Reset session connection state
    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }

    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);

    debug!("do_reconnect_cleanup complete");
}

/// Soft reconnect: keeps Player, Mixer, and event listener alive.
/// Only shuts down Spirc/Session and creates new ones. The Player continues
/// playing uninterrupted because it doesn't need the Session for an
/// already-loaded track.
fn do_soft_reconnect_cleanup() {
    debug!("do_soft_reconnect_cleanup: keeping Player/Mixer alive");

    shutdown_spirc("do_soft_reconnect_cleanup");

    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = None;
    }
    SPIRC_READY.store(false, Ordering::SeqCst);

    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }
    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
}

/// Soft reconnect: creates new Session + Spirc while keeping the existing
/// Player and Mixer alive. Audio continues playing during reconnection.
async fn soft_reconnect_async(access_token: &str) -> Result<(), String> {
    let current_generation = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    EVENT_LISTENER_GENERATION.store(current_generation, Ordering::SeqCst);
    debug!(
        "[WAKE +{}ms] soft_reconnect_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = {
        let guard = DEVICE_ID.lock().unwrap();
        guard
            .clone()
            .unwrap_or_else(|| format!("spotifly_{}", std::process::id()))
    };

    let (session, credentials) = create_session(&device_id, access_token)?;

    let player = PLAYER
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "Player not available for soft reconnect".to_string())?;
    let mixer = MIXER
        .lock()
        .unwrap()
        .clone()
        .ok_or_else(|| "Mixer not available for soft reconnect".to_string())?;

    // Swap the session on the existing Player so future track loads use it
    player.set_session(session.clone());

    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = Some(session.clone());
    }

    spawn_cluster_listener(&session, current_generation)?;
    let spirc = create_and_store_spirc(&session, &credentials, player, mixer).await?;

    // Use activate() instead of transfer(None) -- the Player is already
    // playing the correct track so we just need to re-register as active.
    match spirc.activate() {
        Ok(_) => IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst),
        Err(e) => debug!("Soft reconnect: activate failed: {:?}", e),
    }

    notify_connection_state_change();
    Ok(())
}

/// Initializes the player with the given access token.
/// Must be called before play/pause operations.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_init_player(access_token: *const c_char) -> i32 {
    // Initialize env_logger to capture librespot's log output (only once)
    static LOGGER_INIT: std::sync::Once = std::sync::Once::new();
    LOGGER_INIT.call_once(|| {
        env_logger::Builder::from_env(env_logger::Env::default())
            .format_timestamp_millis()
            .init();
    });

    // Print RUST_LOG env var for debugging
    let rust_log = std::env::var("RUST_LOG").unwrap_or_else(|_| "(not set)".to_string());
    debug!("RUST_LOG={}", rust_log);

    // Reset shutdown and sleeping flags in case we're reinitializing
    SHUTTING_DOWN.store(false, Ordering::SeqCst);
    SLEEPING.store(false, Ordering::SeqCst);

    if access_token.is_null() {
        debug!("Player init error: access_token is null");
        return -1;
    }

    let token_str = unsafe {
        match CStr::from_ptr(access_token).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Player init error: invalid access_token string");
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

    let result = RUNTIME.block_on(async { init_player_async(&token_str).await });

    match result {
        Ok(_) => 0,
        Err(_e) => {
            debug!("Player init error: {}", _e);
            -1
        }
    }
}

/// Helper function to create a new Player instance
fn create_new_player(session: &Session, mixer: &Arc<SoftMixer>) -> Result<Arc<Player>, String> {
    let bitrate_setting = BITRATE_SETTING.load(Ordering::SeqCst);
    let bitrate = match bitrate_setting {
        0 => Bitrate::Bitrate96,
        2 => Bitrate::Bitrate320,
        _ => Bitrate::Bitrate160,
    };
    let gapless = GAPLESS_SETTING.load(Ordering::SeqCst);

    let _bitrate_kbps = match bitrate_setting {
        0 => 96,
        2 => 320,
        _ => 160,
    };
    debug!(
        "Player initialized: bitrate={}kbps, gapless={}",
        _bitrate_kbps, gapless
    );

    let player_config = PlayerConfig {
        bitrate,
        gapless,
        position_update_interval: Some(Duration::from_millis(200)),
        ..PlayerConfig::default()
    };
    let audio_format = AudioFormat::default();

    // Use ProxySink - a persistent audio output that survives across Player instances.
    // This enables seamless audio during session reconnection.
    let player = Player::new(
        player_config,
        session.clone(),
        mixer.get_soft_volume(),
        move || mk_proxy_sink(None, audio_format),
    );

    // Store player globally
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = Some(Arc::clone(&player));
    }

    Ok(player)
}

async fn init_player_async(access_token: &str) -> Result<(), String> {
    // Increment session generation - this invalidates any old cluster listeners
    let current_generation = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    debug!(
        "[WAKE +{}ms] init_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = format!("spotifly_{}", std::process::id());
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = Some(device_id.clone());
    }

    let (session, credentials) = create_session(&device_id, access_token)?;

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
    {
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = Some(Arc::clone(&mixer));
    }

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_new_player(&session, &mixer)?;

    // Get event channel from player, opting in to SetQueue events
    let mut event_channel = player.get_player_event_channel();

    // Create channel for stopping event listener
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    // On soft reconnect, EVENT_LISTENER_GENERATION is updated without replacing the listener
    EVENT_LISTENER_GENERATION.store(current_generation, Ordering::SeqCst);
    let player_clone = Arc::clone(&player);
    let event_listener_generation = current_generation;
    RUNTIME.spawn(async move {
        loop {
            tokio::select! {
                _ = rx.recv() => {
                    // Shutdown signal received
                    debug!("Player event listener shutting down (generation={})", event_listener_generation);
                    break;
                }
                event = event_channel.recv() => {
                    match event {
                        Some(PlayerEvent::Playing { position_ms, .. }) => {
                            debug!("PlayerEvent::Playing at {}ms", position_ms);
                            IS_PLAYING.store(true, Ordering::SeqCst);
                            IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                            // Clear auto-resume flag - we're already playing
                            RESUME_AFTER_RECONNECT_UNTIL_MS.store(0, Ordering::SeqCst);
                            update_position(position_ms);
                            // Send playback state update to Swift
                            send_local_playback_state(true, position_ms);
                        }
                        Some(PlayerEvent::Paused { position_ms, .. }) => {
                            debug!("PlayerEvent::Paused at {}ms", position_ms);
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            // Still active when paused - just not playing
                            update_position(position_ms);
                            // Send playback state update to Swift
                            send_local_playback_state(false, position_ms);

                            // Auto-resume after reconnection if we were playing before disconnect
                            let resume_until = RESUME_AFTER_RECONNECT_UNTIL_MS.load(Ordering::SeqCst);
                            if resume_until > 0 && current_timestamp_ms() < resume_until {
                                // Clear the flag first to prevent multiple resume attempts
                                RESUME_AFTER_RECONNECT_UNTIL_MS.store(0, Ordering::SeqCst);
                                debug!("[WAKE +{}ms] Auto-resuming playback after reconnection", elapsed_since_wake_ms());

                                let spirc_guard = SPIRC.lock().unwrap();
                                if let Some(spirc) = spirc_guard.as_ref() {
                                    match spirc.play() {
                                        Ok(_) => {
                                            IS_PLAYING.store(true, Ordering::SeqCst);
                                            debug!("[WAKE +{}ms] Auto-resume succeeded", elapsed_since_wake_ms());
                                        }
                                        Err(e) => {
                                            debug!("[WAKE +{}ms] Auto-resume failed: {:?}", elapsed_since_wake_ms(), e);
                                        }
                                    }
                                }
                            }
                        }
                        Some(PlayerEvent::PositionChanged { position_ms, .. }) => {
                            // Periodic position update (every 200ms)
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Seeked { position_ms, .. }) => {
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::PositionCorrection { position_ms, .. }) => {
                            debug!("[WAKE +{}ms] PositionCorrection event: {}ms", elapsed_since_wake_ms(), position_ms);
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
                        Some(PlayerEvent::TrackChanged { audio_item }) => {
                            // Extract track URI from audio_item (same as Loading event)
                            let track_uri_str = audio_item.track_id.to_string();
                            let duration_ms = audio_item.duration_ms;
                            debug!("TrackChanged event: {} ({}ms) - triggering callbacks", track_uri_str, duration_ms);

                            // Update current track URI and duration
                            {
                                let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap();
                                *uri_guard = Some(track_uri_str.clone());
                            }
                            CURRENT_DURATION_MS.store(duration_ms, Ordering::SeqCst);

                            // Emit Loading callback with track info (position 0 for auto-advance)
                            let cb_guard = LOADING_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let notification = LoadingNotification {
                                    track_uri: track_uri_str,
                                    position_ms: 0,
                                };
                                if let Ok(json) = serde_json::to_string(&notification) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
                            }

                            // Also trigger state update callback
                            let cb_guard = STATE_UPDATE_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                drop(cb_guard);
                                callback();
                            }
                        }
                        Some(PlayerEvent::VolumeChanged { volume }) => {
                            debug!("VolumeChanged event: {}", volume);
                            check_and_send_volume(volume as u32);
                        }
                        Some(PlayerEvent::Loading { track_id, position_ms, .. }) => {
                            let track_uri_str = track_id.to_string();
                            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);

                            // Track current playing URI
                            {
                                let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap();
                                *uri_guard = Some(track_uri_str.clone());
                            }

                            let cb_guard = LOADING_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let notification = LoadingNotification {
                                    track_uri: track_uri_str,
                                    position_ms,
                                };
                                if let Ok(json) = serde_json::to_string(&notification) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
                            }
                        }
                        Some(PlayerEvent::SetQueue {
                            context_uri,
                            current_track,
                            next_tracks,
                            prev_tracks,
                        }) => {
                            debug!(
                                "SetQueue event: context={}, next={}, prev={}",
                                context_uri,
                                next_tracks.len(),
                                prev_tracks.len()
                            );
                            let cb_guard = SET_QUEUE_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let notification = SetQueueNotification {
                                    context_uri,
                                    current_track: current_track.map(|t| QueueTrackInfo {
                                        uri: t.uri,
                                        provider: t.provider,
                                    }),
                                    next_tracks: next_tracks
                                        .into_iter()
                                        .map(|t| QueueTrackInfo {
                                            uri: t.uri,
                                            provider: t.provider,
                                        })
                                        .collect(),
                                    prev_tracks: prev_tracks
                                        .into_iter()
                                        .map(|t| QueueTrackInfo {
                                            uri: t.uri,
                                            provider: t.provider,
                                        })
                                        .collect(),
                                };
                                if let Ok(json) = serde_json::to_string(&notification) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
                            }
                        }
                        Some(PlayerEvent::SessionDisconnected { connection_id, user_name }) => {
                            // Read generation dynamically so soft reconnects can update it
                            // without replacing the event listener
                            let my_gen = EVENT_LISTENER_GENERATION.load(Ordering::SeqCst);
                            debug!("[WAKE +{}ms] SessionDisconnected event: connection_id={}, user={}, listener_generation={}",
                                   elapsed_since_wake_ms(), connection_id, user_name, my_gen);

                            // Check if this event is from a stale session
                            let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
                            if my_gen != current_gen {
                                debug!("[WAKE +{}ms] SessionDisconnected from old generation {} (current={}), ignoring",
                                       elapsed_since_wake_ms(), my_gen, current_gen);
                                continue;
                            }

                            mark_disconnected("Session disconnected");

                            // Spawn reconnection loop if not intentionally sleeping/shutting down
                            if SHUTTING_DOWN.load(Ordering::SeqCst) {
                                debug!("[WAKE +{}ms] SessionDisconnected during shutdown - not reconnecting", elapsed_since_wake_ms());
                            } else if SLEEPING.load(Ordering::SeqCst) {
                                debug!("[WAKE +{}ms] SessionDisconnected during sleep - not reconnecting", elapsed_since_wake_ms());
                            } else {
                                spawn_reconnection_loop();
                            }
                        }
                        Some(PlayerEvent::SessionConnected { connection_id, user_name }) => {
                            debug!("[WAKE +{}ms] SessionConnected event: connection_id={}, user={}", elapsed_since_wake_ms(), connection_id, user_name);
                            // Update session state
                            {
                                let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
                                state.is_connected = true;
                                state.connection_id = Some(connection_id);
                            }
                            // Set connected timestamp and reset reconnect counter
                            CONNECTED_SINCE_MS.store(current_timestamp_ms(), Ordering::SeqCst);
                            RECONNECT_ATTEMPT.store(0, Ordering::SeqCst);
                            // Clear last error on successful connect
                            {
                                let mut last_error = LAST_ERROR.lock().unwrap();
                                *last_error = None;
                            }

                            // Notify connection state change
                            notify_connection_state_change();
                            let cb_guard = SESSION_CONNECTED_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                cb();
                            }
                        }
                        Some(PlayerEvent::SessionClientChanged {
                            client_id,
                            client_name,
                            client_brand_name,
                            client_model_name,
                        }) => {
                            debug!(
                                "SessionClientChanged event: id={}, name={}, brand={}, model={}",
                                client_id, client_name, client_brand_name, client_model_name
                            );
                            let cb_guard = SESSION_CLIENT_CHANGED_CALLBACK.lock().unwrap();
                            if let Some(callback) = *cb_guard {
                                let cb = callback;
                                drop(cb_guard);
                                let info = SessionClientInfo {
                                    client_id,
                                    client_name,
                                    client_brand_name,
                                    client_model_name,
                                };
                                if let Ok(json) = serde_json::to_string(&info) {
                                    let c_str = CString::new(json).unwrap();
                                    cb(c_str.as_ptr());
                                }
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

    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = Some(session.clone());
    }
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        *tx_guard = Some(tx);
    }

    spawn_cluster_listener(&session, current_generation)?;

    match create_and_store_spirc(&session, &credentials, player, mixer).await {
        Ok(spirc) => {
            match spirc.transfer(None) {
                Ok(_) => IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst),
                Err(e) => debug!("Auto-activation via transfer failed: {:?}", e),
            }
            notify_connection_state_change();
        }
        Err(e) => {
            // Spirc failed -- fall back to manual session connection for basic playback
            debug!("{}, falling back to basic playback", e);
            if let Err(connect_err) = session.connect(credentials, true).await {
                return Err(format!("Session connect error: {}", connect_err));
            }
        }
    }

    Ok(())
}

/// Checks if volume changed and sends callback if so
fn check_and_send_volume(volume: u32) {
    let volume_u16 = volume as u16;
    let last = LAST_VOLUME.load(Ordering::SeqCst);

    // Only send callback if volume actually changed
    if volume_u16 != last {
        LAST_VOLUME.store(volume_u16, Ordering::SeqCst);
        debug!("Volume changed: {} -> {}", last, volume_u16);

        let cb_guard = VOLUME_CALLBACK.lock().unwrap();
        if let Some(callback) = *cb_guard {
            drop(cb_guard);
            callback(volume_u16);
        }
    }
}

/// Checks if an error indicates the Spirc channel is closed (needs reinit)
fn is_channel_closed_error(err: &librespot_core::Error) -> bool {
    let err_string = format!("{:?}", err);
    err_string.contains("channel closed")
}

/// Error codes:
/// -1 = general error
/// -2 = channel closed, needs reinit (call spotifly_init_player again)
/// -3 = session not connected, wait for session_connected callback
const ERROR_GENERAL: i32 = -1;
const ERROR_NEEDS_REINIT: i32 = -2;
const ERROR_NOT_CONNECTED: i32 = -3;

/// Returns 1 if the session is connected and ready for commands, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_session_connected() -> i32 {
    let state = SESSION_CONNECTION_STATE.lock().unwrap();
    if state.is_connected { 1 } else { 0 }
}

/// Helper to check if session is connected. Returns ERROR_NOT_CONNECTED if not.
///
/// Also detects zombie sessions: the Session object may have been invalidated
/// (e.g. server closed the connection overnight) without the event listener
/// ever firing SessionDisconnected (because the Spirc task was idle).
/// When detected, updates state and triggers reconnection proactively.
fn require_session_connected() -> Result<(), i32> {
    let state = SESSION_CONNECTION_STATE.lock().unwrap();
    if !state.is_connected {
        debug!("Command rejected: session not connected");
        return Err(ERROR_NOT_CONNECTED);
    }
    drop(state);

    let session_invalid = SESSION
        .lock()
        .unwrap()
        .as_ref()
        .map_or(true, |s| s.is_invalid());

    if session_invalid {
        debug!("Detected zombie session (is_connected=true but Session is invalid)");
        mark_disconnected("Session expired");
        spawn_reconnection_loop();
        return Err(ERROR_NOT_CONNECTED);
    }

    Ok(())
}

fn send_playback_state(player_state: &PlayerState) {
    debug!("send_playback_state called");

    // Log context URI - this is the "active playlist/album/artist" being played from
    let context_uri = &player_state.context_uri;
    if !context_uri.is_empty() {
        debug!("Context URI: {}", context_uri);
    }

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
        let repeat_track = options.map(|o| o.repeating_track).unwrap_or(false);
        let repeat_context = options.map(|o| o.repeating_context).unwrap_or(false);

        let update = PlaybackStateUpdate {
            is_playing: player_state.is_playing,
            is_paused: player_state.is_paused,
            track_uri,
            position_ms: player_state.position_as_of_timestamp,
            duration_ms: player_state.duration,
            shuffle,
            repeat_track,
            repeat_context,
            timestamp_ms: player_state.timestamp,
        };

        debug!(
            "PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, timestamp={}ms, shuffle={}, repeat_track={}, repeat_context={}",
            update.is_playing,
            update.is_paused,
            update.position_ms,
            update.duration_ms,
            update.timestamp_ms,
            update.shuffle,
            update.repeat_track,
            update.repeat_context
        );

        if let Ok(json) = serde_json::to_string(&update) {
            debug!(
                "Sending playback state JSON ({} bytes) to Swift callback",
                json.len()
            );
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug!("Playback state callback returned");
        } else {
            debug!("Failed to serialize playback state to JSON");
        }
    } else {
        debug!("No playback state callback registered, skipping update");
    }
}

/// Send playback state update from local player events (Playing, Paused)
/// This is used when Spotifly is the active device - state changes happen locally
/// and don't come through Mercury cluster updates.
fn send_local_playback_state(is_playing: bool, position_ms: u32) {
    debug!(
        "send_local_playback_state called: is_playing={}, position_ms={}",
        is_playing, position_ms
    );

    let cb_guard = PLAYBACK_STATE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);

        // Get track URI from local state
        let track_uri = CURRENT_TRACK_URI
            .lock()
            .unwrap()
            .clone()
            .unwrap_or_default();

        // Get duration from local state
        let duration_ms = CURRENT_DURATION_MS.load(Ordering::SeqCst);

        let timestamp_ms = current_timestamp_ms() as i64;

        let update = PlaybackStateUpdate {
            is_playing,
            is_paused: !is_playing,
            track_uri,
            position_ms: position_ms as i64,
            duration_ms: duration_ms as i64,
            shuffle: false, // TODO: track shuffle state locally if needed
            repeat_track: false,
            repeat_context: false,
            timestamp_ms,
        };

        debug!(
            "Local PlaybackState: playing={}, paused={}, position={}ms, duration={}ms",
            update.is_playing, update.is_paused, update.position_ms, update.duration_ms
        );

        if let Ok(json) = serde_json::to_string(&update) {
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
        }
    }
}

fn process_and_send_queue(player_state: PlayerState) {
    debug!("process_and_send_queue called");

    // Log context URI for queue processing too
    if !player_state.context_uri.is_empty() {
        debug!("Queue context URI: {}", player_state.context_uri);
    }

    let cb_guard = QUEUE_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        debug!("Callback is registered, processing queue");
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
                provider: t.provider.clone(),
            }
        };

        // Process current track
        let current_track = player_state.track.into_option().and_then(|t| {
            debug!("current track[0] uri='{}' provider='{}'", t.uri, t.provider);
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
                debug!(
                    "next track[{}] uri='{}' provider='{}'",
                    i, t.uri, t.provider
                );
            }

            // Stop at first delimiter - everything after is autoplay content
            if t.uri == "spotify:delimiter" {
                debug!(
                    "Stopping at delimiter (index {}), hiding {} autoplay tracks",
                    i,
                    player_state.next_tracks.len() - i - 1
                );
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
                debug!(
                    "prev track[{}] uri='{}' provider='{}'",
                    i, t.uri, t.provider
                );
            }

            // Stop at delimiter
            if t.uri == "spotify:delimiter" {
                debug!("Stopping prev at delimiter (index {})", i);
                break;
            }

            if t.uri.starts_with("spotify:track:") {
                prev_tracks.push(to_queue_item(t));
            }
        }

        debug!(
            "Queue counts: current={}, next={}, prev={}",
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
            debug!(
                "Sending queue JSON ({} bytes) to Swift callback",
                json.len()
            );
            let c_str = CString::new(json).unwrap();
            cb(c_str.as_ptr());
            debug!("Swift callback returned");
        } else {
            debug!("Failed to serialize queue state to JSON");
        }
    } else {
        debug!("No callback registered, skipping queue update");
    }
}

/// Helper to ensure the device is active before loading content.
/// If not active, transfers playback to this device first (which activates it).
/// Returns Ok(()) if ready to load, Err(i32) with error code if activation failed.
fn ensure_active_for_playback(spirc: &Arc<Spirc>) -> Result<(), i32> {
    if !IS_ACTIVE_DEVICE.load(Ordering::SeqCst) {
        debug!("Device not active, activating via transfer before load");
        match spirc.transfer(None) {
            Ok(_) => {
                debug!("Transfer (activate) succeeded");
            }
            Err(_e) => {
                debug!("Transfer (activate) failed: {:?}", _e);
                return Err(-1);
            }
        }
    }
    Ok(())
}

/// Plays multiple tracks in sequence.
/// Returns 0 on success, -1 on error.
///
/// # Parameters
/// - track_uris_json: JSON array of track URIs as a C string (e.g., "[\"spotify:track:xxx\", \"spotify:track:yyy\"]")
#[no_mangle]
pub extern "C" fn spotifly_play_tracks(track_uris_json: *const c_char) -> i32 {
    debug!("spotifly_play_tracks called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    if track_uris_json.is_null() {
        debug!("Play tracks error: track_uris_json is null");
        return -1;
    }

    let track_uris_str = unsafe {
        match CStr::from_ptr(track_uris_json).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play tracks error: invalid track_uris_json string");
                return -1;
            }
        }
    };

    // Parse JSON array of track URIs
    let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
        Ok(uris) => uris,
        Err(_e) => {
            debug!("Play tracks error: failed to parse JSON: {:?}", _e);
            return -1;
        }
    };

    if track_uris.is_empty() {
        debug!("Play tracks error: empty track URIs array");
        return -1;
    }

    // Use Spirc.load() for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Ensure device is active before loading
            if let Err(e) = ensure_active_for_playback(spirc) {
                return e;
            }

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
                    debug!("Spirc.load(tracks) succeeded");
                    IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug!("Play tracks error: Spirc.load() failed: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play tracks error: Spirc not initialized");
            -1
        }
    }
}

/// Plays content by its Spotify URI or URL.
/// Supports albums, playlists, and artists (context URIs).
/// @param uri_or_url Spotify URI or URL (e.g., "spotify:album:xxx")
/// @param track_index Track index to start at (-1 = from beginning, 0+ = specific track)
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_uri(uri_or_url: *const c_char, track_index: i32) -> i32 {
    if uri_or_url.is_null() {
        debug!("Play error: uri_or_url is null");
        return -1;
    }

    let input_str = unsafe {
        match CStr::from_ptr(uri_or_url).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play error: invalid uri_or_url string");
                return -1;
            }
        }
    };

    // Convert URL to URI if needed
    let uri_str = url_to_uri(&input_str);
    debug!(
        "spotifly_play_uri called: uri={}, track_index={}",
        uri_str, track_index
    );

    if let Err(e) = require_session_connected() {
        return e;
    }

    // Use Spirc.load() with LoadRequest for proper Connect state sync
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Ensure device is active before loading
            if let Err(e) = ensure_active_for_playback(spirc) {
                return e;
            }

            // Determine playing_track option based on track_index
            let playing_track = if track_index >= 0 {
                Some(PlayingTrack::Index(track_index as u32))
            } else {
                None
            };

            // Create LoadRequest - use from_context_uri for albums/playlists/artists,
            // from_tracks for single tracks (legacy behavior, prefer using radio for tracks)
            let load_request = if uri_str.starts_with("spotify:track:") {
                // Legacy single-track behavior - prefer using spotifly_play_radio instead
                debug!("Spirc.load(LoadRequest::from_tracks([{}]))", uri_str);
                LoadRequest::from_tracks(
                    vec![uri_str.clone()],
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        ..Default::default()
                    },
                )
            } else {
                // Context-based playback with optional starting track
                debug!(
                    "Spirc.load(LoadRequest::from_context_uri({}, playing_track={:?}))",
                    uri_str, playing_track
                );
                LoadRequest::from_context_uri(
                    uri_str.clone(),
                    LoadRequestOptions {
                        start_playing: true,
                        seek_to: 0,
                        playing_track,
                        ..Default::default()
                    },
                )
            };

            match spirc.load(load_request) {
                Ok(_) => {
                    debug!("Spirc.load() succeeded");
                    IS_PLAYING.store(true, Ordering::SeqCst);
                    IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug!("Play error: Spirc.load() failed: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play error: Spirc not initialized");
            -1
        }
    }
}

/// Pauses playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_pause() -> i32 {
    debug!("spotifly_pause called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.pause() {
            Ok(_) => {
                IS_PLAYING.store(false, Ordering::SeqCst);
                0
            }
            Err(e) => {
                debug!("Pause error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Pause error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Clears any buffered audio samples.
/// The Swift-side callback handles the flush synchronously before returning.
/// Note: spotifly_disconnect() already handles this internally.
#[no_mangle]
pub extern "C" fn spotifly_clear_audio_buffer() {
    debug!("spotifly_clear_audio_buffer called");
    proxy_sink::ProxySink::clear_buffer();
}

/// Resumes playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_resume() -> i32 {
    debug!("spotifly_resume called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.play() {
            Ok(_) => {
                IS_PLAYING.store(true, Ordering::SeqCst);
                0
            }
            Err(e) => {
                debug!("Resume error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Resume error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Stops playback completely.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_stop() -> i32 {
    debug!("spotifly_stop called");
    let player_guard = PLAYER.lock().unwrap();
    match player_guard.as_ref() {
        Some(player) => {
            player.stop();
            IS_PLAYING.store(false, Ordering::SeqCst);
            0
        }
        None => {
            debug!("Stop error: player not initialized");
            -1
        }
    }
}

/// Shuts down the Spirc connection and sends goodbye to other devices.
/// Call this when the app is quitting to properly disconnect from Spotify Connect.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_shutdown() -> i32 {
    debug!("spotifly_shutdown called");
    // Prevent reconnection attempts during intentional shutdown
    SHUTTING_DOWN.store(true, Ordering::SeqCst);
    let spirc_guard = SPIRC.lock().unwrap();
    if let Some(spirc) = spirc_guard.as_ref() {
        if spirc.shutdown().is_ok() {
            return 0;
        }
    }
    -1
}

/// Disconnects from Spotify Connect without preventing future reconnection.
/// Use this before system sleep - the device disappears from Spotify immediately,
/// but forceReconnect() can still bring it back on wake.
/// Unlike shutdown(), this does NOT set SHUTTING_DOWN, so auto-reconnect still works.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_disconnect() -> i32 {
    debug!("spotifly_disconnect called - disconnecting for sleep");
    // Set sleeping flag to prevent auto-reconnect when cluster listener ends
    SLEEPING.store(true, Ordering::SeqCst);

    let spirc_guard = SPIRC.lock().unwrap();
    if let Some(spirc) = spirc_guard.as_ref() {
        // First pause playback to stop producing new audio
        let _ = spirc.pause();
        debug!("spotifly_disconnect: paused playback");

        // Clear the audio buffer synchronously to flush any remaining samples
        // This must complete before we return, otherwise stale audio plays on wake
        drop(spirc_guard); // Release lock before blocking call
        proxy_sink::ProxySink::clear_buffer();
        debug!("spotifly_disconnect: audio buffer cleared");

        // Now shutdown Spirc (disconnect from Spotify Connect)
        let spirc_guard = SPIRC.lock().unwrap();
        if let Some(spirc) = spirc_guard.as_ref() {
            if spirc.shutdown().is_ok() {
                debug!("spotifly_disconnect: spirc shutdown complete");
                return 0;
            }
        }
    }
    -1
}

/// Cleans up all player state, allowing a fresh reinitialization.
/// Call this before spotifly_init_player() when the session has disconnected.
/// This clears all static state (session, player, spirc, etc.)
#[no_mangle]
pub extern "C" fn spotifly_cleanup() {
    debug!("spotifly_cleanup called - clearing all state");

    // Signal event listener to stop
    {
        let mut tx_guard = PLAYER_EVENT_TX.lock().unwrap();
        if let Some(tx) = tx_guard.take() {
            let _ = tx.send(());
        }
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer
    shutdown_spirc("spotifly_cleanup");

    // Now clear Spirc reference
    {
        let mut spirc_guard = SPIRC.lock().unwrap();
        *spirc_guard = None;
    }
    SPIRC_READY.store(false, Ordering::SeqCst);

    // Clear player
    {
        let mut player_guard = PLAYER.lock().unwrap();
        *player_guard = None;
    }

    // Clear mixer
    {
        let mut mixer_guard = MIXER.lock().unwrap();
        *mixer_guard = None;
    }

    // Clear session
    {
        let mut session_guard = SESSION.lock().unwrap();
        *session_guard = None;
    }

    // Clear device ID
    {
        let mut device_id_guard = DEVICE_ID.lock().unwrap();
        *device_id_guard = None;
    }

    // Reset state flags
    IS_PLAYING.store(false, Ordering::SeqCst);
    IS_ACTIVE_DEVICE.store(false, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(0, Ordering::SeqCst);
    LAST_VOLUME.store(0, Ordering::SeqCst);

    // Reset session connection state
    {
        let mut state = SESSION_CONNECTION_STATE.lock().unwrap();
        state.is_connected = false;
        state.connection_id = None;
    }

    // Reset connection state tracking (but keep reconnect_attempt for backoff)
    CONNECTED_SINCE_MS.store(0, Ordering::SeqCst);
    // Note: We don't reset RECONNECT_ATTEMPT here - it's used for exponential backoff
    // and should only be reset on successful reconnect (in SessionConnected handler)

    // Notify connection state change
    notify_connection_state_change();

    debug!("spotifly_cleanup complete - ready for reinitialization");
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_playing() -> i32 {
    if IS_PLAYING.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Returns 1 if this device is the active Spotify Connect device, 0 otherwise.
/// When not active, playback controls should use Web API instead of Spirc.
#[no_mangle]
pub extern "C" fn spotifly_is_active_device() -> i32 {
    if IS_ACTIVE_DEVICE.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
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
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_next() -> i32 {
    debug!("spotifly_next called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.next() {
            Ok(_) => 0,
            Err(e) => {
                debug!("Next error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Next error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_previous() -> i32 {
    debug!("spotifly_previous called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.prev() {
            Ok(_) => 0,
            Err(e) => {
                debug!("Previous error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Previous error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_seek(position_ms: u32) -> i32 {
    debug!("spotifly_seek called: {}ms", position_ms);
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.set_position_ms(position_ms) {
            Ok(_) => 0,
            Err(e) => {
                debug!("Seek error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Seek error: Spirc not initialized");
            ERROR_GENERAL
        }
    }
}

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_radio(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        debug!("Play radio error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Play radio error: invalid track_uri string");
                return -1;
            }
        }
    };

    debug!("spotifly_play_radio called: {}", uri_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug!("Play radio error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    // Get the radio playlist URI
    let playlist_uri: Result<String, String> = RUNTIME.block_on(async {
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        let response = session
            .spclient()
            .get_radio_for_track(&spotify_uri)
            .await
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
            debug!("Play radio error: {}", _e);
            return -1;
        }
    };

    debug!("Loading radio playlist: {}", playlist_uri);

    // Load the radio playlist via Spirc
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Ensure device is active before loading
            if let Err(e) = ensure_active_for_playback(spirc) {
                return e;
            }

            let load_request = LoadRequest::from_context_uri(
                playlist_uri,
                LoadRequestOptions {
                    start_playing: true,
                    seek_to: 0,
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => {
                    IS_ACTIVE_DEVICE.store(true, Ordering::SeqCst);
                    0
                }
                Err(_e) => {
                    debug!("Play radio error: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Play radio error: Spirc not initialized");
            -1
        }
    }
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_set_volume(volume: u16) -> i32 {
    debug!("spotifly_set_volume called: {}", volume);
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.set_volume(volume) {
            Ok(_) => 0,
            Err(e) => {
                debug!("Set volume error: {:?}", e);
                if is_channel_closed_error(&e) {
                    ERROR_NEEDS_REINIT
                } else {
                    ERROR_GENERAL
                }
            }
        },
        None => {
            debug!("Set volume error: Spirc not initialized");
            ERROR_GENERAL
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
        let _kbps = match value {
            0 => 96,
            2 => 320,
            _ => 160,
        };
        debug!(
            "Bitrate changed to {}kbps (restart playback to apply)",
            _kbps
        );
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
        debug!(
            "Gapless playback changed to {} (restart playback to apply)",
            enabled
        );
    }
}

/// Gets the current gapless playback setting.
#[no_mangle]
pub extern "C" fn spotifly_get_gapless() -> bool {
    GAPLESS_SETTING.load(Ordering::SeqCst)
}

/// Sets the initial volume (0-65535) used when registering with Spotify Connect.
/// Must be called before spotifly_init_player() to take effect.
#[no_mangle]
pub extern "C" fn spotifly_set_initial_volume(volume: u16) {
    INITIAL_VOLUME_SETTING.store(volume, Ordering::SeqCst);
}

/// Transfers playback from another device to this local player.
/// Uses the native Spotify Connect protocol via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_transfer_to_local() -> i32 {
    debug!("spotifly_transfer_to_local called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            // Pass None to transfer from whatever device is currently playing
            match spirc.transfer(None) {
                Ok(_) => 0,
                Err(_e) => {
                    debug!("Transfer error: {:?}", _e);
                    -1
                }
            }
        }
        None => {
            debug!("Transfer error: Spirc not initialized");
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
        debug!("Transfer playback error: to_device_id is null");
        return -1;
    }

    let to_device_str = unsafe {
        match CStr::from_ptr(to_device_id).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Transfer playback error: invalid to_device_id string");
                return -1;
            }
        }
    };

    debug!("spotifly_transfer_playback called: {}", to_device_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            debug!("Transfer playback error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let device_id_guard = DEVICE_ID.lock().unwrap();
    let from_device_id = match device_id_guard.as_ref() {
        Some(id) => id.clone(),
        None => {
            debug!("Transfer playback error: device ID not initialized");
            return -1;
        }
    };
    drop(device_id_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        session
            .spclient()
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
            debug!("Transfer playback error: {}", _e);
            -1
        }
    }
}

/// Returns 1 if Spirc is initialized and connected to Spotify Connect, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_spirc_ready() -> i32 {
    if SPIRC_READY.load(Ordering::SeqCst) {
        1
    } else {
        0
    }
}

/// Adds an item to the queue.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_add_to_queue(uri: *const c_char) -> i32 {
    if uri.is_null() {
        debug!("Add to queue error: uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                debug!("Add to queue error: invalid uri string");
                return -1;
            }
        }
    };

    debug!("[Spotifly] spotifly_add_to_queue called: {}", uri_str);

    if let Err(e) = require_session_connected() {
        return e;
    }

    // Parse string to SpotifyUri
    let spotify_uri = match parse_spotify_uri(&uri_str) {
        Ok(uri) => uri,
        Err(e) => {
            debug!("Add to queue error: {}", e);
            return -1;
        }
    };

    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => match spirc.add_to_queue(spotify_uri) {
            Ok(_) => {
                debug!("[Spotifly] add_to_queue succeeded");
                0
            }
            Err(e) => {
                debug!("Add to queue error: {:?}", e);
                -1
            }
        },
        None => {
            debug!("Add to queue error: Spirc not initialized");
            -1
        }
    }
}
