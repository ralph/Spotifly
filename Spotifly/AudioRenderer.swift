//
//  AudioRenderer.swift
//  Spotifly
//
//  The audio output: decoded PCM into AVSampleBufferAudioRenderer, which plays
//  it on the Mac, on headphones and over AirPlay.
//

import AVFoundation
import CoreMedia
import Synchronization

/// Plays interleaved Float32 PCM through an `AVSampleBufferAudioRenderer` on
/// its own render synchronizer, fed through the renderer's receiver.
///
/// `enqueue` suspends until the renderer wants more, and that is all the
/// pacing there is. The renderer keeps one to two seconds queued and takes
/// half a second at a time, so a decoder awaiting it wakes about twice a
/// second; a paused renderer wants nothing, so the decoder waits out a pause
/// in the same call; and a flush, or cancelling the caller's task, returns it
/// at once. The ring buffer, write throttle and feed callback this replaced
/// are gone with the pre-macOS 27 API they worked around.
///
/// An actor because the renderer and its receiver are not `Sendable`. The
/// synchronizer is, which is what lets the playhead be read without awaiting.
actor AudioRenderer {
    nonisolated static let sampleRate = 44100
    nonisolated static let channelCount = 2

    /// The render clock: frames played since the last `restart`. Never
    /// replaced, so `playedFrames` can read it from anywhere.
    private nonisolated let synchronizer = AVSampleBufferRenderSynchronizer()
    private let renderer: AVSampleBufferAudioRenderer
    private let receiver: AVSampleBufferAudioRenderer.Receiver
    private let format: CMAudioFormatDescription

    /// Presentation time of the next buffer: frames enqueued since the last flush.
    private var nextPresentationTime = CMTime.zero

    /// Bumped by every flush, so an enqueue that was waiting across one does
    /// not advance the presentation time the flush has just reset.
    private var flushes = 0

    /// When the enqueue that is waiting now began to wait; see `isStalled`.
    private var waitingSince: ContinuousClock.Instant?

    /// The gain last asked for; see `setVolume`.
    private nonisolated let requestedVolume = Mutex<Float>(1)

    init() {
        let renderer = AVSampleBufferAudioRenderer()
        // The renderer spatializes only multichannel audio unless told
        // otherwise, and Spotify's is stereo. Allowing stereo makes Spatial
        // Audio on AirPods and similar headphones available to it; whether it
        // is used, and with or without head tracking, is the listener's choice
        // in Control Center.
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        self.renderer = renderer
        receiver = synchronizer.sampleBufferReceiver(adding: renderer)

        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * Self.channelCount)
        let description = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(Self.channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0,
        )
        do {
            format = try CMAudioFormatDescription(audioStreamBasicDescription: description)
        } catch {
            fatalError("AudioRenderer: no format description for 44.1 kHz stereo Float32: \(error)")
        }
        debugLog("AudioRenderer", "Initialized (44100Hz, 2ch, Float32)")
    }

    // MARK: - Feeding

    /// What became of a buffer handed to `enqueue`.
    enum Enqueued {
        case accepted
        /// Discarded by a flush, or the caller's task was cancelled.
        case flushed
        /// The output changed under the renderer — another device, AirPlay —
        /// and it dropped what it had queued. The caller has to fill it again
        /// from the playhead.
        case outputChanged
        case failed
    }

    /// Queues `frames` interleaved frames, suspending until the renderer wants
    /// them. The first buffer after a flush plays at clock time zero, and each
    /// one after it directly follows the one before.
    func enqueue(_ samples: Data, frames: Int) async -> Enqueued {
        guard !Task.isCancelled else { return .flushed }

        let buffer = CMReadySampleBuffer(
            audioDataBuffer: CMReadOnlyDataBlockBuffer(samples),
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: nextPresentationTime,
        )
        let flushesBefore = flushes

        let result: AVSampleBufferAudioRenderer.Receiver.EnqueueResult
        waitingSince = .now
        defer { waitingSince = nil }
        do {
            result = try await receiver.enqueue(CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(buffer))
        } catch {
            return .flushed
        }

        switch result {
        case .enqueued:
            if flushes == flushesBefore {
                nextPresentationTime = CMTimeAdd(
                    nextPresentationTime,
                    CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Self.sampleRate)),
                )
            }
            return .accepted
        case let .enqueuedWithSuggestedFlush(reasons):
            // How the renderer reports a change of its own output device. A
            // change of the system's default output, which is what picking
            // speakers or AirPlay in Control Center is, does not come this way:
            // see `isStalled`.
            debugLog("AudioRenderer", "Output changed: \(reasons)")
            return .outputChanged
        case .cancelledDueToFlush:
            return .flushed
        case let .cancelledDueToError(error):
            debugLog("AudioRenderer", "Enqueue failed: \(error)")
            return .failed
        @unknown default:
            return .failed
        }
    }

    // MARK: - Playback Control

    /// Discards everything queued and starts the clock again at zero, running
    /// or held. Held, the renderer still takes its first second or so of audio,
    /// so a paused track starts at once on `resume`.
    func restart(paused: Bool) {
        flush()
        synchronizer.setRate(paused ? 0 : 1, time: .zero)
        debugLog("AudioRenderer", paused ? "Restarted, held" : "Restarted")
    }

    /// Freezes playout, keeping what is queued; the clock holds its position.
    func pause() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
    }

    /// Continues from where `pause` left off.
    func resume() {
        synchronizer.setRate(1, time: synchronizer.currentTime())
    }

    /// Stops playout and discards what is queued.
    func stop() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
        flush()
    }

    private func flush() {
        receiver.flush()
        nextPresentationTime = .zero
        flushes += 1
    }

    /// Whether the renderer has stopped asking for audio it needs.
    ///
    /// When the system's default output changes, the renderer drops what it
    /// had queued and then never asks for more: the waiting `enqueue` does
    /// not return, no rendering event arrives, and the clock runs on over
    /// silence. Measured on macOS 27.0, switching between a display's speakers
    /// and the Mac's in Control Center, every time. It shows as an enqueue
    /// that has waited a while with next to nothing left queued — in normal
    /// playback the renderer asks again with about 0.9 s still queued — and
    /// the caller refills, which cancelling the stuck enqueue makes possible.
    /// Nothing detects it while nothing is enqueued, so a change after the
    /// last track's last buffer loses what was left of it.
    var isStalled: Bool {
        guard let waitingSince, synchronizer.rate > 0 else { return false }
        let queued = CMTimeSubtract(nextPresentationTime, synchronizer.currentTime()).seconds
        return queued < 0.25 && waitingSince.duration(to: .now) > .milliseconds(500)
    }

    /// Frames played out since the last `restart`, read off the render clock:
    /// the audible playhead, not what has been decoded or queued.
    nonisolated var playedFrames: Int64 {
        let seconds = synchronizer.currentTime().seconds
        return seconds.isFinite && seconds > 0 ? Int64(seconds * Double(Self.sampleRate)) : 0
    }

    // MARK: - Volume

    /// Sets the output gain (0…1). There is no mixer stage anywhere else, so
    /// this is where playback volume is applied: at the output, taking effect
    /// immediately rather than after the queued audio drains. The caller is
    /// expected to have applied any perceptual curve already (see
    /// SpotifyPlayer).
    ///
    /// Callable from anywhere. The value is applied on the actor, and it is
    /// always the latest one, however the tasks carrying a slider's run of
    /// changes happen to be ordered.
    nonisolated func setVolume(_ volume: Float) {
        requestedVolume.withLock { $0 = max(0, min(1, volume)) }
        Task { await applyVolume() }
    }

    private func applyVolume() {
        renderer.volume = requestedVolume.withLock { $0 }
    }
}
