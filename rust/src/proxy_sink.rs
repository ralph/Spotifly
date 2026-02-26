//! Proxy Audio Sink
//!
//! Forwards decoded PCM audio from librespot to Swift via FFI callbacks.
//! Swift handles audio output using AVSampleBufferAudioRenderer for
//! AirPlay-compatible playback.

use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::AudioFormat;
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use log::debug;
use once_cell::sync::Lazy;
use std::sync::Mutex;

/// FFI callback for sending audio data to Swift.
/// Parameters: pointer to interleaved f32 samples (stereo, 44100Hz), number of f32 values.
type AudioDataCallback = extern "C" fn(*const f32, usize);

/// FFI callback for playback control events.
/// Parameter: 0 = stop, 1 = start/resume, 2 = clear/flush
type AudioControlCallback = extern "C" fn(u8);

/// Audio control event codes
pub const AUDIO_CONTROL_STOP: u8 = 0;
pub const AUDIO_CONTROL_START: u8 = 1;
pub const AUDIO_CONTROL_CLEAR: u8 = 2;

/// Registered callback from Swift for audio sample data
static AUDIO_DATA_CALLBACK: Lazy<Mutex<Option<AudioDataCallback>>> =
    Lazy::new(|| Mutex::new(None));

/// Registered callback from Swift for audio control events
static AUDIO_CONTROL_CALLBACK: Lazy<Mutex<Option<AudioControlCallback>>> =
    Lazy::new(|| Mutex::new(None));

/// Register the audio data callback (called from lib.rs FFI)
pub fn register_audio_data_callback(callback: AudioDataCallback) {
    let mut cb = AUDIO_DATA_CALLBACK.lock().unwrap();
    *cb = Some(callback);
    debug!("ProxySink: Audio data callback registered");
}

/// Register the audio control callback (called from lib.rs FFI)
pub fn register_audio_control_callback(callback: AudioControlCallback) {
    let mut cb = AUDIO_CONTROL_CALLBACK.lock().unwrap();
    *cb = Some(callback);
    debug!("ProxySink: Audio control callback registered");
}

/// Send a control event to Swift
fn send_control(event: u8) {
    let cb_guard = AUDIO_CONTROL_CALLBACK.lock().unwrap();
    if let Some(callback) = *cb_guard {
        let cb = callback;
        drop(cb_guard);
        cb(event);
    }
}

/// A Sink implementation that forwards audio to Swift via FFI callbacks.
/// Swift handles actual audio output using AVSampleBufferAudioRenderer,
/// enabling AirPlay support.
pub struct ProxySink {
    #[allow(dead_code)]
    format: AudioFormat,
}

impl ProxySink {
    pub fn new(format: AudioFormat) -> Result<Self, SinkError> {
        debug!(
            "ProxySink: Created new instance (format: {:?})",
            format
        );
        Ok(Self { format })
    }

    /// Shut down audio output.
    /// Call this only when the app is quitting.
    #[allow(dead_code)]
    pub fn shutdown() {
        debug!("ProxySink: Sending shutdown (stop)");
        send_control(AUDIO_CONTROL_STOP);
    }

    /// Clear all buffered audio samples (async, non-blocking).
    #[allow(dead_code)]
    pub fn clear_buffer() {
        debug!("ProxySink: Sending clear command");
        send_control(AUDIO_CONTROL_CLEAR);
    }

    /// Clear all buffered audio samples synchronously.
    /// The Swift callback handles the flush synchronously before returning.
    pub fn clear_buffer_sync() {
        debug!("ProxySink: Sending synchronous clear command");
        send_control(AUDIO_CONTROL_CLEAR);
    }
}

impl Sink for ProxySink {
    fn start(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Start");
        send_control(AUDIO_CONTROL_START);
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        debug!("ProxySink: Stop");
        send_control(AUDIO_CONTROL_STOP);
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let samples = packet
            .samples()
            .map_err(|e| SinkError::OnWrite(format!("Failed to get samples: {}", e)))?;

        // Convert f64 samples to f32
        let samples_f32: Vec<f32> = converter.f64_to_f32(samples).to_vec();

        // Send to Swift via FFI callback
        let cb_guard = AUDIO_DATA_CALLBACK.lock().unwrap();
        if let Some(callback) = *cb_guard {
            let cb = callback;
            drop(cb_guard);
            // This call may block if Swift's ring buffer is full (backpressure)
            cb(samples_f32.as_ptr(), samples_f32.len());
        }

        Ok(())
    }
}

/// Factory function to create a ProxySink
pub fn mk_proxy_sink(_device: Option<String>, format: AudioFormat) -> Box<dyn Sink> {
    match ProxySink::new(format) {
        Ok(sink) => Box::new(sink),
        Err(e) => {
            panic!("Failed to create ProxySink: {}", e);
        }
    }
}
