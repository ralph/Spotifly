use librespot_oauth::{OAuthClientBuilder, OAuthError};
use once_cell::sync::Lazy;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::Mutex;
use std::time::Instant;
use tokio::runtime::Runtime;

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

    let client = OAuthClientBuilder::new(client_id, redirect_uri, scopes)
        .open_in_browser()
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
