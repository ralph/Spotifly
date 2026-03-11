use super::*;
use std::sync::atomic::Ordering;

#[test]
fn cleanup_clears_cached_recovery_state() {
    CURRENT_DURATION_MS.store(123_000, Ordering::SeqCst);
    POSITION_MS.store(45_000, Ordering::SeqCst);
    POSITION_TIMESTAMP_MS.store(99_999, Ordering::SeqCst);
    RESUME_AFTER_RECONNECT_UNTIL_MS.store(999_999, Ordering::SeqCst);
    *CURRENT_TRACK_URI.lock().unwrap() = Some("spotify:track:abc".to_string());
    *CURRENT_CONTEXT_URI.lock().unwrap() = Some("spotify:playlist:def".to_string());

    spotifly_cleanup();

    assert_eq!(CURRENT_DURATION_MS.load(Ordering::SeqCst), 0);
    assert_eq!(POSITION_MS.load(Ordering::SeqCst), 0);
    assert_eq!(POSITION_TIMESTAMP_MS.load(Ordering::SeqCst), 0);
    assert_eq!(RESUME_AFTER_RECONNECT_UNTIL_MS.load(Ordering::SeqCst), 0);
    assert_eq!(*CURRENT_TRACK_URI.lock().unwrap(), None);
    assert_eq!(*CURRENT_CONTEXT_URI.lock().unwrap(), None);
}
