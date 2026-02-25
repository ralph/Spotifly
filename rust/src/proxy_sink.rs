//! Proxy Audio Sink
//!
//! A persistent audio sink that survives across Player instances.
//! This enables seamless reconnection without audio gaps by keeping
//! the underlying audio output stream alive on a dedicated thread.

use cpal::traits::{DeviceTrait, HostTrait};
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::config::AudioFormat;
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use log::{debug, error, info, warn};
use once_cell::sync::Lazy;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const SAMPLE_RATE: u32 = 44100;
const NUM_CHANNELS: u16 = 2;

/// Commands sent to the audio thread
enum AudioCommand {
    /// Write audio samples (already converted to f32)
    Write(Vec<f32>),
    /// Start/resume playback
    Start,
    /// Pause playback (keep stream alive)
    Stop,
    /// Clear all buffered audio (flush stale samples)
    Clear,
    /// Clear with acknowledgment (for synchronous clearing)
    ClearSync(std::sync::mpsc::SyncSender<()>),
    /// Shutdown the audio thread completely
    Shutdown,
}

/// State of the audio thread
struct AudioThreadState {
    command_tx: SyncSender<AudioCommand>,
    _thread_handle: JoinHandle<()>,
}

/// Global audio thread that persists across Player instances
static AUDIO_THREAD: Lazy<Arc<Mutex<Option<AudioThreadState>>>> =
    Lazy::new(|| Arc::new(Mutex::new(None)));

/// Spawn or get the audio thread
fn ensure_audio_thread() -> Result<SyncSender<AudioCommand>, SinkError> {
    let mut guard = AUDIO_THREAD.lock().unwrap();

    if let Some(state) = guard.as_ref() {
        // Thread already running, return the sender
        return Ok(state.command_tx.clone());
    }

    // Spawn new audio thread
    debug!("ProxySink: Spawning persistent audio thread");

    // Use a bounded channel with some buffer for backpressure
    let (tx, rx) = mpsc::sync_channel::<AudioCommand>(64);

    let thread_handle = thread::Builder::new()
        .name("spotifly-audio".to_string())
        .spawn(move || {
            audio_thread_main(rx);
        })
        .map_err(|e| {
            SinkError::ConnectionRefused(format!("Failed to spawn audio thread: {}", e))
        })?;

    let state = AudioThreadState {
        command_tx: tx.clone(),
        _thread_handle: thread_handle,
    };

    *guard = Some(state);
    debug!("ProxySink: Audio thread spawned successfully");

    Ok(tx)
}

/// Main function for the audio thread
fn audio_thread_main(rx: Receiver<AudioCommand>) {
    info!("ProxySink audio thread started");

    // Initialize audio output
    let host = cpal::default_host();
    let cpal_device = match host.default_output_device() {
        Some(d) => d,
        None => {
            error!("ProxySink: No audio output device available");
            return;
        }
    };

    if let Ok(name) = cpal_device.name() {
        info!("ProxySink: Using audio device: {}", name);
    }

    // Get device config
    let default_config = match cpal_device.default_output_config() {
        Ok(c) => c,
        Err(e) => {
            error!("ProxySink: Failed to get default config: {}", e);
            return;
        }
    };

    // Try to find stereo 44.1kHz config, fall back to default
    let config = cpal_device
        .supported_output_configs()
        .ok()
        .and_then(|mut cfgs| {
            cfgs.find(|c| c.channels() == NUM_CHANNELS as cpal::ChannelCount)
                .and_then(|c| {
                    c.try_with_sample_rate(cpal::SampleRate(SAMPLE_RATE))
                        .or_else(|| c.try_with_sample_rate(default_config.sample_rate()))
                })
        })
        .unwrap_or(default_config);

    debug!("ProxySink: Audio config: {:?}", config);

    // Create the output stream
    let mut stream = match rodio::OutputStreamBuilder::default()
        .with_device(cpal_device.clone())
        .with_config(&config.config())
        .with_sample_format(cpal::SampleFormat::F32)
        .open_stream()
    {
        Ok(s) => s,
        Err(e) => {
            warn!(
                "ProxySink: Failed to create exact stream, trying fallback: {}",
                e
            );
            match rodio::OutputStreamBuilder::from_device(cpal_device) {
                Ok(builder) => match builder.open_stream_or_fallback() {
                    Ok(s) => s,
                    Err(e) => {
                        error!("ProxySink: Failed to create fallback stream: {}", e);
                        return;
                    }
                },
                Err(e) => {
                    error!("ProxySink: Failed to create stream builder: {}", e);
                    return;
                }
            }
        }
    };

    stream.log_on_drop(false);
    let sink = rodio::Sink::connect_new(stream.mixer());

    info!("ProxySink: Audio output initialized, entering command loop");

    // Process commands
    loop {
        match rx.recv() {
            Ok(AudioCommand::Write(samples)) => {
                let source = rodio::buffer::SamplesBuffer::new(
                    NUM_CHANNELS as cpal::ChannelCount,
                    SAMPLE_RATE,
                    samples,
                );
                sink.append(source);

                // Backpressure: wait if buffer gets too full
                while sink.len() > 26 {
                    thread::sleep(Duration::from_millis(10));
                }
            }
            Ok(AudioCommand::Start) => {
                debug!("ProxySink: Start command received");
                sink.play();
            }
            Ok(AudioCommand::Stop) => {
                debug!("ProxySink: Stop command received");
                sink.pause();
            }
            Ok(AudioCommand::Clear) => {
                debug!(
                    "ProxySink: Clear command received, flushing {} buffered sources",
                    sink.len()
                );
                sink.clear();
            }
            Ok(AudioCommand::ClearSync(ack_tx)) => {
                debug!(
                    "ProxySink: ClearSync command received, flushing {} buffered sources",
                    sink.len()
                );
                sink.clear();
                let _ = ack_tx.send(()); // Acknowledge completion
            }
            Ok(AudioCommand::Shutdown) => {
                info!("ProxySink: Shutdown command received");
                break;
            }
            Err(_) => {
                // Channel closed, exit
                info!("ProxySink: Command channel closed, exiting");
                break;
            }
        }
    }

    info!("ProxySink: Audio thread exiting");
}

/// A Sink implementation that delegates to a persistent audio thread.
/// The underlying rodio OutputStream survives across Player instances,
/// enabling seamless audio during session reconnection.
pub struct ProxySink {
    command_tx: SyncSender<AudioCommand>,
    #[allow(dead_code)]
    format: AudioFormat,
}

impl ProxySink {
    pub fn new(format: AudioFormat) -> Result<Self, SinkError> {
        let command_tx = ensure_audio_thread()?;
        debug!(
            "ProxySink: Created new proxy instance (format: {:?})",
            format
        );
        Ok(Self { command_tx, format })
    }

    /// Shut down the persistent audio thread.
    /// Call this only when the app is quitting.
    #[allow(dead_code)]
    pub fn shutdown() {
        let mut guard = AUDIO_THREAD.lock().unwrap();
        if let Some(state) = guard.take() {
            debug!("ProxySink: Sending shutdown command");
            let _ = state.command_tx.send(AudioCommand::Shutdown);
            // Thread will exit when it processes the shutdown command
        }
    }

    /// Clear all buffered audio samples (async, non-blocking).
    /// Uses try_send to avoid blocking the main thread.
    #[allow(dead_code)]
    pub fn clear_buffer() {
        let guard = AUDIO_THREAD.lock().unwrap();
        if let Some(state) = guard.as_ref() {
            debug!("ProxySink: Sending clear command");
            match state.command_tx.try_send(AudioCommand::Clear) {
                Ok(_) => {}
                Err(std::sync::mpsc::TrySendError::Full(_)) => {
                    debug!("ProxySink: Clear command dropped (channel full)");
                }
                Err(std::sync::mpsc::TrySendError::Disconnected(_)) => {
                    debug!("ProxySink: Clear command dropped (channel disconnected)");
                }
            }
        }
    }

    /// Clear all buffered audio samples synchronously.
    /// Blocks until the audio thread has processed the clear command.
    /// Use this before sleep to ensure no stale audio plays on wake.
    pub fn clear_buffer_sync() {
        let guard = AUDIO_THREAD.lock().unwrap();
        if let Some(state) = guard.as_ref() {
            debug!("ProxySink: Sending synchronous clear command");
            let (ack_tx, ack_rx) = mpsc::sync_channel::<()>(1);
            match state.command_tx.send(AudioCommand::ClearSync(ack_tx)) {
                Ok(_) => {
                    // Wait for acknowledgment with timeout
                    match ack_rx.recv_timeout(Duration::from_millis(500)) {
                        Ok(_) => debug!("ProxySink: Clear completed"),
                        Err(_) => debug!("ProxySink: Clear acknowledgment timed out"),
                    }
                }
                Err(_) => {
                    debug!("ProxySink: Clear command failed (channel disconnected)");
                }
            }
        }
    }
}

impl Sink for ProxySink {
    fn start(&mut self) -> SinkResult<()> {
        self.command_tx
            .send(AudioCommand::Start)
            .map_err(|_| SinkError::NotConnected("Audio thread not running".to_string()))?;
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        self.command_tx
            .send(AudioCommand::Stop)
            .map_err(|_| SinkError::NotConnected("Audio thread not running".to_string()))?;
        Ok(())
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let samples = packet
            .samples()
            .map_err(|e| SinkError::OnWrite(format!("Failed to get samples: {}", e)))?;

        // Convert f64 samples to f32 (rodio's native format)
        let samples_f32: Vec<f32> = converter.f64_to_f32(samples).to_vec();

        // Send to audio thread
        self.command_tx
            .send(AudioCommand::Write(samples_f32))
            .map_err(|_| SinkError::NotConnected("Audio thread not running".to_string()))?;

        Ok(())
    }
}

/// Factory function to create a ProxySink
pub fn mk_proxy_sink(_device: Option<String>, format: AudioFormat) -> Box<dyn Sink> {
    match ProxySink::new(format) {
        Ok(sink) => Box::new(sink),
        Err(e) => {
            // Log error and panic - we can't recover from audio init failure
            panic!("Failed to create ProxySink: {}", e);
        }
    }
}
