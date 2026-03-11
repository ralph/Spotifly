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

#[test]
fn soft_reconnect_without_context_rehydration_requires_hard_fallback() {
    let seed = RecoverySeed {
        was_active: true,
        was_playing: true,
        current_track_uri: Some("spotify:track:abc".into()),
        current_context_uri: Some("spotify:playlist:def".into()),
        position_ms: 45_000,
        had_next_tracks: true,
    };

    let signals = RecoverySignals {
        got_fresh_context_for_epoch: false,
        got_fresh_queue_for_epoch: false,
        timed_out_waiting_for_rehydration: true,
        manual_reconnect_requested: false,
    };

    assert_eq!(
        recovery_action_after_soft_reconnect(&seed, &signals),
        RecoveryAction::HardReconnectAndReloadSeed
    );
}
