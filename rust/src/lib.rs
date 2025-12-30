use librespot_oauth::{OAuthClientBuilder, OAuthError};
use once_cell::sync::Lazy;
use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::Mutex;
use std::time::Instant;
use tokio::runtime::Runtime;

// Spotify's official client ID used by librespot
const SPOTIFY_CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const REDIRECT_URI: &str = "http://127.0.0.1:8888/callback";

// Global tokio runtime for async operations
static RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

// Thread-safe storage for OAuth result
static OAUTH_RESULT: Lazy<Mutex<Option<OAuthResult>>> = Lazy::new(|| Mutex::new(None));

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
#[no_mangle]
pub extern "C" fn spotifly_start_oauth() -> i32 {
    let result = RUNTIME.block_on(async {
        perform_oauth().await
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

async fn perform_oauth() -> Result<OAuthResult, OAuthError> {
    let scopes = vec![
        "user-read-private",
        "user-read-email",
        "streaming",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
    ];

    let client = OAuthClientBuilder::new(SPOTIFY_CLIENT_ID, REDIRECT_URI, scopes).build()?;

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
