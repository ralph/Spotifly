mod proxy_sink;

use futures_util::StreamExt;
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc};
use librespot_core::cache::Cache;
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::SpotifyUri;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig, NoOpVolume};
use librespot_playback::player::{Player, PlayerEvent, QueueTrack};
use librespot_protocol::connect::ClusterUpdate;
use librespot_protocol::player::{PlayerState, ProvidedTrack};
use log::debug;
use once_cell::sync::Lazy;
use proxy_sink::mk_proxy_sink;
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering};
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
static IS_PLAYING: AtomicBool = AtomicBool::new(false);
static PLAYING_EVENT_SEQ: AtomicU64 = AtomicU64::new(0);
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static PLAYBACK_STATE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static VOLUME_CALLBACK: Lazy<Mutex<Option<extern "C" fn(u16)>>> = Lazy::new(|| Mutex::new(None));
static LOADING_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static QUEUE_CHANGED_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static BECAME_INACTIVE_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static BECAME_ACTIVE_CALLBACK: Lazy<Mutex<Option<extern "C" fn()>>> =
    Lazy::new(|| Mutex::new(None));
static SESSION_CLIENT_CHANGED_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static SET_QUEUE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static ACTIVE_DEVICE_CALLBACK: Lazy<Mutex<Option<extern "C" fn(*const c_char)>>> =
    Lazy::new(|| Mutex::new(None));
static LAST_ACTIVE_DEVICE_ID: Lazy<Mutex<String>> = Lazy::new(|| Mutex::new(String::new()));
static LAST_VOLUME: AtomicU16 = AtomicU16::new(0);
static SHUFFLE_STATE: AtomicBool = AtomicBool::new(false);
static REPEAT_TRACK_STATE: AtomicBool = AtomicBool::new(false);
static REPEAT_CONTEXT_STATE: AtomicBool = AtomicBool::new(false);

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

/// Everything the connection snapshot publishes, behind a single lock.
///
/// These fields used to live in six independent globals (three mutexes and three
/// atomics), so a snapshot assembled from them could mix values from different
/// transitions — ready from one, connection metadata from another. Keeping them
/// together makes every published snapshot internally consistent by construction.
///
/// `connected_since_ms` uses 0 for "never connected"; the wire format maps that to null.
///
/// `is_active_device` also lives here rather than in a separate atomic. It used to be
/// tracked in `IS_ACTIVE_DEVICE`, written from fourteen scattered command and event sites
/// and never reconciled against the cluster, while Swift separately tracked activity from
/// the active-device-id callback — so playback routing and the UI could disagree about
/// whether Spotifly or a remote speaker was active.
#[derive(Default, Clone)]
struct ConnectionState {
    session_connected: bool,
    session_connection_id: Option<String>,
    spirc_ready: bool,
    device_id: Option<String>,
    reconnect_attempt: u32,
    last_error: Option<String>,
    connected_since_ms: u64,
    is_active_device: bool,
}

/// Derives whether this device is the active one from a cluster update.
///
/// An empty active-device ID means nothing is active anywhere. That is a real state and
/// must clear activity rather than be ignored, otherwise the last active device stays
/// displayed forever once playback stops.
fn is_active_in_cluster(active_device_id: &str, own_device_id: Option<&str>) -> bool {
    !active_device_id.is_empty() && own_device_id == Some(active_device_id)
}

/// Whether an intentional teardown is under way. Recovery must never fight one.
fn teardown_in_progress() -> bool {
    SHUTTING_DOWN.load(Ordering::SeqCst) || SLEEPING.load(Ordering::SeqCst)
}

/// Whether losing the active Connect role should start network recovery.
///
/// Deactivation is normally just a handoff to another device and must not reconnect. The
/// one case that must is a Session that has gone invalid: librespot calls
/// `handle_disconnect` on unexpected Spirc shutdown, and the cluster listener can miss
/// that while the dealer stream is still open.
fn should_recover_after_deactivation(session_invalid: bool, teardown_in_progress: bool) -> bool {
    session_invalid && !teardown_in_progress
}

/// What playback looked like when recovery was decided on.
///
/// Captured at the trigger rather than inside the reconnect task. Between those two points
/// the deactivation handler clears the active flag, a `Stopped` event clears `IS_PLAYING`,
/// and a final cluster update can clear both — so reading it late made "does an outage
/// resume playback" depend on event ordering rather than on what was actually playing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct RecoveryIntent {
    was_playing: bool,
    was_active: bool,
}

impl RecoveryIntent {
    /// Reads what is playing right now. Call this before touching playback state.
    fn capture() -> Self {
        Self {
            was_playing: IS_PLAYING.load(Ordering::SeqCst),
            was_active: is_active_device(),
        }
    }

    /// Only local playback is rehydrated. If another device was playing, it still is, and
    /// taking over would steal it from the user.
    fn should_resume(self) -> bool {
        self.was_playing && self.was_active
    }
}

/// Whether the periodic health check should start recovery.
///
/// Invalidity alone is not a sufficient trigger. `Session::is_invalid` is only set by
/// `shutdown()`, so a session that was created but never managed to connect — exactly what
/// a failed `init_player_async` leaves behind — reports itself valid forever. The state
/// that actually needs rescuing is "not connected and nobody is recovering", however it was
/// reached: a session that died, or one that never came up.
///
/// The reconnect check matters because the loop is the thing that fixes this; firing while
/// it is already running would only re-publish a disconnected snapshot once a minute.
fn health_check_should_recover(
    session_invalid: bool,
    session_connected: bool,
    reconnect_in_progress: bool,
    teardown_in_progress: bool,
) -> bool {
    !teardown_in_progress && !reconnect_in_progress && (session_invalid || !session_connected)
}

/// Whether a listener may act on an event, given the generation it was created for.
///
/// A superseded listener drains asynchronously after its replacement is installed, so it
/// can still deliver events belonging to a session that no longer exists.
fn listener_may_act(listener_generation: u64, current_generation: u64) -> bool {
    listener_generation == current_generation
}

/// Whether a reconnect loop may still rebuild, given the generation it set out to recover.
///
/// The loop sleeps up to 30 seconds between attempts. A manual restart or a teardown in
/// that window means the thing it is fixing is gone, and rebuilding would clobber whatever
/// replaced it.
fn reconnect_may_proceed(
    recovering_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    recovering_generation == current_generation && !teardown_in_progress
}

/// Whether a cluster listener that ended should start network recovery.
///
/// Only the listener belonging to the current session generation may act. An older
/// listener ending is the expected consequence of the session it belonged to being
/// replaced, not evidence of a transport failure — acting on it would reconnect a session
/// that is already healthy.
fn should_recover_after_cluster_end(
    listener_generation: u64,
    current_generation: u64,
    teardown_in_progress: bool,
) -> bool {
    listener_generation == current_generation && !teardown_in_progress
}

/// Whether this device is currently the active Spotify Connect device.
fn is_active_device() -> bool {
    with_connection(|c| c.is_active_device)
}

/// Records whether this device is the active one, publishing the change if it moved.
fn set_active_device(active: bool) {
    if store_active_device(active) {
        notify_connection_state_change();
    }
}

/// Records activity without publishing, returning whether it changed.
///
/// For callers that are mid-transition and will publish once when they are done —
/// `init_player_async` still has to rehydrate after activating, and publishing in between
/// is what let Swift bootstrap against a half-built session.
fn store_active_device(active: bool) -> bool {
    let changed = with_connection(|c| {
        let changed = c.is_active_device != active;
        c.is_active_device = active;
        changed
    });
    if changed {
        debug!("Active device changed: is_active={}", active);
    }
    changed
}

static CONNECTION: Lazy<Mutex<ConnectionState>> =
    Lazy::new(|| Mutex::new(ConnectionState::default()));

/// Mutates the connection state under its lock and returns whatever `f` returns.
///
/// Does not publish — callers decide when to `notify_connection_state_change()`, so a
/// multi-field transition emits one snapshot rather than one per field. Never call
/// `notify_connection_state_change()` from inside `f`: it locks `CONNECTION` too.
fn with_connection<R>(f: impl FnOnce(&mut ConnectionState) -> R) -> R {
    let mut state = CONNECTION.lock().unwrap();
    f(&mut state)
}

/// Returns the device ID assigned at session creation, if a session has been built.
fn current_device_id() -> Option<String> {
    with_connection(|c| c.device_id.clone())
}

// Position tracking - updated from player events
static POSITION_MS: AtomicU32 = AtomicU32::new(0);

// Current track duration (ms) - updated from TrackChanged event
static CURRENT_DURATION_MS: AtomicU32 = AtomicU32::new(0);

// Current track URI - for detecting same-track reconnects
static CURRENT_TRACK_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// Current context URI - captured from SetQueue and cluster player state updates.
// We keep the latest non-empty value to recover resume after reconnect.
static CURRENT_CONTEXT_URI: Lazy<Mutex<Option<String>>> = Lazy::new(|| Mutex::new(None));

// Connection state tracking - for transparency dashboard. See ConnectionState above;
// reconnect attempt, connected-since, and last error all live there now.
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

// Generation counter for reconnection. Bumped once per rebuild, in init_player_async, and
// captured by every listener that rebuild creates. A listener whose captured generation no
// longer matches belongs to a session that has already been replaced, and must not act.
//
// There used to be a second global, EVENT_LISTENER_GENERATION, holding "the generation the
// current event listener belongs to". Soft reconnect kept one listener alive across
// sessions, so the listener could not simply capture its generation — and the global was
// written to the new value on every bump, which made the two always equal and the staleness
// check unreachable. Now that a rebuild replaces the listener along with its session, the
// listener captures the value directly and the check does what it claims.
static SESSION_GENERATION: AtomicU64 = AtomicU64::new(0);

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
    is_active_device: bool,
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
}

fn update_current_context_uri(context_uri: &str) {
    if context_uri.is_empty() {
        return;
    }
    let mut context_guard = CURRENT_CONTEXT_URI.lock().unwrap();
    *context_guard = Some(context_uri.to_string());
}

fn update_playback_options(shuffle: bool, repeat_track: bool, repeat_context: bool) {
    SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(repeat_track, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(repeat_context, Ordering::SeqCst);
}

fn current_playback_options() -> (bool, bool, bool) {
    (
        SHUFFLE_STATE.load(Ordering::SeqCst),
        REPEAT_TRACK_STATE.load(Ordering::SeqCst),
        REPEAT_CONTEXT_STATE.load(Ordering::SeqCst),
    )
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

/// Copies a C string argument into an owned `String`, or `None` if it is null or not UTF-8.
///
/// # Safety
/// `ptr` must be null or point to a valid NUL-terminated C string.
unsafe fn c_string_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    let c_str = unsafe { CStr::from_ptr(ptr) };
    c_str.to_str().ok().map(str::to_owned)
}

/// Copies a registered callback out of its slot, releasing the slot lock before returning.
///
/// No callback may run with its slot lock held: it re-enters Swift, which can call straight
/// back into Rust. Taking the pointer out here makes that structural instead of a
/// `drop(guard)` that every call site has to remember.
fn registered_callback<F: Copy>(slot: &Mutex<Option<F>>) -> Option<F> {
    *slot.lock().unwrap()
}

/// Serializes `payload` and hands it to a Swift callback as a C string.
///
/// The C string outlives the call and is freed on return: Swift copies what it needs
/// before the callback returns.
fn send_json<T: Serialize>(callback: extern "C" fn(*const c_char), payload: &T) {
    match serde_json::to_string(payload) {
        Ok(json) => {
            let c_str = CString::new(json).unwrap();
            callback(c_str.as_ptr());
        }
        Err(e) => debug!("Failed to serialize callback payload: {:?}", e),
    }
}

/// Runs a command against the current Spirc and maps the outcome to an FFI error code.
///
/// `what` names the command in the error logs. A closed channel is reported separately
/// (`ERROR_NEEDS_REINIT`) because Swift responds to it by rebuilding the player rather
/// than by surfacing a failure.
fn spirc_command(
    what: &str,
    command: impl FnOnce(&Spirc) -> Result<(), librespot_core::Error>,
) -> i32 {
    let spirc_guard = SPIRC.lock().unwrap();
    let Some(spirc) = spirc_guard.as_ref() else {
        debug!("{} error: Spirc not initialized", what);
        return ERROR_GENERAL;
    };

    match command(spirc) {
        Ok(()) => 0,
        Err(e) => {
            debug!("{} error: {:?}", what, e);
            if is_channel_closed_error(&e) {
                ERROR_NEEDS_REINIT
            } else {
                ERROR_GENERAL
            }
        }
    }
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
    *QUEUE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive playback state updates (as JSON string).
#[no_mangle]
pub extern "C" fn spotifly_register_playback_state_callback(
    callback: extern "C" fn(*const c_char),
) {
    *PLAYBACK_STATE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive volume change notifications.
/// Called when the volume is changed remotely (e.g., from another Spotify Connect device).
/// The callback receives the new volume (0-65535).
#[no_mangle]
pub extern "C" fn spotifly_register_volume_callback(callback: extern "C" fn(u16)) {
    *VOLUME_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive loading notifications.
/// Called when a new track starts loading (before metadata is fetched).
/// This fires earlier than TrackChanged (~180ms vs ~620ms after command).
/// The callback receives JSON with track_uri and position_ms.
#[no_mangle]
pub extern "C" fn spotifly_register_loading_callback(callback: extern "C" fn(*const c_char)) {
    *LOADING_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive queue change notifications.
/// Called when a remote device adds a track to the queue.
/// The callback receives JSON with track_uri.
#[no_mangle]
pub extern "C" fn spotifly_register_queue_changed_callback(callback: extern "C" fn(*const c_char)) {
    *QUEUE_CHANGED_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback fired when this device stops being the active Connect device.
///
/// This is an activity notification, not a health one: it fires on an explicit
/// disconnect, on shutdown, and whenever another device takes over playback. Do not
/// treat it as a connection failure - read the connection snapshot for that.
#[no_mangle]
pub extern "C" fn spotifly_register_became_inactive_callback(callback: extern "C" fn()) {
    *BECAME_INACTIVE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback fired when this device becomes the active Connect device.
///
/// Also an activity notification: the session was already connected beforehand, so this
/// says nothing about readiness. Use the connection snapshot to decide when commands
/// can be sent.
#[no_mangle]
pub extern "C" fn spotifly_register_became_active_callback(callback: extern "C" fn()) {
    *BECAME_ACTIVE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive session client changed notifications.
#[unsafe(no_mangle)]
pub extern "C" fn spotifly_register_session_client_changed_callback(
    callback: extern "C" fn(*const c_char),
) {
    *SESSION_CLIENT_CHANGED_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive set queue notifications.
/// Called when the queue is set/modified (via set_queue command from mobile app).
/// The callback receives JSON with next_tracks and prev_tracks arrays containing uri and provider.
#[no_mangle]
pub extern "C" fn spotifly_register_set_queue_callback(callback: extern "C" fn(*const c_char)) {
    *SET_QUEUE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback to receive active device ID changes from cluster updates.
/// Called on every cluster update with the current active device ID string.
#[no_mangle]
pub extern "C" fn spotifly_register_active_device_callback(callback: extern "C" fn(*const c_char)) {
    *ACTIVE_DEVICE_CALLBACK.lock().unwrap() = Some(callback);
}

/// Registers a callback for token requests during reconnection.
/// When Rust needs a fresh token to reconnect, it calls this callback.
/// Swift should respond by calling spotifly_set_token() with a fresh access token.
#[no_mangle]
pub extern "C" fn spotifly_register_token_request_callback(callback: extern "C" fn()) {
    *TOKEN_REQUEST_CALLBACK.lock().unwrap() = Some(callback);
}

/// Provides a fresh access token for reconnection.
/// Called by Swift in response to the token request callback.
/// The token is passed to the pending reconnection attempt.
#[no_mangle]
pub extern "C" fn spotifly_set_token(token: *const c_char) {
    let Some(token_str) = (unsafe { c_string_arg(token) }) else {
        debug!("spotifly_set_token: token is null or not valid UTF-8");
        return;
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
    *CONNECTION_STATE_CALLBACK.lock().unwrap() = Some(callback);
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
    let state = with_connection(|c| c.clone());

    ConnectionStateInfo {
        session_connected: state.session_connected,
        session_connection_id: state.session_connection_id,
        spirc_ready: state.spirc_ready,
        device_id: state.device_id,
        device_name: "Spotifly".to_string(),
        reconnect_attempt: state.reconnect_attempt,
        last_error: state.last_error,
        connected_since_ms: (state.connected_since_ms > 0).then_some(state.connected_since_ms),
        is_active_device: state.is_active_device,
    }
}

/// Marks the session as disconnected, records the reason, and notifies the UI.
fn mark_disconnected(reason: &str) {
    with_connection(|c| {
        c.session_connected = false;
        c.session_connection_id = None;
        c.connected_since_ms = 0;
        c.last_error = Some(reason.to_string());
    });
    notify_connection_state_change();
}

/// Sends the active device ID to the registered callback if it changed since the last update.
/// Called on every cluster update — deduplicates so Swift only sees actual changes.
///
/// An empty ID means "no device is active" and is forwarded as such. It used to be
/// dropped, which left Swift showing the previous active device forever once playback
/// stopped everywhere.
fn notify_active_device_id(device_id: &str) {
    // Only notify if the active device actually changed
    let mut last = LAST_ACTIVE_DEVICE_ID.lock().unwrap();
    if *last == device_id {
        return;
    }
    *last = device_id.to_string();
    drop(last);

    if let Some(callback) = registered_callback(&ACTIVE_DEVICE_CALLBACK) {
        if let Ok(c_str) = CString::new(device_id) {
            callback(c_str.as_ptr());
        }
    }
}

/// Sends connection state update to the registered callback
fn notify_connection_state_change() {
    if let Some(callback) = registered_callback(&CONNECTION_STATE_CALLBACK) {
        send_json(callback, &build_connection_state_info());
    }
}

/// Creates a new (unconnected) Session with the given device ID and access token.
fn create_session(
    device_id: &str,
    access_token: &str,
) -> Result<(Session, librespot_core::authentication::Credentials), String> {
    let session_config = SessionConfig {
        device_id: device_id.to_string(),
        ..Default::default()
    };
    let credentials = librespot_core::authentication::Credentials::with_access_token(access_token);
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

    *SPIRC.lock().unwrap() = Some(spirc_arc.clone());
    // Deliberately does not record success yet. Activation and, on a reconnect, the
    // rehydrating load still have to run, and either can fail — `init_player_async` commits
    // the whole set once, at the end, when the session is genuinely usable.
    //
    // Setting it here was subtly wrong in two ways. The activation that follows makes
    // librespot emit SessionConnected, whose handler publishes a snapshot; with the flags
    // already true that snapshot announced readiness before playback resumed. And a later
    // failure could only clear the booleans, leaving a fresh connected-since timestamp and
    // a reset attempt counter in the disconnected snapshot that followed.

    debug!(
        "[WAKE +{}ms] Spirc ready - connected to Spotify Connect",
        elapsed_since_wake_ms()
    );

    // Small delay to let librespot's initial cluster processing complete
    tokio::time::sleep(Duration::from_millis(200)).await;

    Ok(spirc_arc)
}

/// How often to check whether the current session needs recovery.
const SESSION_HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(60);

/// Watches for a session that is unusable while no other recovery owner is active.
///
/// Every other recovery trigger needs something to happen: the cluster listener only acts
/// when its stream *closes*, and librespot's dealer retries internally so the stream can
/// stay open for minutes past a dead session; the zombie check in
/// `require_session_connected` only runs when a command is issued. While Spotifly is the
/// active device something trips one of those quickly. While it is *not* active, nothing
/// may. The same check also covers a partial initialization that stored a Session but never
/// reached the connected-and-Spirc-ready state. In either case it starts the normal
/// reconnect loop unless that loop or an intentional teardown already owns the lifecycle.
///
/// Cost is one sleeping task per generation, waking once a minute to read a few flags
/// (`Session::is_invalid` is a lock read of a `bool`). It exits when its generation is
/// superseded, so it dies with the session it belongs to rather than accumulating.
fn spawn_session_health_check(generation: u64) {
    RUNTIME.spawn(async move {
        loop {
            tokio::time::sleep(SESSION_HEALTH_CHECK_INTERVAL).await;

            // Superseded: whatever replaced our session brought its own check.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                return;
            }

            // Sleep and shutdown invalidate the session on purpose.
            if teardown_in_progress() {
                continue;
            }

            let session_invalid = SESSION
                .lock()
                .unwrap()
                .as_ref()
                .is_some_and(|s| s.is_invalid());

            if health_check_should_recover(
                session_invalid,
                with_connection(|c| c.session_connected),
                RECONNECTING.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!(
                    "Session health check: session {} needs recovery (invalid={})",
                    generation, session_invalid
                );
                let intent = RecoveryIntent::capture();
                mark_disconnected("Session unusable");
                spawn_reconnection_loop(intent);
                // Recovery owns it from here; the rebuild spawns the next check.
                return;
            }
        }
    });
}

/// Subscribes to cluster updates on the session's dealer and spawns a task to process them.
///
/// When the stream ends, the Spirc it belonged to is gone, so this triggers reconnection —
/// but only for the current generation, and only outside an intentional teardown.
fn spawn_cluster_listener(session: &Session, generation: u64) -> Result<(), String> {
    let queue_stream = session
        .dealer()
        .listen_for(
            "hm://connect-state/v1/cluster",
            librespot_core::dealer::protocol::Message::from_raw::<ClusterUpdate>,
        )
        .map_err(|e| format!("Failed to subscribe to cluster updates: {}", e))?;

    RUNTIME.spawn(async move {
        debug!("Cluster listener started (generation={})", generation);
        let mut stream = queue_stream;
        while let Some(msg_result) = stream.next().await {
            // Same rule as the player event listener: a superseded cluster listener keeps
            // receiving until its stream actually closes, and its updates describe a session
            // that has been replaced. Checking only after the stream ends, as this used to,
            // leaves every message before that point unguarded.
            if !listener_may_act(generation, SESSION_GENERATION.load(Ordering::SeqCst)) {
                continue;
            }

            match msg_result {
                Ok(cluster_update) => {
                    if let Some(cluster) = cluster_update.cluster.into_option() {
                        // Derive our own activity from the cluster rather than inferring it
                        // from whichever command happened to run last. This is the same
                        // comparison SpircTask makes internally; Spotifly runs a second
                        // subscription to the same dealer topic and has to reach the same
                        // conclusion, or playback routing and the UI disagree.
                        set_active_device(is_active_in_cluster(
                            &cluster.active_device_id,
                            current_device_id().as_deref(),
                        ));
                        notify_active_device_id(&cluster.active_device_id);
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

        debug!("Cluster listener ended (generation={})", generation);

        let current_gen = SESSION_GENERATION.load(Ordering::SeqCst);
        if !should_recover_after_cluster_end(generation, current_gen, teardown_in_progress()) {
            debug!(
                "Cluster listener ended without recovery (generation={}, current={})",
                generation, current_gen
            );
            return;
        }

        let intent = RecoveryIntent::capture();
        mark_disconnected("Cluster listener ended unexpectedly");
        spawn_reconnection_loop(intent);
    });

    Ok(())
}

/// Request a fresh token from Swift via callback
fn request_token_from_swift() {
    match registered_callback(&TOKEN_REQUEST_CALLBACK) {
        Some(callback) => {
            debug!("Requesting fresh token from Swift");
            callback();
        }
        None => debug!("No token request callback registered"),
    }
}

/// Spawns the reconnection loop task.
/// Uses exponential backoff and requests fresh tokens from Swift.
fn spawn_reconnection_loop(intent: RecoveryIntent) {
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

    RUNTIME.spawn(async move {

        // The generation this loop is recovering. Between two attempts it can sleep for up
        // to 30 seconds, and during that time something else — a manual restart from the
        // wake path, or spotifly_cleanup on logout — may have already rebuilt or torn down
        // the session. Waking up and rebuilding anyway would replace a healthy new session
        // with one built from a stale token. RECONNECTING alone never caught this: it says
        // "a loop is running", not "the thing it is fixing still exists".
        // Mutable on purpose: each rebuild attempt bumps SESSION_GENERATION itself, so the
        // loop adopts the value its own attempt produced. Without that it reads its own
        // work as a foreign supersede and gives up after a single failed attempt.
        let mut recovering_generation = SESSION_GENERATION.load(Ordering::SeqCst);

        // Backoff that never gives up. This used to be a fixed schedule of ten attempts
        // totalling about three minutes, after which the loop exited — so an outage longer
        // than that left the app dead with nothing running to notice the network coming
        // back, and only a manual play would recover it. The loop is not idle polling: it
        // exists only while disconnected and exits on any lifecycle event, because every
        // iteration re-checks the generation and the teardown flags below.
        let mut attempt: u32 = 0;

        loop {
            let delay = match attempt {
                0 => 0,
                1 => 2,
                2 => 5,
                3 => 10,
                _ => 30,
            };
            // Advance before any `continue` below, so a token failure still backs off
            // instead of spinning on a zero delay.
            let attempt_number = attempt + 1;
            attempt = attempt.saturating_add(1);

            if delay > 0 {
                tokio::time::sleep(Duration::from_secs(delay)).await;
            }

            if !reconnect_may_proceed(
                recovering_generation,
                SESSION_GENERATION.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!(
                    "[WAKE +{}ms] Abandoning reconnect for generation {}: superseded or torn down",
                    elapsed_since_wake_ms(),
                    recovering_generation
                );
                RECONNECTING.store(false, Ordering::SeqCst);
                return;
            }

            debug!("[WAKE +{}ms] Reconnect attempt {}", elapsed_since_wake_ms(), attempt_number);
            with_connection(|c| {
                c.reconnect_attempt = attempt_number;
                c.last_error = Some(format!("Reconnecting (attempt {})", attempt_number));
            });
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

            // Re-check after the token round-trip: requesting one from Swift can take up
            // to ten seconds, which is plenty of time for a restart to land.
            if !reconnect_may_proceed(
                recovering_generation,
                SESSION_GENERATION.load(Ordering::SeqCst),
                teardown_in_progress(),
            ) {
                debug!("[WAKE +{}ms] Abandoning reconnect: state changed while fetching token", elapsed_since_wake_ms());
                RECONNECTING.store(false, Ordering::SeqCst);
                return;
            }

            // One recovery strategy: tear everything down and rebuild Session, Player,
            // Mixer and Spirc as a single generation, then restore the captured intent.
            //
            // There used to be a "soft reconnect" that kept the Player alive across
            // sessions to avoid an audible gap. It bought a shorter interruption at the
            // cost of a Player outliving the Session it was built for, which is what
            // forced the librespot patch that makes Spirc adopt an orphaned
            // play_request_id, the context-reload-after-reconnect blip, and a watchdog
            // that re-issued play commands when the audio key fetch on the dead session
            // silently timed out. A brief gap during an outage is the better trade.
            do_reconnect_cleanup();

            // Rehydration happens inside init_player_async, so that the session is fully
            // settled before its readiness is published. See the note there.
            match init_player_async(&token, intent.was_active, intent.should_resume()).await {
                Ok(_) => {
                    debug!("[WAKE +{}ms] Reconnect successful on attempt {}", elapsed_since_wake_ms(), attempt_number);
                    RECONNECTING.store(false, Ordering::SeqCst);
                    return;
                }
                Err(e) => {
                    debug!("[WAKE +{}ms] Reconnect attempt {} failed: {}", elapsed_since_wake_ms(), attempt_number, e);
                    // Adopt the generation this attempt created. init_player_async bumps it
                    // before it can fail, so leaving the old value here would make the next
                    // iteration mistake our own rebuild for someone else's and abandon.
                    recovering_generation = SESSION_GENERATION.load(Ordering::SeqCst);
                    with_connection(|c| c.last_error = Some(format!("Reconnect failed: {}", e)));
                    notify_connection_state_change();
                }
            }
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
    if SESSION.lock().unwrap().is_none() {
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
    spawn_reconnection_loop(RecoveryIntent::capture());

    0
}

/// Performs full cleanup for reconnection.
/// Clears Session, Spirc, Player, and Mixer because Player is tightly coupled
/// to the Session's ChannelManager for decryption key requests.
fn do_reconnect_cleanup() {
    debug!("do_reconnect_cleanup: full cleanup for reconnection");

    // Signal event listener to stop
    if let Some(tx) = PLAYER_EVENT_TX.lock().unwrap().take() {
        let _ = tx.send(());
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer,
    // which will cause the cluster listener stream to end. Without this, old tasks
    // remain alive holding references to Session/Player until the server closes the connection.
    shutdown_spirc("do_reconnect_cleanup");

    // Now clear Spirc reference
    *SPIRC.lock().unwrap() = None;
    with_connection(|c| c.spirc_ready = false);

    // Clear Player - must be recreated with new Session. Tell Swift first: dropping the
    // Player does not run Sink::stop, so the renderer would otherwise keep believing it is
    // rendering and skip resetting its real-time throttle on the next start.
    proxy_sink::ProxySink::notify_player_gone();
    *PLAYER.lock().unwrap() = None;

    // Clear Mixer
    *MIXER.lock().unwrap() = None;

    // Clear Session
    *SESSION.lock().unwrap() = None;

    // Clear device ID (will be regenerated) and reset session connection state
    with_connection(|c| {
        c.device_id = None;
        c.session_connected = false;
        c.session_connection_id = None;
        c.connected_since_ms = 0;
    });

    debug!("do_reconnect_cleanup complete");
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

    let Some(token_str) = (unsafe { c_string_arg(access_token) }) else {
        debug!("Player init error: access_token is null or not valid UTF-8");
        return -1;
    };

    // Check if we already have a session
    {
        let session_guard = SESSION.lock().unwrap();
        if session_guard.is_some() {
            // Already initialized
            return 0;
        }
    }

    let result = RUNTIME.block_on(async { init_player_async(&token_str, false, false).await });

    match result {
        Ok(_) => 0,
        Err(_e) => {
            debug!("Player init error: {}", _e);
            -1
        }
    }
}

/// Helper function to create a new Player instance
fn create_new_player(session: &Session) -> Arc<Player> {
    let (bitrate, bitrate_kbps) = match BITRATE_SETTING.load(Ordering::SeqCst) {
        0 => (Bitrate::Bitrate96, 96),
        2 => (Bitrate::Bitrate320, 320),
        _ => (Bitrate::Bitrate160, 160),
    };
    let gapless = GAPLESS_SETTING.load(Ordering::SeqCst);

    debug!(
        "Player initialized: bitrate={}kbps, gapless={}",
        bitrate_kbps, gapless
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
    //
    // NoOpVolume: do NOT attenuate samples here. Volume is applied at the output
    // (AVSampleBufferAudioRenderer.volume in Swift) so changes take effect
    // immediately instead of after the ~2s of already-decoded PCM drains. The
    // SoftMixer still tracks the logical volume for Spotify Connect reporting; it
    // just no longer feeds the player's sample gain.
    let player = Player::new(
        player_config,
        session.clone(),
        Box::new(NoOpVolume),
        move || mk_proxy_sink(None, audio_format),
    );

    // Store player globally
    *PLAYER.lock().unwrap() = Some(Arc::clone(&player));

    player
}

/// Builds a complete, settled session and publishes its readiness exactly once, at the end.
///
/// The ordering matters. Readiness used to be published the moment Spirc existed, while
/// activation and the rehydrating load still had to run — so Swift, which reacts to that
/// publication by bootstrapping from the Web API, fetched and applied a server snapshot
/// that Rust then immediately overwrote. That was visible as the playback position jumping
/// forward to a stale value and back. Publishing once, when nothing further is pending,
/// removes the window rather than racing it.
async fn init_player_async(
    access_token: &str,
    activate_after_connect: bool,
    resume_after_connect: bool,
) -> Result<(), String> {
    // Increment session generation - this invalidates any old cluster listeners
    let current_generation = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    debug!(
        "[WAKE +{}ms] init_player_async starting, generation={}",
        elapsed_since_wake_ms(),
        current_generation
    );

    let device_id = format!("spotifly_{}", std::process::id());
    with_connection(|c| c.device_id = Some(device_id.clone()));

    let (session, credentials) = create_session(&device_id, access_token)?;

    // Create new mixer
    let mixer_config = MixerConfig::default();
    let mixer: Arc<SoftMixer> =
        Arc::new(SoftMixer::open(mixer_config).map_err(|e| format!("Mixer error: {}", e))?);
    *MIXER.lock().unwrap() = Some(Arc::clone(&mixer));

    // Create new player - must be created with the new session because Player is
    // tightly coupled to Session's ChannelManager for decryption key requests
    let player = create_new_player(&session);

    // Get event channel from player, opting in to SetQueue events
    let mut event_channel = player.get_player_event_channel();

    // Create channel for stopping event listener
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();

    // This listener belongs to the generation being built here, for its whole life: a
    // rebuild replaces the listener along with the session, so the value never has to
    // change underneath it.
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
                    // Drop everything from a superseded generation. A replaced listener
                    // drains asynchronously after its successor is live — the logs show old
                    // listeners still delivering seconds later — and without this guard it
                    // would keep writing position, track, playing and active-device state
                    // belonging to a session that no longer exists.
                    //
                    // `event.is_some()` matters: a closed channel must still reach the
                    // `None` arm below and break the loop. Skipping on `None` would spin.
                    if event.is_some()
                        && !listener_may_act(
                            event_listener_generation,
                            SESSION_GENERATION.load(Ordering::SeqCst),
                        )
                    {
                        continue;
                    }

                    match event {
                        Some(PlayerEvent::Playing { position_ms, .. }) => {
                            debug!("PlayerEvent::Playing at {}ms", position_ms);
                            IS_PLAYING.store(true, Ordering::SeqCst);
                            set_active_device(true);
                            PLAYING_EVENT_SEQ.fetch_add(1, Ordering::SeqCst);
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
                            // Deliberately does not touch active-device state: playback
                            // stopping is not the same as losing the active Connect role.
                            // This used to clear it, which fought the cluster-derived value
                            // and made the UI think a remote speaker had taken over
                            // whenever local playback simply ended.
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
                        }
                        Some(PlayerEvent::EndOfTrack { track_id, .. }) => {
                            // Logged with the position it ended at: a natural end and a
                            // stream that stopped early are otherwise indistinguishable in
                            // the log, because Spirc's auto-advance is silent on success.
                            // Without this, "did the track finish or get cut off?" cannot be
                            // answered from a log at all.
                            debug!(
                                "PlayerEvent::EndOfTrack: {} at {}ms",
                                track_id,
                                POSITION_MS.load(Ordering::SeqCst)
                            );
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
                            if let Some(callback) = registered_callback(&LOADING_CALLBACK) {
                                send_json(callback, &LoadingNotification {
                                    track_uri: track_uri_str,
                                    position_ms: 0,
                                });
                            }
                        }
                        Some(PlayerEvent::VolumeChanged { volume }) => {
                            debug!("VolumeChanged event: {}", volume);
                            check_and_send_volume(volume as u32);
                        }
                        Some(PlayerEvent::ShuffleChanged { shuffle }) => {
                            debug!("PlayerEvent::ShuffleChanged: {}", shuffle);
                            SHUFFLE_STATE.store(shuffle, Ordering::SeqCst);
                            send_local_playback_state(
                                IS_PLAYING.load(Ordering::SeqCst),
                                POSITION_MS.load(Ordering::SeqCst),
                            );
                        }
                        Some(PlayerEvent::RepeatChanged { context, track }) => {
                            debug!(
                                "PlayerEvent::RepeatChanged: context={}, track={}",
                                context, track
                            );
                            REPEAT_CONTEXT_STATE.store(context, Ordering::SeqCst);
                            REPEAT_TRACK_STATE.store(track, Ordering::SeqCst);
                            send_local_playback_state(
                                IS_PLAYING.load(Ordering::SeqCst),
                                POSITION_MS.load(Ordering::SeqCst),
                            );
                        }
                        Some(PlayerEvent::Loading { track_id, position_ms, .. }) => {
                            let track_uri_str = track_id.to_string();
                            debug!("Loading event: {} at {}ms", track_uri_str, position_ms);

                            // Track current playing URI
                            {
                                let mut uri_guard = CURRENT_TRACK_URI.lock().unwrap();
                                *uri_guard = Some(track_uri_str.clone());
                            }

                            if let Some(callback) = registered_callback(&LOADING_CALLBACK) {
                                send_json(callback, &LoadingNotification {
                                    track_uri: track_uri_str,
                                    position_ms,
                                });
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
                            update_current_context_uri(&context_uri);
                            if let Some(callback) = registered_callback(&SET_QUEUE_CALLBACK) {
                                let to_track_info = |t: QueueTrack| QueueTrackInfo {
                                    uri: t.uri,
                                    provider: t.provider,
                                };
                                send_json(callback, &SetQueueNotification {
                                    context_uri,
                                    current_track: current_track.map(to_track_info),
                                    next_tracks: next_tracks.into_iter().map(to_track_info).collect(),
                                    prev_tracks: prev_tracks.into_iter().map(to_track_info).collect(),
                                });
                            }
                        }
                        // librespot emits SessionDisconnected when the local Connect device
                        // becomes INACTIVE — not when the network session fails.
                        // SpircTask::handle_disconnect() runs on an explicit Disconnect, on
                        // shutdown, and on any cluster update that hands the active role to
                        // another device. (This is upstream behavior, not part of our patch.)
                        //
                        // Treating it as an outage meant an ordinary handoff to a phone or a
                        // speaker marked the connection dead and started a reconnect loop
                        // against a perfectly healthy session.
                        Some(PlayerEvent::SessionDisconnected { connection_id, user_name }) => {
                            debug!("[WAKE +{}ms] became inactive (SessionDisconnected): connection_id={}, user={}, listener_generation={}",
                                   elapsed_since_wake_ms(), connection_id, user_name, event_listener_generation);

                            // Capture before clearing: the recovery decision below needs to
                            // know what was playing, and set_active_device wipes half of it.
                            let intent = RecoveryIntent::capture();
                            set_active_device(false);

                            // Only recover if the transport is genuinely broken. A dead
                            // Session here means the Spirc task went down with it (librespot
                            // calls handle_disconnect on unexpected shutdown), which the
                            // cluster listener may not observe if the dealer stream is still
                            // open. A missing Session means some other path already owns the
                            // lifecycle, so leave it alone.
                            let session_invalid = SESSION
                                .lock()
                                .unwrap()
                                .as_ref()
                                .is_some_and(|s| s.is_invalid());

                            if should_recover_after_deactivation(
                                session_invalid,
                                teardown_in_progress(),
                            ) {
                                debug!("[WAKE +{}ms] Session is invalid at deactivation - recovering", elapsed_since_wake_ms());
                                mark_disconnected("Session invalid");
                                spawn_reconnection_loop(intent);
                            } else {
                                notify_connection_state_change();
                            }

                            if let Some(callback) = registered_callback(&BECAME_INACTIVE_CALLBACK) {
                                callback();
                            }
                        }
                        // Emitted when the local Connect device becomes ACTIVE. Carries the
                        // session's connection id, but says nothing about network health -
                        // the session was already connected before activation.
                        Some(PlayerEvent::SessionConnected { connection_id, user_name }) => {
                            debug!("[WAKE +{}ms] became active (SessionConnected): connection_id={}, user={}", elapsed_since_wake_ms(), connection_id, user_name);
                            set_active_device(true);
                            with_connection(|c| c.session_connection_id = Some(connection_id));

                            // Notify connection state change
                            notify_connection_state_change();
                            if let Some(callback) = registered_callback(&BECAME_ACTIVE_CALLBACK) {
                                callback();
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
                            if let Some(callback) =
                                registered_callback(&SESSION_CLIENT_CHANGED_CALLBACK)
                            {
                                send_json(callback, &SessionClientInfo {
                                    client_id,
                                    client_name,
                                    client_brand_name,
                                    client_model_name,
                                });
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

    *SESSION.lock().unwrap() = Some(session.clone());
    *PLAYER_EVENT_TX.lock().unwrap() = Some(tx);

    spawn_cluster_listener(&session, current_generation)?;
    spawn_session_health_check(current_generation);

    match create_and_store_spirc(&session, &credentials, player, mixer).await {
        Ok(spirc) => {
            // Passive startup by default: do not take over the active device on launch.
            // Re-activate only when reconnecting from a previously-active local session.
            //
            // Recorded, not published — the single notify at the end of this function
            // covers it. set_active_device would publish here, before the rehydration
            // below, reopening the window this ordering exists to close.
            if activate_after_connect {
                match spirc.activate() {
                    Ok(_) => {
                        store_active_device(true);
                    }
                    Err(e) => debug!("Auto-activation failed: {:?}", e),
                }
            } else {
                store_active_device(false);
            }

            // Rehydrate before announcing readiness. The rebuilt Player has no track
            // loaded, and nothing else will load one: Spirc coming up and the device
            // becoming active only make it *available* to play, not playing. Without this
            // the session returns healthy and silent while Swift still shows the pre-outage
            // position, because IS_PLAYING and the position anchor survive the rebuild.
            //
            // This used to arm a five-second window waiting for a Paused event, on the
            // assumption that the track would load itself via transfer(None) — nothing in
            // this path ever called transfer(None), so the event never came.
            if resume_after_connect {
                let seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
                let result = resume_via_load(&spirc);
                debug!(
                    "[WAKE +{}ms] Rehydrate after reconnect: load result={}",
                    elapsed_since_wake_ms(),
                    result
                );

                if result == ERROR_NEEDS_REINIT {
                    // Closed command channel: this Spirc is already dead, so the session can
                    // never play. Nothing to roll back — success is committed below, after
                    // this point, so the connection state still reads disconnected.
                    return Err("Rehydration failed: Spirc command channel closed".to_string());
                }

                if result != 0 {
                    // Nothing to resume — no saved context or track URI. Reachable when an
                    // outage lands between a play command and the player events that record
                    // what is playing. The session itself is fine, so failing here would
                    // make every later attempt fail identically, forever.
                    debug!(
                        "[WAKE +{}ms] Rehydrate: nothing to resume (result={})",
                        elapsed_since_wake_ms(),
                        result
                    );
                } else if !wait_for_playing_event_async(seq_before, REHYDRATE_PLAYING_TIMEOUT).await
                {
                    // Spirc::load only queues a command, so a zero result means "accepted",
                    // not "playing". Waiting keeps Swift's Web API bootstrap out of the gap
                    // between the two. A timeout is not fatal: the load may still land, and
                    // tearing down an otherwise healthy session would be worse than
                    // announcing it late.
                    debug!(
                        "[WAKE +{}ms] Rehydrate: no Playing event within {:?}, publishing anyway",
                        elapsed_since_wake_ms(),
                        REHYDRATE_PLAYING_TIMEOUT
                    );
                }
            }

            // Committing late means this can be reached after something else took over —
            // spotifly_cleanup on logout, a manual retry, or sleep, any of which can land
            // during the rehydration wait above. Writing success then would resurrect a
            // dead session as healthy and stop the health check from recovering it.
            if !listener_may_act(current_generation, SESSION_GENERATION.load(Ordering::SeqCst))
                || teardown_in_progress()
            {
                return Err(format!(
                    "Initialization for generation {} was superseded before it completed",
                    current_generation
                ));
            }

            // Single commit-and-publish point: session up, device activated, playback
            // rehydrated. Recording success only here means a failure anywhere above
            // leaves the previous disconnected state untouched, and no snapshot in
            // between can announce a session that cannot yet play.
            with_connection(|c| {
                c.spirc_ready = true;
                c.session_connected = true;
                c.connected_since_ms = current_timestamp_ms();
                c.reconnect_attempt = 0;
                c.last_error = None;
            });
            notify_connection_state_change();
        }
        Err(e) => {
            // No fallback: every Spotifly control goes through Spirc, so a bare connected
            // Session is not a usable player. This used to call session.connect() and
            // return Ok, which reported success while leaving Swift with a player whose
            // every command would fail - and because initializeIfNeeded then refused to
            // retry, that state was permanent.
            return Err(format!("Spirc initialization failed: {}", e));
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

        if let Some(callback) = registered_callback(&VOLUME_CALLBACK) {
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
    i32::from(with_connection(|c| c.session_connected))
}

/// Helper to check if session is connected. Returns ERROR_NOT_CONNECTED if not.
///
/// Also detects zombie sessions: the Session object may have been invalidated
/// (e.g. server closed the connection overnight) without the event listener
/// ever firing SessionDisconnected (because the Spirc task was idle).
/// When detected, updates state and triggers reconnection proactively.
fn require_session_connected() -> Result<(), i32> {
    if !with_connection(|c| c.session_connected) {
        debug!("Command rejected: session not connected");
        return Err(ERROR_NOT_CONNECTED);
    }

    let session_invalid = SESSION
        .lock()
        .unwrap()
        .as_ref()
        .map_or(true, |s| s.is_invalid());

    if session_invalid {
        debug!("Detected zombie session (is_connected=true but Session is invalid)");
        mark_disconnected("Session expired");
        spawn_reconnection_loop(RecoveryIntent::capture());
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
        update_current_context_uri(context_uri);
    }

    let Some(callback) = registered_callback(&PLAYBACK_STATE_CALLBACK) else {
        debug!("No playback state callback registered, skipping update");
        return;
    };

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
    update_playback_options(shuffle, repeat_track, repeat_context);

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

    send_json(callback, &update);
}

/// Send playback state update from local player events (Playing, Paused)
/// This is used when Spotifly is the active device - state changes happen locally
/// and don't come through Mercury cluster updates.
fn send_local_playback_state(is_playing: bool, position_ms: u32) {
    debug!(
        "send_local_playback_state called: is_playing={}, position_ms={}",
        is_playing, position_ms
    );

    let Some(callback) = registered_callback(&PLAYBACK_STATE_CALLBACK) else {
        return;
    };

    // Get track URI from local state
    let track_uri = CURRENT_TRACK_URI
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_default();

    // Get duration from local state
    let duration_ms = CURRENT_DURATION_MS.load(Ordering::SeqCst);
    let (shuffle, repeat_track, repeat_context) = current_playback_options();

    let update = PlaybackStateUpdate {
        is_playing,
        is_paused: !is_playing,
        track_uri,
        position_ms: position_ms as i64,
        duration_ms: duration_ms as i64,
        shuffle,
        repeat_track,
        repeat_context,
        timestamp_ms: current_timestamp_ms() as i64,
    };

    debug!(
        "Local PlaybackState: playing={}, paused={}, position={}ms, duration={}ms, shuffle={}, repeat_track={}, repeat_context={}",
        update.is_playing,
        update.is_paused,
        update.position_ms,
        update.duration_ms,
        update.shuffle,
        update.repeat_track,
        update.repeat_context
    );

    send_json(callback, &update);
}

/// Converts a Connect-state track into a queue item.
///
/// Metadata is left empty on purpose: Swift resolves it from the AppStore by URI, so
/// carrying names and artwork across the FFI boundary would just duplicate it.
fn to_queue_item(track: &ProvidedTrack) -> QueueItem {
    QueueItem {
        uri: track.uri.clone(),
        name: String::new(),
        artist: String::new(),
        image_url: String::new(),
        duration_ms: 0,
        album_name: String::new(),
        provider: track.provider.clone(),
    }
}

/// Collects the playable tracks of one queue side, stopping at the first delimiter.
///
/// `spotify:delimiter` marks the boundary of what the user actually queued: after it in
/// next_tracks comes Spotify's autoplay continuation, and in prev_tracks it marks the
/// start of the context. Showing either as part of the queue would present tracks the
/// user never chose.
fn collect_queue_items(tracks: &[ProvidedTrack], side: &str) -> Vec<QueueItem> {
    let mut items = Vec::new();

    for (i, track) in tracks.iter().enumerate() {
        if i < 3 || !track.uri.starts_with("spotify:track:") {
            debug!(
                "{} track[{}] uri='{}' provider='{}'",
                side, i, track.uri, track.provider
            );
        }

        if track.uri == "spotify:delimiter" {
            debug!(
                "Stopping {} at delimiter (index {}), hiding {} tracks",
                side,
                i,
                tracks.len() - i - 1
            );
            break;
        }

        if track.uri.starts_with("spotify:track:") {
            items.push(to_queue_item(track));
        }
    }

    items
}

fn process_and_send_queue(player_state: PlayerState) {
    debug!("process_and_send_queue called");

    // Log context URI for queue processing too
    if !player_state.context_uri.is_empty() {
        debug!("Queue context URI: {}", player_state.context_uri);
        update_current_context_uri(&player_state.context_uri);
    }

    let Some(callback) = registered_callback(&QUEUE_CALLBACK) else {
        debug!("No callback registered, skipping queue update");
        return;
    };

    let current_track = player_state.track.into_option().and_then(|t| {
        debug!("current track[0] uri='{}' provider='{}'", t.uri, t.provider);
        if t.uri.starts_with("spotify:track:") {
            Some(to_queue_item(&t))
        } else {
            None
        }
    });
    let next_tracks = collect_queue_items(&player_state.next_tracks, "next");
    let prev_tracks = collect_queue_items(&player_state.prev_tracks, "prev");

    debug!(
        "Queue counts: current={}, next={}, prev={}",
        if current_track.is_some() { 1 } else { 0 },
        next_tracks.len(),
        prev_tracks.len()
    );

    send_json(
        callback,
        &QueueState {
            track: current_track,
            next_tracks,
            prev_tracks,
        },
    );
}

/// Helper to ensure the device is active before loading content.
/// If not active, activates via Spirc directly (no spclient HTTP needed).
/// Returns Ok(()) if ready to load, Err(i32) with error code if activation failed.
fn ensure_active_for_playback(spirc: &Arc<Spirc>) -> Result<(), i32> {
    if !is_active_device() {
        debug!("Device not active, activating via spirc.activate()");
        match spirc.activate() {
            Ok(_) => {
                debug!("Activate succeeded");
                set_active_device(true);
            }
            Err(_e) => {
                debug!("Activate failed: {:?}", _e);
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
    let Some(track_uris_str) = (unsafe { c_string_arg(track_uris_json) }) else {
        debug!("Play tracks error: track_uris_json is null or not valid UTF-8");
        return -1;
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
                    set_active_device(true);
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
    let Some(input_str) = (unsafe { c_string_arg(uri_or_url) }) else {
        debug!("Play error: uri_or_url is null or not valid UTF-8");
        return -1;
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
                    set_active_device(true);
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
    // IS_PLAYING is cleared here rather than left to the event stream: the user can pause
    // while a track is still loading, and in that case PlayerEvent::Playing never fires,
    // so there is no playing-to-paused transition for the listener to report.
    spirc_command("Pause", |spirc| {
        spirc.pause()?;
        IS_PLAYING.store(false, Ordering::SeqCst);
        Ok(())
    })
}

/// Clears any buffered audio samples.
/// The Swift-side callback handles the flush synchronously before returning.
/// Note: spotifly_disconnect() already handles this internally.
#[no_mangle]
pub extern "C" fn spotifly_clear_audio_buffer() {
    debug!("spotifly_clear_audio_buffer called");
    proxy_sink::ProxySink::clear_buffer();
}

fn wait_for_playing_event(previous_seq: u64, timeout_ms: u64) -> bool {
    let start_ms = current_timestamp_ms();
    loop {
        if PLAYING_EVENT_SEQ.load(Ordering::SeqCst) > previous_seq {
            return true;
        }
        if current_timestamp_ms().saturating_sub(start_ms) >= timeout_ms {
            return false;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// How long rehydration waits for the Player to actually start before giving up on the
/// wait (not on the session). Observed load-to-playing is around a second.
const REHYDRATE_PLAYING_TIMEOUT: Duration = Duration::from_secs(3);

/// Waits for the Player to report playback, without parking a runtime worker.
///
/// The blocking twin above is fine in synchronous FFI entry points; this one runs inside
/// `init_player_async`, where a thread sleep would block a tokio worker thread.
async fn wait_for_playing_event_async(previous_seq: u64, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        if PLAYING_EVENT_SEQ.load(Ordering::SeqCst) > previous_seq {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    PLAYING_EVENT_SEQ.load(Ordering::SeqCst) > previous_seq
}

fn resume_via_load(spirc: &Arc<Spirc>) -> i32 {
    let position_ms = POSITION_MS.load(Ordering::SeqCst);
    let context_uri = CURRENT_CONTEXT_URI.lock().unwrap().clone();
    let current_track_uri = CURRENT_TRACK_URI.lock().unwrap().clone();

    if let Some(context_uri) = context_uri.filter(|uri| !uri.is_empty()) {
        let playing_track = current_track_uri.clone().map(PlayingTrack::Uri);
        debug!(
            "Resume fallback: loading context {} at {}ms (track hint: {:?})",
            context_uri, position_ms, playing_track
        );

        let load_request = LoadRequest::from_context_uri(
            context_uri,
            LoadRequestOptions {
                start_playing: true,
                seek_to: position_ms,
                playing_track,
                ..Default::default()
            },
        );

        match spirc.load(load_request) {
            Ok(_) => {
                set_active_device(true);
                return 0;
            }
            Err(e) => {
                debug!("Resume fallback context load failed: {:?}", e);
                if is_channel_closed_error(&e) {
                    return ERROR_NEEDS_REINIT;
                }
            }
        }
    }

    if let Some(track_uri) = current_track_uri.filter(|uri| !uri.is_empty()) {
        debug!(
            "Resume fallback: loading single track {} at {}ms",
            track_uri, position_ms
        );
        let load_request = LoadRequest::from_tracks(
            vec![track_uri],
            LoadRequestOptions {
                start_playing: true,
                seek_to: position_ms,
                ..Default::default()
            },
        );

        match spirc.load(load_request) {
            Ok(_) => {
                set_active_device(true);
                return 0;
            }
            Err(e) => {
                debug!("Resume fallback track load failed: {:?}", e);
                if is_channel_closed_error(&e) {
                    return ERROR_NEEDS_REINIT;
                }
            }
        }
    }

    ERROR_GENERAL
}

/// Resumes playback.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_resume() -> i32 {
    debug!("spotifly_resume called");
    if let Err(e) = require_session_connected() {
        return e;
    }

    if IS_PLAYING.load(Ordering::SeqCst) {
        return 0;
    }

    let spirc = {
        let spirc_guard = SPIRC.lock().unwrap();
        spirc_guard.as_ref().cloned()
    };

    match spirc {
        Some(spirc) => {
            let play_seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
            match spirc.play() {
                Ok(_) => {
                    if wait_for_playing_event(play_seq_before, 500) {
                        return 0;
                    }

                    debug!(
                        "Resume play() produced no Playing event within timeout; attempting load fallback"
                    );
                    let fallback_seq_before = PLAYING_EVENT_SEQ.load(Ordering::SeqCst);
                    let load_result = resume_via_load(&spirc);
                    if load_result != 0 {
                        return load_result;
                    }

                    if wait_for_playing_event(fallback_seq_before, 2000) {
                        0
                    } else {
                        debug!("Resume fallback load produced no Playing event within timeout");
                        ERROR_GENERAL
                    }
                }
                Err(e) => {
                    debug!("Resume error: {:?}", e);
                    if is_channel_closed_error(&e) {
                        ERROR_NEEDS_REINIT
                    } else {
                        ERROR_GENERAL
                    }
                }
            }
        }
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
    // Stops at the Player rather than through Spirc: this is a local teardown of
    // playback, not a Connect command.
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

    // Invalidate the current generation first, so anything already in flight — most
    // importantly a reconnect loop sleeping between attempts — sees that what it was
    // recovering no longer exists and abandons instead of rebuilding over the teardown.
    let invalidated = SESSION_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    debug!("spotifly_cleanup invalidated generation, now {}", invalidated);

    // Signal event listener to stop
    if let Some(tx) = PLAYER_EVENT_TX.lock().unwrap().take() {
        let _ = tx.send(());
    }

    // Shutdown Spirc first - this terminates the spirc_task and closes the dealer
    shutdown_spirc("spotifly_cleanup");

    // Now clear Spirc reference
    *SPIRC.lock().unwrap() = None;
    // Clear player (see do_reconnect_cleanup for why Swift is told first)
    proxy_sink::ProxySink::notify_player_gone();
    *PLAYER.lock().unwrap() = None;

    // Clear mixer
    *MIXER.lock().unwrap() = None;

    // Clear session
    *SESSION.lock().unwrap() = None;

    // Reset state flags
    IS_PLAYING.store(false, Ordering::SeqCst);
    set_active_device(false);
    SHUFFLE_STATE.store(false, Ordering::SeqCst);
    REPEAT_TRACK_STATE.store(false, Ordering::SeqCst);
    REPEAT_CONTEXT_STATE.store(false, Ordering::SeqCst);
    POSITION_MS.store(0, Ordering::SeqCst);
    LAST_VOLUME.store(0, Ordering::SeqCst);
    LAST_ACTIVE_DEVICE_ID.lock().unwrap().clear();

    // Reset the connection snapshot: not ready, not connected, no device ID.
    // reconnect_attempt is deliberately preserved - it drives exponential backoff and
    // is only reset on a successful connect (in the SessionConnected handler).
    with_connection(|c| {
        c.spirc_ready = false;
        c.session_connected = false;
        c.session_connection_id = None;
        c.device_id = None;
        c.connected_since_ms = 0;
    });

    // Notify connection state change
    notify_connection_state_change();

    debug!("spotifly_cleanup complete - ready for reinitialization");
}

/// Returns 1 if currently playing, 0 otherwise.
#[no_mangle]
pub extern "C" fn spotifly_is_playing() -> i32 {
    i32::from(IS_PLAYING.load(Ordering::SeqCst))
}

/// Returns 1 if this device is the active Spotify Connect device, 0 otherwise.
/// When not active, playback controls should use Web API instead of Spirc.
#[no_mangle]
pub extern "C" fn spotifly_is_active_device() -> i32 {
    i32::from(is_active_device())
}

/// Returns the last position reported by the Player.
///
/// Swift owns display interpolation. Interpolating here as well used to add up to five
/// seconds after Player events stopped, while reconnect rehydration correctly resumed from
/// this raw position. The two clocks therefore produced an exact five-second snap backwards.
fn current_position_ms() -> u32 {
    POSITION_MS.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn spotifly_get_position_ms() -> u32 {
    current_position_ms()
}

/// Skips to the next track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_next() -> i32 {
    debug!("spotifly_next called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Next", |spirc| spirc.next())
}

/// Skips to the previous track in the queue.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_previous() -> i32 {
    debug!("spotifly_previous called");
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Previous", |spirc| spirc.prev())
}

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_seek(position_ms: u32) -> i32 {
    debug!("spotifly_seek called: {}ms", position_ms);
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Seek", |spirc| spirc.set_position_ms(position_ms))
}

/// Async core of radio playback. Safe to call from both sync (via block_on) and async contexts.
async fn play_radio_async(uri_str: &str) -> i32 {
    if let Err(e) = require_session_connected() {
        return e;
    }

    let session = {
        let guard = SESSION.lock().unwrap();
        match guard.as_ref() {
            Some(s) => s.clone(),
            None => {
                debug!("Play radio error: session not initialized");
                return -1;
            }
        }
    };

    // Resolve the radio playlist URI
    let playlist_uri: Result<String, String> = async {
        let spotify_uri = parse_spotify_uri(uri_str)?;

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
    }
    .await;

    let playlist_uri = match playlist_uri {
        Ok(uri) => uri,
        Err(_e) => {
            debug!("Play radio error: {}", _e);
            return -1;
        }
    };

    let current_track_uri = CURRENT_TRACK_URI.lock().unwrap().clone();
    let seek_to = if current_track_uri.as_deref() == Some(uri_str) {
        current_position_ms()
    } else {
        0
    };

    debug!("Loading radio playlist: {} at {}ms", playlist_uri, seek_to);

    let spirc_guard = SPIRC.lock().unwrap();
    match spirc_guard.as_ref() {
        Some(spirc) => {
            if let Err(e) = ensure_active_for_playback(spirc) {
                return e;
            }

            let load_request = LoadRequest::from_context_uri(
                playlist_uri.clone(),
                LoadRequestOptions {
                    start_playing: true,
                    seek_to,
                    playing_track: Some(PlayingTrack::Uri(uri_str.to_string())),
                    ..Default::default()
                },
            );
            match spirc.load(load_request) {
                Ok(_) => {
                    set_active_device(true);
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

/// Plays radio for a seed track.
/// Gets the radio playlist URI and loads it directly via Spirc.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_play_radio(track_uri: *const c_char) -> i32 {
    let Some(uri_str) = (unsafe { c_string_arg(track_uri) }) else {
        debug!("Play radio error: track_uri is null or not valid UTF-8");
        return -1;
    };

    debug!("spotifly_play_radio called: {}", uri_str);

    RUNTIME.block_on(play_radio_async(&uri_str))
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_set_volume(volume: u16) -> i32 {
    debug!("spotifly_set_volume called: {}", volume);
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Set volume", |spirc| spirc.set_volume(volume))
}

/// Sets shuffle mode on the current playback context.
/// Returns 0 on success, -1 on error, -2 if channel closed (needs reinit).
#[no_mangle]
pub extern "C" fn spotifly_set_shuffle(enabled: bool) -> i32 {
    debug!("spotifly_set_shuffle called: {}", enabled);
    if let Err(e) = require_session_connected() {
        return e;
    }
    spirc_command("Set shuffle", |spirc| spirc.shuffle(enabled))
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
    let Some(to_device_str) = (unsafe { c_string_arg(to_device_id) }) else {
        debug!("Transfer playback error: to_device_id is null or not valid UTF-8");
        return -1;
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

    let from_device_id = match current_device_id() {
        Some(id) => id,
        None => {
            debug!("Transfer playback error: device ID not initialized");
            return -1;
        }
    };

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
            set_active_device(false);
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
    i32::from(with_connection(|c| c.spirc_ready))
}

/// Adds an item to the queue.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_add_to_queue(uri: *const c_char) -> i32 {
    let Some(uri_str) = (unsafe { c_string_arg(uri) }) else {
        debug!("Add to queue error: uri is null or not valid UTF-8");
        return -1;
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

#[cfg(test)]
mod tests {
    use super::*;

    // Recovery must start from transport evidence, not from Connect activity. These cover
    // the distinction that P0.1 was about: librespot emits the same deactivation event for
    // an ordinary handoff and for an unexpected Spirc shutdown.

    #[test]
    fn deactivation_alone_does_not_recover() {
        // Another device took over. The session is fine — do not reconnect.
        assert!(!should_recover_after_deactivation(false, false));
    }

    #[test]
    fn deactivation_with_dead_session_recovers() {
        // librespot calls handle_disconnect on unexpected Spirc shutdown; the cluster
        // listener can miss that while the dealer stream is still open.
        assert!(should_recover_after_deactivation(true, false));
    }

    #[test]
    fn deactivation_during_teardown_never_recovers() {
        // Sleep and shutdown disconnect on purpose; recovering would fight them.
        assert!(!should_recover_after_deactivation(true, true));
        assert!(!should_recover_after_deactivation(false, true));
    }

    // A listener or loop belonging to a replaced session must not act. Before the rewrite
    // this could not be expressed: one event listener survived across sessions, so its
    // generation was rewritten in place and the staleness check compared two values that
    // were always equal.

    #[test]
    fn a_superseded_listener_is_rejected() {
        // The replacement is installed while the old listener is still draining.
        assert!(!listener_may_act(3, 4));
    }

    #[test]
    fn the_current_listener_acts() {
        assert!(listener_may_act(4, 4));
    }

    #[test]
    fn a_reconnect_loop_abandons_after_its_generation_moves() {
        // A restart landed while the loop slept between attempts; rebuilding now would
        // replace a healthy new session with one built from a stale token.
        assert!(!reconnect_may_proceed(2, 3, false));
    }

    #[test]
    fn a_reconnect_loop_abandons_during_teardown() {
        assert!(!reconnect_may_proceed(2, 2, true));
    }

    #[test]
    fn a_reconnect_loop_does_not_abandon_because_of_its_own_rebuild() {
        // Regression: each attempt calls init_player_async, which bumps the generation
        // before it can fail. Comparing against the value captured at loop start made the
        // loop read its own rebuild as a foreign supersede and give up after one attempt,
        // killing the remaining nine backoff retries — and with the Player already torn
        // down by the preceding cleanup, playback stayed dead for the whole outage.
        let mut recovering = 2;
        let after_own_failed_attempt = 3; // init_player_async bumped it, then errored
        assert!(!reconnect_may_proceed(
            recovering,
            after_own_failed_attempt,
            false
        ));

        // Adopting the generation our own attempt produced is what keeps the loop alive.
        recovering = after_own_failed_attempt;
        assert!(reconnect_may_proceed(
            recovering,
            after_own_failed_attempt,
            false
        ));
    }

    #[test]
    fn a_reconnect_loop_still_abandons_on_a_foreign_rebuild() {
        // Adopting our own bump must not blind the loop to someone else's.
        let recovering = 3; // adopted after our own attempt
        assert!(!reconnect_may_proceed(recovering, 4, false));
    }

    #[test]
    fn a_reconnect_loop_proceeds_for_its_own_generation() {
        assert!(reconnect_may_proceed(2, 2, false));
    }

    // The periodic health check is the only thing watching while Spotifly is idle, so its
    // trigger has to cover more than a session that reports itself invalid.

    // Only local playback is rehydrated, and the intent has to be captured before the
    // disconnect handling clears it.

    #[test]
    fn local_playback_is_resumed() {
        assert!(RecoveryIntent { was_playing: true, was_active: true }.should_resume());
    }

    #[test]
    fn remote_playback_is_left_alone() {
        // Another device is still playing; taking over would steal it from the user.
        assert!(!RecoveryIntent { was_playing: true, was_active: false }.should_resume());
    }

    #[test]
    fn a_paused_local_player_is_not_resumed() {
        assert!(!RecoveryIntent { was_playing: false, was_active: true }.should_resume());
    }

    #[test]
    fn health_check_recovers_a_dead_session() {
        assert!(health_check_should_recover(true, false, false, false));
    }

    #[test]
    fn health_check_recovers_a_session_that_never_connected() {
        // Regression: Session::is_invalid is only set by shutdown(), so a session left
        // behind by a failed init reports valid forever. Before this, nothing retried —
        // the Swift watchdog used to paper over it by rebuilding every 120s, and removing
        // that watchdog exposed the gap at both startup and after a failed rebuild.
        assert!(health_check_should_recover(false, false, false, false));
    }

    #[test]
    fn health_check_leaves_a_healthy_session_alone() {
        assert!(!health_check_should_recover(false, true, false, false));
    }

    #[test]
    fn health_check_defers_to_a_running_reconnect() {
        // The loop is what fixes this; firing alongside it would just re-publish a
        // disconnected snapshot once a minute.
        assert!(!health_check_should_recover(true, false, true, false));
    }

    #[test]
    fn health_check_stays_out_of_a_teardown() {
        assert!(!health_check_should_recover(true, false, false, true));
    }

    #[test]
    fn only_the_current_cluster_listener_recovers() {
        assert!(should_recover_after_cluster_end(7, 7, false));
        // An older listener ending is the expected result of its session being replaced.
        assert!(!should_recover_after_cluster_end(6, 7, false));
        assert!(!should_recover_after_cluster_end(7, 7, true));
    }

    // Active-device state is derived from the cluster rather than inferred from whichever
    // command ran last (P1.3).

    #[test]
    fn cluster_naming_us_makes_us_active() {
        assert!(is_active_in_cluster("spotifly_1234", Some("spotifly_1234")));
    }

    #[test]
    fn cluster_naming_another_device_makes_us_inactive() {
        assert!(!is_active_in_cluster("phone-abc", Some("spotifly_1234")));
    }

    #[test]
    fn empty_active_device_clears_activity() {
        // "Nothing is playing anywhere" is a real state, not a missing value.
        assert!(!is_active_in_cluster("", Some("spotifly_1234")));
    }

    #[test]
    fn no_local_device_id_is_never_active() {
        assert!(!is_active_in_cluster("phone-abc", None));
        assert!(!is_active_in_cluster("", None));
    }
}
