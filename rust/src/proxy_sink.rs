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
const AUDIO_CONTROL_STOP: u8 = 0;
const AUDIO_CONTROL_START: u8 = 1;
const AUDIO_CONTROL_CLEAR: u8 = 2;

static AUDIO_DATA_CALLBACK: Lazy<Mutex<Option<AudioDataCallback>>> =
    Lazy::new(|| Mutex::new(None));

static AUDIO_CONTROL_CALLBACK: Lazy<Mutex<Option<AudioControlCallback>>> =
    Lazy::new(|| Mutex::new(None));

/// Register the audio data callback (called from lib.rs FFI)
pub fn register_audio_data_callback(callback: AudioDataCallback) {
    *AUDIO_DATA_CALLBACK.lock().unwrap() = Some(callback);
    debug!("ProxySink: Audio data callback registered");
}

/// Register the audio control callback (called from lib.rs FFI)
pub fn register_audio_control_callback(callback: AudioControlCallback) {
    *AUDIO_CONTROL_CALLBACK.lock().unwrap() = Some(callback);
    debug!("ProxySink: Audio control callback registered");
}

/// Send a control event to Swift.
/// Copies the callback ref before invoking to avoid holding the lock during the call.
fn send_control(event: u8) {
    let cb = {
        let guard = AUDIO_CONTROL_CALLBACK.lock().unwrap();
        *guard
    };
    if let Some(callback) = cb {
        callback(event);
    }
}

/// A Sink implementation that forwards audio to Swift via FFI callbacks.
/// Swift handles actual audio output using AVSampleBufferAudioRenderer,
/// enabling AirPlay support.
pub struct ProxySink;

impl ProxySink {
    /// Clear all buffered audio on the Swift side.
    /// The Swift callback handles the flush synchronously before returning.
    pub fn clear_buffer() {
        debug!("ProxySink: Sending clear command");
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

        let samples_f32: Vec<f32> = converter.f64_to_f32(samples).to_vec();

        // Copy callback ref before invoking — avoids holding lock during call to Swift
        let cb = {
            let guard = AUDIO_DATA_CALLBACK.lock().unwrap();
            *guard
        };
        if let Some(callback) = cb {
            callback(samples_f32.as_ptr(), samples_f32.len());
        }

        Ok(())
    }
}

/// Factory function to create a ProxySink
pub fn mk_proxy_sink(_device: Option<String>, _format: AudioFormat) -> Box<dyn Sink> {
    debug!("ProxySink: Created new instance");
    Box::new(ProxySink)
}
