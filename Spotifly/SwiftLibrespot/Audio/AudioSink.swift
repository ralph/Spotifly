//
//  AudioSink.swift
//  SwiftLibrespot
//
//  The output stage of the audio pipeline: where decoded PCM goes to be played.
//

import Foundation

/// Receives interleaved Float32 PCM at a fixed stream format and plays it out.
///
/// The pipeline pushes decoded audio as fast as decoding allows; pacing is the
/// sink's job, via backpressure (`write` blocks once enough audio is buffered
/// ahead) rather than timers on the decode side.
///
/// Control mirrors librespot's sink semantics: `stop` freezes playout while
/// keeping whatever is buffered, so a resume continues from the same spot with
/// no audible gap in state; `flush` discards the buffer entirely.
///
/// `nonisolated`: implementations run wherever the decoder runs — never the
/// main actor.
nonisolated protocol AudioSink: AnyObject, Sendable {
    /// Number of frames actually played out since the most recent `start`.
    /// This is the audible playhead, not the amount written.
    var playedFramesSinceStart: Int64 { get }

    /// Writes interleaved samples. Blocks while the sink is sufficiently far
    /// ahead of real time — this is what throttles the decode loop.
    func write(samples: UnsafePointer<Float>, count: Int)

    /// Begins (or resumes) playout of buffered samples.
    func start()

    /// Freezes playout. Buffered samples are retained for a later `resume()`.
    func stop()

    /// Unfreezes playout of retained samples after a `stop()`, continuing from
    /// where it left off. Unlike `start()`, this must not discard anything.
    func resume()

    /// Discards all buffered samples and resets the playhead clock.
    func flush()

    /// Sets output gain (0…1), effective immediately.
    func setVolume(_ volume: Float)
}
