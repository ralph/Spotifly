use librespot_connect::{ConnectConfig, Spirc};
use librespot_core::config::DeviceType;
use librespot_core::session::Session;
use librespot_core::SessionConfig;
use librespot_core::cache::Cache;
use librespot_core::SpotifyUri;
use librespot_metadata::{Album, Artist, Metadata, Playlist, Track};
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player, PlayerEvent};
use once_cell::sync::Lazy;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicU64, AtomicUsize, Ordering};
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
static PLAYER_EVENT_TX: Lazy<Mutex<Option<mpsc::UnboundedSender<()>>>> = Lazy::new(|| Mutex::new(None));

// Queue state
static QUEUE: Lazy<Mutex<Vec<QueueItem>>> = Lazy::new(|| Mutex::new(Vec::new()));
static CURRENT_INDEX: AtomicUsize = AtomicUsize::new(0);

// Position tracking - updated from player events
static POSITION_MS: AtomicU32 = AtomicU32::new(0);
static POSITION_TIMESTAMP_MS: AtomicU64 = AtomicU64::new(0);

// Playback settings (applied on player init)
// Bitrate: 0 = 96kbps, 1 = 160kbps (default), 2 = 320kbps
static BITRATE_SETTING: AtomicU8 = AtomicU8::new(1);
// Gapless playback: true by default (matches librespot default)
static GAPLESS_SETTING: AtomicBool = AtomicBool::new(true);

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

#[derive(Clone, serde::Serialize)]
struct QueueItem {
    uri: String,
    track_name: String,
    artist_name: String,
    album_art_url: String,
    duration_ms: u32,
    album_id: Option<String>,
    artist_id: Option<String>,
    external_url: Option<String>,
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
fn get_album_art_url(track: &Track) -> String {
    // Try to get largest album cover from track metadata
    track.album.covers.iter()
        .max_by_key(|img| img.width * img.height)
        .and_then(|img| {
            img.id.to_base16().ok().map(|file_id_hex| {
                format!("https://i.scdn.co/image/{}", file_id_hex)
            })
        })
        .unwrap_or_default()
}

// Helper function to extract album ID from track
fn get_album_id(track: &Track) -> Option<String> {
    Some(track.album.id.to_id().ok()?)
}

// Helper function to extract first artist ID from track
fn get_artist_id(track: &Track) -> Option<String> {
    track.artists.first()
        .and_then(|a| a.id.to_id().ok())
}

// Helper function to build external URL from track URI
fn get_external_url(uri: &str) -> Option<String> {
    // URI format: spotify:track:TRACKID
    let parts: Vec<&str> = uri.split(':').collect();
    if parts.len() == 3 && parts[1] == "track" {
        Some(format!("https://open.spotify.com/track/{}", parts[2]))
    } else {
        None
    }
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
            let uri_str = track_uri.to_string();
            let track_name = track.name.clone();
            let artist_name = track.artists.iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            let album_art_url = get_album_art_url(&track);
            let duration_ms = track.duration as u32;

            queue_items.push(QueueItem {
                uri: uri_str.clone(),
                track_name,
                artist_name,
                album_art_url,
                duration_ms,
                album_id: get_album_id(&track),
                artist_id: get_artist_id(&track),
                external_url: get_external_url(&uri_str),
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
                let uri_str = track_uri.to_string();
                let track_name = track.name.clone();
                let artist_name = track.artists.iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                let album_art_url = get_album_art_url(&track);
                let duration_ms = track.duration as u32;

                queue_items.push(QueueItem {
                    uri: uri_str.clone(),
                    track_name,
                    artist_name,
                    album_art_url,
                    duration_ms,
                    album_id: get_album_id(&track),
                    artist_id: get_artist_id(&track),
                    external_url: get_external_url(&uri_str),
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
            let uri_str = track_uri.to_string();
            let track_name = track.name.clone();
            let artist_name = track.artists.iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            let album_art_url = get_album_art_url(&track);
            let duration_ms = track.duration as u32;

            queue_items.push(QueueItem {
                uri: uri_str.clone(),
                track_name,
                artist_name,
                album_art_url,
                duration_ms,
                album_id: get_album_id(&track),
                artist_id: get_artist_id(&track),
                external_url: get_external_url(&uri_str),
            });
        }
    }

    Ok(queue_items)
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

    let bitrate_kbps = match bitrate_setting {
        0 => 96,
        2 => 320,
        _ => 160,
    };
    println!("[Spotifly] Player initialized: bitrate={}kbps, gapless={}", bitrate_kbps, gapless);

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
                            update_position(position_ms);
                        }
                        Some(PlayerEvent::Paused { position_ms, .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
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
                            update_position(0);
                        }
                        Some(PlayerEvent::EndOfTrack { .. }) => {
                            IS_PLAYING.store(false, Ordering::SeqCst);
                            update_position(0);
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

    // Store session, player, mixer, and event channel first
    // This ensures basic playback works even if Spirc initialization fails
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

    // Create Spirc for Spotify Connect support (makes this app appear as a Connect device)
    // This is optional - if it fails, basic playback still works
    let connect_config = ConnectConfig {
        name: "Spotifly".to_string(),
        device_type: DeviceType::Computer,
        initial_volume: 65535 / 2, // 50% volume
        ..Default::default()
    };

    // Create credentials from access token for Spirc
    let spirc_credentials = librespot_core::authentication::Credentials::with_access_token(access_token);

    match Spirc::new(
        connect_config,
        session,
        spirc_credentials,
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
        }
        Err(e) => {
            // Spirc failed but basic playback still works
            eprintln!("Spirc init warning (Connect won't be available): {:?}", e);
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
    if track_uris_json.is_null() {
        eprintln!("Play tracks error: track_uris_json is null");
        return -1;
    }

    let track_uris_str = unsafe {
        match CStr::from_ptr(track_uris_json).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Play tracks error: invalid track_uris_json string");
                return -1;
            }
        }
    };

    // Parse JSON array of track URIs
    let track_uris: Vec<String> = match serde_json::from_str(&track_uris_str) {
        Ok(uris) => uris,
        Err(e) => {
            eprintln!("Play tracks error: failed to parse JSON: {:?}", e);
            return -1;
        }
    };

    if track_uris.is_empty() {
        eprintln!("Play tracks error: empty track URIs array");
        return -1;
    }

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Play tracks error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            eprintln!("Play tracks error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        let mut queue_items = Vec::new();

        // Load metadata for all tracks
        for uri_str in &track_uris {
            let spotify_uri = parse_spotify_uri(uri_str)?;

            match spotify_uri {
                SpotifyUri::Track { .. } => {
                    let track = Track::get(&session, &spotify_uri).await
                        .map_err(|e| format!("Failed to load track {}: {:?}", uri_str, e))?;

                    let track_name = track.name.clone();
                    let artist_name = track.artists.iter()
                        .map(|a| a.name.clone())
                        .collect::<Vec<_>>()
                        .join(", ");
                    let album_art_url = get_album_art_url(&track);
                    let duration_ms = track.duration as u32;

                    let queue_item = QueueItem {
                        uri: uri_str.clone(),
                        track_name,
                        artist_name,
                        album_art_url,
                        duration_ms,
                        album_id: get_album_id(&track),
                        artist_id: get_artist_id(&track),
                        external_url: get_external_url(&uri_str),
                    };

                    queue_items.push(queue_item);
                }
                _ => {
                    return Err(format!("Invalid track URI: {}", uri_str));
                }
            }
        }

        if queue_items.is_empty() {
            return Err("No valid tracks loaded".to_string());
        }

        // Update queue
        let mut queue_guard = QUEUE.lock().unwrap();
        queue_guard.clear();
        queue_guard.extend(queue_items);
        drop(queue_guard);

        CURRENT_INDEX.store(0, Ordering::SeqCst);

        // Load and play first track
        let first_uri = parse_spotify_uri(&track_uris[0])?;
        player.load(first_uri, true, 0);

        Ok(())
    });

    match result {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("Play tracks error: {}", e);
            -1
        }
    }
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
                let artist_name = track.artists.iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                let album_art_url = get_album_art_url(&track);
                let duration_ms = track.duration as u32;

                let queue_item = QueueItem {
                    uri: uri_str.clone(),
                    track_name,
                    artist_name,
                    album_art_url,
                    duration_ms,
                    album_id: get_album_id(&track),
                    artist_id: get_artist_id(&track),
                    external_url: get_external_url(&uri_str),
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

/// Seeks to the given position in milliseconds.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_seek(position_ms: u32) -> i32 {
    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Seek error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    player.seek(position_ms);
    0
}

/// Jumps to a specific track in the queue by index and starts playing.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_jump_to_index(index: usize) -> i32 {
    let queue_guard = QUEUE.lock().unwrap();

    if index >= queue_guard.len() {
        eprintln!("Jump error: index {} out of bounds (queue length: {})", index, queue_guard.len());
        drop(queue_guard);
        return -1;
    }

    let target_track = queue_guard[index].clone();
    drop(queue_guard);

    CURRENT_INDEX.store(index, Ordering::SeqCst);

    let player_guard = PLAYER.lock().unwrap();
    let player = match player_guard.as_ref() {
        Some(p) => Arc::clone(p),
        None => {
            eprintln!("Jump error: player not initialized");
            return -1;
        }
    };
    drop(player_guard);

    let result = RUNTIME.block_on(async {
        parse_spotify_uri(&target_track.uri)
    });

    match result {
        Ok(uri) => {
            player.load(uri, true, 0);
            IS_PLAYING.store(true, Ordering::SeqCst);
            0
        }
        Err(e) => {
            eprintln!("Jump error: {}", e);
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

/// Returns the track duration in milliseconds at the given index.
/// Returns 0 if index is out of bounds.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_duration_ms(index: usize) -> u32 {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return 0;
    }
    queue_guard[index].duration_ms
}

/// Gets the album ID for a queue item by index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or album ID is not available.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_album_id(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match &queue_guard[index].album_id {
        Some(album_id) => {
            match CString::new(album_id.clone()) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

/// Gets the artist ID for a queue item by index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or artist ID is not available.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_artist_id(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match &queue_guard[index].artist_id {
        Some(artist_id) => {
            match CString::new(artist_id.clone()) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

/// Gets the external URL for a queue item by index.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL if index is out of bounds or external URL is not available.
#[no_mangle]
pub extern "C" fn spotifly_get_queue_external_url(index: usize) -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();
    if index >= queue_guard.len() {
        return ptr::null_mut();
    }

    match &queue_guard[index].external_url {
        Some(external_url) => {
            match CString::new(external_url.clone()) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        None => ptr::null_mut(),
    }
}

/// Returns all queue items as a JSON string.
/// Caller must free the string with spotifly_free_string().
/// Returns NULL on error.
#[no_mangle]
pub extern "C" fn spotifly_get_all_queue_items() -> *mut c_char {
    let queue_guard = QUEUE.lock().unwrap();

    // Serialize the entire queue to JSON
    match serde_json::to_string(&*queue_guard) {
        Ok(json_string) => {
            match CString::new(json_string) {
                Ok(cstr) => cstr.into_raw(),
                Err(_) => ptr::null_mut(),
            }
        }
        Err(_) => ptr::null_mut(),
    }
}

/// Adds a track to the end of the current queue without clearing it.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_add_to_queue(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        eprintln!("Add to queue error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Add to queue error: invalid track_uri string");
                return -1;
            }
        }
    };

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            eprintln!("Add to queue error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        // Parse the URI
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        // Only support tracks for add to queue
        match spotify_uri {
            SpotifyUri::Track { .. } => {
                let track = Track::get(&session, &spotify_uri).await
                    .map_err(|e| format!("Failed to load track: {:?}", e))?;

                let track_name = track.name.clone();
                let artist_name = track.artists.iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                let album_art_url = get_album_art_url(&track);
                let duration_ms = track.duration as u32;

                let queue_item = QueueItem {
                    uri: uri_str.clone(),
                    track_name,
                    artist_name,
                    album_art_url,
                    duration_ms,
                    album_id: get_album_id(&track),
                    artist_id: get_artist_id(&track),
                    external_url: get_external_url(&uri_str),
                };

                // Add to queue instead of replacing
                let mut queue_guard = QUEUE.lock().unwrap();
                queue_guard.push(queue_item);
                drop(queue_guard);

                Ok(())
            }
            _ => {
                Err(format!("Only track URIs are supported for add to queue: {}", uri_str))
            }
        }
    });

    match result {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("Add to queue error: {}", e);
            -1
        }
    }
}

/// Adds a track to play next (after the currently playing track).
/// If nothing is playing, adds it to the queue.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_add_next_to_queue(track_uri: *const c_char) -> i32 {
    if track_uri.is_null() {
        eprintln!("Add next to queue error: track_uri is null");
        return -1;
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Add next to queue error: invalid track_uri string");
                return -1;
            }
        }
    };

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            eprintln!("Add next to queue error: session not initialized");
            return -1;
        }
    };
    drop(session_guard);

    let result: Result<(), String> = RUNTIME.block_on(async {
        // Parse the URI
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        // Only support tracks for add to queue
        match spotify_uri {
            SpotifyUri::Track { .. } => {
                let track = Track::get(&session, &spotify_uri).await
                    .map_err(|e| format!("Failed to load track: {:?}", e))?;

                let track_name = track.name.clone();
                let artist_name = track.artists.iter()
                    .map(|a| a.name.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                let album_art_url = get_album_art_url(&track);
                let duration_ms = track.duration as u32;

                let queue_item = QueueItem {
                    uri: uri_str.clone(),
                    track_name,
                    artist_name,
                    album_art_url,
                    duration_ms,
                    album_id: get_album_id(&track),
                    artist_id: get_artist_id(&track),
                    external_url: get_external_url(&uri_str),
                };

                // Insert after current index
                let mut queue_guard = QUEUE.lock().unwrap();
                let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

                // Insert at current_index + 1, or at the end if queue is empty
                let insert_position = if queue_guard.is_empty() {
                    0
                } else {
                    (current_idx + 1).min(queue_guard.len())
                };

                queue_guard.insert(insert_position, queue_item);
                drop(queue_guard);

                Ok(())
            }
            _ => {
                Err(format!("Only track URIs are supported for add next to queue: {}", uri_str))
            }
        }
    });

    match result {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("Add next to queue error: {}", e);
            -1
        }
    }
}

/// Removes a track from the queue at the given index.
/// Only allows removing tracks AFTER the current index (unplayed tracks).
/// Returns 0 on success, -1 on error or if trying to remove a played/playing track.
#[no_mangle]
pub extern "C" fn spotifly_remove_from_queue(index: usize) -> i32 {
    let mut queue_guard = QUEUE.lock().unwrap();
    let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

    // Validate index: must be after current track and within bounds
    if index <= current_idx || index >= queue_guard.len() {
        eprintln!(
            "Remove from queue error: invalid index {} (current: {}, len: {})",
            index,
            current_idx,
            queue_guard.len()
        );
        return -1;
    }

    queue_guard.remove(index);
    0
}

/// Moves a track from one position to another in the queue.
/// Only allows reordering tracks AFTER the current index (unplayed tracks).
/// Returns 0 on success, -1 on error or if trying to move played/playing tracks.
#[no_mangle]
pub extern "C" fn spotifly_move_queue_item(from_index: usize, to_index: usize) -> i32 {
    let mut queue_guard = QUEUE.lock().unwrap();
    let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

    // Validate indices: both must be after current track and within bounds
    if from_index <= current_idx
        || to_index <= current_idx
        || from_index >= queue_guard.len()
        || to_index >= queue_guard.len()
    {
        eprintln!(
            "Move queue item error: invalid indices from={} to={} (current: {}, len: {})",
            from_index,
            to_index,
            current_idx,
            queue_guard.len()
        );
        return -1;
    }

    if from_index == to_index {
        return 0; // No-op, success
    }

    let item = queue_guard.remove(from_index);
    queue_guard.insert(to_index, item);
    0
}

/// Clears all tracks after the currently playing track from the queue.
/// Keeps the currently playing track and all previously played tracks.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_clear_upcoming_queue() -> i32 {
    let mut queue_guard = QUEUE.lock().unwrap();
    let current_idx = CURRENT_INDEX.load(Ordering::SeqCst);

    // Truncate queue to current_idx + 1 (keep current and played)
    if current_idx + 1 < queue_guard.len() {
        queue_guard.truncate(current_idx + 1);
    }
    0
}

/// Gets radio tracks for a seed track and returns them as JSON.
/// Returns a JSON array of track URIs, or NULL on error.
/// Caller must free the string with spotifly_free_string().
#[no_mangle]
pub extern "C" fn spotifly_get_radio_tracks(track_uri: *const c_char) -> *mut c_char {
    if track_uri.is_null() {
        eprintln!("Get radio error: track_uri is null");
        return ptr::null_mut();
    }

    let uri_str = unsafe {
        match CStr::from_ptr(track_uri).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => {
                eprintln!("Get radio error: invalid track_uri string");
                return ptr::null_mut();
            }
        }
    };

    let session_guard = SESSION.lock().unwrap();
    let session = match session_guard.as_ref() {
        Some(s) => s.clone(),
        None => {
            eprintln!("Get radio error: session not initialized");
            return ptr::null_mut();
        }
    };
    drop(session_guard);

    let result: Result<Vec<String>, String> = RUNTIME.block_on(async {
        // Parse the URI
        let spotify_uri = parse_spotify_uri(&uri_str)?;

        // Get radio tracks from Spotify
        let response = session.spclient().get_radio_for_track(&spotify_uri).await
            .map_err(|e| format!("Failed to get radio: {:?}", e))?;

        // Parse the JSON response
        let json: serde_json::Value = serde_json::from_slice(&response)
            .map_err(|e| format!("Failed to parse radio response: {:?}", e))?;

        // The API returns a playlist URI in mediaItems, not individual tracks
        // Format: { "mediaItems": [{ "uri": "spotify:playlist:xxx" }] }
        let playlist_uri = json.get("mediaItems")
            .and_then(|items| items.as_array())
            .and_then(|items| items.first())
            .and_then(|item| item.get("uri"))
            .and_then(|u| u.as_str())
            .filter(|uri| uri.starts_with("spotify:playlist:"))
            .ok_or_else(|| "No radio playlist found in response".to_string())?;

        // Parse the playlist URI
        let playlist_spotify_uri = parse_spotify_uri(playlist_uri)?;

        // Load the playlist tracks
        let queue_items = load_playlist(&session, playlist_spotify_uri).await?;

        // Extract just the track URIs
        let track_uris: Vec<String> = queue_items.into_iter()
            .map(|item| item.uri)
            .collect();

        if track_uris.is_empty() {
            return Err("Radio playlist is empty".to_string());
        }

        Ok(track_uris)
    });

    match result {
        Ok(track_uris) => {
            match serde_json::to_string(&track_uris) {
                Ok(json_string) => {
                    match CString::new(json_string) {
                        Ok(cstr) => cstr.into_raw(),
                        Err(_) => ptr::null_mut(),
                    }
                }
                Err(_) => ptr::null_mut(),
            }
        }
        Err(e) => {
            eprintln!("Get radio error: {}", e);
            ptr::null_mut()
        }
    }
}

/// Sets the playback volume (0-65535).
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn spotifly_set_volume(volume: u16) -> i32 {
    let mixer_guard = MIXER.lock().unwrap();
    match mixer_guard.as_ref() {
        Some(mixer) => {
            mixer.set_volume(volume);
            0
        }
        None => {
            eprintln!("Set volume error: mixer not initialized");
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
        let kbps = match value { 0 => 96, 2 => 320, _ => 160 };
        println!("[Spotifly] Bitrate changed to {}kbps (restart playback to apply)", kbps);
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
        println!("[Spotifly] Gapless playback changed to {} (restart playback to apply)", enabled);
    }
}

/// Gets the current gapless playback setting.
#[no_mangle]
pub extern "C" fn spotifly_get_gapless() -> bool {
    GAPLESS_SETTING.load(Ordering::SeqCst)
}
