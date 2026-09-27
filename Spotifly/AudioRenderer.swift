//
//  AudioRenderer.swift
//  Spotifly
//
//  Bridges decoded PCM output to AVSampleBufferAudioRenderer for AirPlay-compatible playback.
//  Audio data flows: decoder -> ring buffer -> AVSampleBufferAudioRenderer -> AirPlay/speakers
//

import AVFoundation
import CoreMedia

/// Audio renderer that bridges the decoder's push model to
/// AVSampleBufferAudioRenderer's pull model.
///
/// Thread safety: `write(samples:count:)` is called from the pipeline's
/// dedicated decode thread, which blocks freely here — that is the point of
/// it having its own thread. The feed side runs on a serial dispatch queue.
/// A ring buffer with lock-based synchronization bridges the two.
final nonisolated class AudioRenderer: @unchecked Sendable, AudioSink {
    // MARK: - Constants

    private static let sampleRate: Float64 = 44100
    private static let channelCount: UInt32 = 2
    private static let bytesPerSample = MemoryLayout<Float>.size // 4

    /// Ring buffer capacity in f32 samples (~2 seconds of stereo audio)
    private static let ringBufferCapacity = 176_400 // 44100 * 2ch * 2s

    /// Chunk size for feeding renderer (~1024 frames = 2048 stereo samples)
    private static let feedChunkSamples = 2048

    // MARK: - AVFoundation Objects (recreated on output device change)

    private var renderer = AudioRenderer.makeRenderer()
    private var synchronizer = AVSampleBufferRenderSynchronizer()

    /// The renderer spatializes only multichannel audio unless told otherwise,
    /// and Spotify's is stereo. Allowing stereo makes Spatial Audio on AirPods
    /// and similar headphones available to it; whether it is used, and with or
    /// without head tracking, is the listener's choice in Control Center.
    private static func makeRenderer() -> AVSampleBufferAudioRenderer {
        let renderer = AVSampleBufferAudioRenderer()
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        return renderer
    }

    /// Output gain (0...1) applied at the renderer. There is no mixer stage
    /// anywhere else, so this is where playback volume is actually applied — at
    /// the output, which takes effect immediately instead of after the buffered
    /// PCM drains. Accessed only on `renderQueue` so it stays serialized with
    /// feeding and pipeline recreation.
    private var outputVolume: Float = 1.0

    // MARK: - Ring Buffer

    private let ringBuffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0
    private let bufferLock = NSLock()

    /// Parks the decode thread while the buffer is full or the throttle holds
    /// it back; signalled when space frees up and by `stop()`.
    private let spaceAvailable = DispatchSemaphore(value: 0)
    private var writerIsWaiting = false

    // MARK: - Write Throttle (provides real-time pacing)

    /// Wall-clock time (monotonic) when writing started. Must be accessed with bufferLock held.
    private var writeStartTime: TimeInterval = 0

    /// Total f32 samples written since start. Must be accessed with bufferLock held.
    private var totalSamplesWritten: Int64 = 0

    /// Maximum seconds the writer can be ahead of real-time before sleeping.
    /// It replaces the backpressure CoreAudio callbacks used to provide.
    private static let maxBufferAheadSeconds: Double = 2.0

    /// How far under that limit the writer sleeps to, so it wakes to decode
    /// half a second at a time rather than for every chunk — 2 wakeups a
    /// second instead of about 20.
    private static let writeBurstSeconds: Double = 0.5

    // MARK: - State

    private let renderQueue = DispatchQueue(label: "com.spotifly.audio-renderer", qos: .userInteractive)
    private var isRendering = false
    private var currentPTS: CMTime = .zero
    private var isRequestingData = false

    // MARK: - Route Change Observation

    private var routeChangeObserver: (any NSObjectProtocol)?

    // MARK: - Audio Format (cached)

    private let formatDescription: CMAudioFormatDescription

    // MARK: - Init

    init() {
        ringBuffer = .allocate(capacity: Self.ringBufferCapacity)
        ringBuffer.initialize(repeating: 0, count: Self.ringBufferCapacity)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.bytesPerSample) * Self.channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.bytesPerSample) * Self.channelCount,
            mChannelsPerFrame: Self.channelCount,
            mBitsPerChannel: UInt32(Self.bytesPerSample * 8),
            mReserved: 0,
        )

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &desc,
        )
        guard status == noErr, let formatDesc = desc else {
            fatalError("AudioRenderer: Failed to create audio format description: \(status)")
        }
        formatDescription = formatDesc
        synchronizer.addRenderer(renderer)

        // Recover from output device changes (AirPlay ↔ local speaker)
        observeRouteChanges()

        debugLog("AudioRenderer", "Initialized (44100Hz, 2ch, Float32)")
    }

    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        renderer.stopRequestingMediaData()
        synchronizer.removeRenderer(renderer, at: .invalid)
        ringBuffer.deallocate()
    }

    // MARK: - Volume

    /// Sets the output gain (0...1) applied to playback. Takes effect immediately
    /// — it scales audio as it is played out, not the already-buffered PCM — so
    /// volume changes are not delayed by the render buffer. The caller is expected
    /// to have applied any perceptual curve already (see SpotifyPlayer).
    func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        renderQueue.async { [weak self] in
            guard let self else { return }
            outputVolume = clamped
            renderer.volume = clamped
        }
    }

    // MARK: - Ring Buffer Helpers

    /// Number of samples available for reading. Must be called with bufferLock held.
    private var availableSamples: Int {
        writeIndex >= readIndex
            ? writeIndex - readIndex
            : Self.ringBufferCapacity - readIndex + writeIndex
    }

    /// Free space in the ring buffer (-1 to distinguish full from empty). Must be called with bufferLock held.
    private var freeSpace: Int {
        Self.ringBufferCapacity - 1 - availableSamples
    }

    // MARK: - Push Side (called from the decode thread)

    /// Write PCM samples into the ring buffer.
    /// Blocks if buffer is full (backpressure to the decoder).
    func write(samples: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var offset = 0

        while remaining > 0 {
            bufferLock.lock()
            let space = freeSpace

            if space == 0 {
                // Once the consumer has stopped, nothing will ever drain the buffer, so
                // waiting is waiting forever — the 500ms timeout only makes us loop. The
                // caller here is the decode thread, and blocking it stalls the join that
                // teardown waits on. Drop the rest instead: it is audio for a renderer
                // that is no longer playing.
                guard isRendering else {
                    bufferLock.unlock()
                    return
                }

                writerIsWaiting = true
                bufferLock.unlock()
                // Block until pull side consumes data (timeout bounds the wait so a stop
                // that lands while we are parked here is noticed)
                _ = spaceAvailable.wait(timeout: .now() + .milliseconds(500))
                continue
            }

            let toWrite = min(remaining, space)

            // Write with wrap-around
            let firstChunk = min(toWrite, Self.ringBufferCapacity - writeIndex)
            ringBuffer.advanced(by: writeIndex)
                .update(from: samples.advanced(by: offset), count: firstChunk)

            if firstChunk < toWrite {
                let secondChunk = toWrite - firstChunk
                ringBuffer.update(from: samples.advanced(by: offset + firstChunk), count: secondChunk)
            }

            writeIndex = (writeIndex + toWrite) % Self.ringBufferCapacity
            totalSamplesWritten += Int64(toWrite)
            let samplesWritten = totalSamplesWritten
            let elapsed = ProcessInfo.processInfo.systemUptime - writeStartTime
            let needsRestart = isRendering && !isRequestingData
            bufferLock.unlock()

            // If renderer stopped requesting data (buffer was empty), restart it
            if needsRestart {
                renderQueue.async { [weak self] in
                    self?.startRequestingData()
                }
            }

            // Time-based throttle: AVSampleBufferAudioRenderer eagerly accepts data
            // for buffering, providing no real-time backpressure. Without this check,
            // the decode loop runs at full CPU speed (~7x), racing through tracks.
            let audioDuration = Double(samplesWritten) / (Self.sampleRate * Double(Self.channelCount))
            let ahead = audioDuration - elapsed
            // Waits on the semaphore rather than sleeping so that `stop()` cuts
            // it short: a seek or a skip joins this thread before going on.
            if ahead > Self.maxBufferAheadSeconds {
                let pause = ahead - Self.maxBufferAheadSeconds + Self.writeBurstSeconds
                _ = spaceAvailable.wait(timeout: .now() + pause)
            }

            remaining -= toWrite
            offset += toWrite
        }
    }

    // MARK: - Pull Side (called on renderQueue by AVSampleBufferAudioRenderer)

    /// Feeds the renderer from its own pull callback. It asks when it is down
    /// to about 0.7 s and takes about half a second until it is full again at
    /// 1.25 s (measured on macOS 27), so the queue wakes about twice a second.
    ///
    /// The callback runs again at once for as long as it returns with the
    /// renderer still wanting data, so an empty ring must stop it rather than
    /// return — that loop is what once made this a 25 ms timer. The next
    /// `write` starts it again.
    private func startRequestingData() {
        bufferLock.lock()
        guard isRendering, !isRequestingData else {
            bufferLock.unlock()
            return
        }
        isRequestingData = true
        bufferLock.unlock()

        renderer.requestMediaDataWhenReady(on: renderQueue) { [weak self] in
            self?.feedRenderer()
        }
    }

    private func stopRequestingData() {
        bufferLock.lock()
        isRequestingData = false
        bufferLock.unlock()
        renderer.stopRequestingMediaData()
    }

    /// Moves what the ring holds into the renderer until either runs out.
    private func feedRenderer() {
        while renderer.isReadyForMoreMediaData {
            // Read a chunk from ring buffer
            bufferLock.lock()
            let available = availableSamples
            let toRead = min(Self.feedChunkSamples, available)

            if toRead == 0 {
                // Cleared under the same lock the writer checks it with, so a
                // write landing now restarts the feed rather than being missed.
                isRequestingData = false
                bufferLock.unlock()
                renderer.stopRequestingMediaData()
                return
            }

            // Allocate temporary buffer for this chunk
            let chunkSize = toRead * Self.bytesPerSample
            let chunk = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: Self.bytesPerSample)

            // Copy with wrap-around
            let firstChunk = min(toRead, Self.ringBufferCapacity - readIndex)
            chunk.copyMemory(
                from: ringBuffer.advanced(by: readIndex),
                byteCount: firstChunk * Self.bytesPerSample,
            )
            if firstChunk < toRead {
                let secondChunk = toRead - firstChunk
                chunk.advanced(by: firstChunk * Self.bytesPerSample)
                    .copyMemory(from: ringBuffer, byteCount: secondChunk * Self.bytesPerSample)
            }

            readIndex = (readIndex + toRead) % Self.ringBufferCapacity
            let shouldSignal = writerIsWaiting
            writerIsWaiting = false
            bufferLock.unlock()

            if shouldSignal {
                spaceAvailable.signal()
            }

            // Create CMBlockBuffer from chunk data
            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: chunk,
                blockLength: chunkSize,
                blockAllocator: kCFAllocatorDefault, // Core Media will free the block
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: chunkSize,
                flags: 0,
                blockBufferOut: &blockBuffer,
            )

            guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
                chunk.deallocate()
                debugLog("AudioRenderer", "Failed to create CMBlockBuffer: \(status)")
                return
            }

            // Create CMSampleBuffer
            let frameCount = toRead / Int(Self.channelCount)
            var sampleBuffer: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: formatDescription,
                sampleCount: frameCount,
                presentationTimeStamp: currentPTS,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer,
            )

            guard status == noErr, let sample = sampleBuffer else {
                debugLog("AudioRenderer", "Failed to create CMSampleBuffer: \(status)")
                return
            }

            // Advance presentation time
            currentPTS = CMTimeAdd(
                currentPTS,
                CMTime(value: CMTimeValue(frameCount), timescale: CMTimeScale(Self.sampleRate)),
            )

            // Enqueue
            renderer.enqueue(sample)
        }
    }

    // MARK: - Playback Control

    /// Frames actually played out since the most recent `start()`, read off the
    /// render synchronizer's clock. This is the *audible* position — samples that
    /// have left the speakers, not samples the decoder has produced. The Rust path
    /// this replaced reported the decoder clock here, which ran up to two seconds
    /// ahead of what was audible and forced asymmetric drift compensation
    /// downstream.
    ///
    /// Synchronous dispatch is safe: callers are the player state machine and its
    /// timers, never the render queue itself.
    var playedFramesSinceStart: Int64 {
        renderQueue.sync {
            let seconds = synchronizer.currentTime().seconds
            return seconds.isFinite && seconds > 0 ? Int64(seconds * Self.sampleRate) : 0
        }
    }

    /// Synchronous dispatch, so the caller can rely on the state being fully
    /// updated on return — `AudioPipeline.startDecoding` starts writing the moment
    /// this returns, and a teardown expects the flush to have happened.
    func start() {
        renderQueue.sync { [self] in
            bufferLock.lock()
            guard !isRendering else {
                // Already rendering, so the full pipeline reset below is skipped — a
                // deliberate no-op, since flushing mid-playback would glitch the audio.
                //
                // But the throttle anchor must still be re-armed. It measures written
                // audio against wall clock *since the anchor*, so any period where the
                // writer was idle — an outage, a rebuild — banks credit against it. On the
                // next write the throttle sees a large deficit, never sleeps, and lets the
                // decoder run flat out until it catches up: playback races, EndOfTrack
                // fires early, and Spirc advances the track while the renderer still has
                // tens of seconds buffered.
                //
                // Re-anchoring is safe here: it only rebases the pacing budget and does
                // not touch the ring buffer or its contents.
                writeStartTime = ProcessInfo.processInfo.systemUptime
                totalSamplesWritten = 0
                bufferLock.unlock()
                debugLog("AudioRenderer", "Start while already rendering — re-anchored throttle")
                return
            }
            isRendering = true
            bufferLock.unlock()

            // Clear stale data from previous playback: it would otherwise conflict
            // on timestamps and lose real-time pacing entirely.
            resetAudioPipeline()
            synchronizer.setRate(1.0, time: .zero)
            startRequestingData()
            debugLog("AudioRenderer", "Started playback")
        }
    }

    func stop() {
        renderQueue.sync { [self] in
            // Wake a writer parked on a full buffer or in the throttle, also when
            // already stopped: a retiring decode thread is joined after this. On a
            // full buffer it re-checks isRendering and returns rather than waiting
            // for space that will never come now that the pull side is stopping.
            spaceAvailable.signal()

            bufferLock.lock()
            guard isRendering else {
                bufferLock.unlock()
                return
            }
            isRendering = false
            isRequestingData = false
            bufferLock.unlock()

            synchronizer.setRate(0.0, time: synchronizer.currentTime())
            stopRequestingData()
            debugLog("AudioRenderer", "Stopped playback")
        }
    }

    /// Unfreezes playback after `stop()`, continuing from the same point with
    /// whatever was still buffered. Unlike `start()`, deliberately does *not*
    /// flush or reset anything: a pause/resume cycle is seamless by design.
    /// The playhead clock holds its position while stopped, so positions read
    /// across the pause stay continuous.
    func resume() {
        renderQueue.sync { [self] in
            bufferLock.lock()
            guard !isRendering else {
                bufferLock.unlock()
                return
            }
            isRendering = true
            bufferLock.unlock()

            synchronizer.setRate(1.0, time: synchronizer.currentTime())
            startRequestingData()
            debugLog("AudioRenderer", "Resumed playback")
        }
    }

    func flush() {
        renderQueue.sync { [self] in
            debugLog("AudioRenderer", "Flushing audio buffer")
            resetAudioPipeline()

            bufferLock.lock()
            let rendering = isRendering
            bufferLock.unlock()

            if rendering {
                synchronizer.setRate(1.0, time: .zero)
                startRequestingData()
            }
        }
    }

    // MARK: - Route Change Recovery

    /// Observe the renderer's auto-flush notification, which fires when the
    /// output device changes (e.g. AirPlay ↔ local speaker). After an auto-flush
    /// the renderer's internal CoreAudio context is broken (FigSync/timebase errors),
    /// so we must recreate the renderer and synchronizer entirely.
    private func observeRouteChanges() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil,
        ) { [weak self] notification in
            guard let self else { return }

            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?
                .timeValue ?? .zero
            debugLog("AudioRenderer", "Renderer auto-flushed (output device changed, time: \(flushTime))")

            // Recreate pipeline on renderQueue (async since this fires on an arbitrary thread)
            renderQueue.async { [self] in
                bufferLock.lock()
                let rendering = isRendering
                bufferLock.unlock()

                guard rendering else { return }

                debugLog("AudioRenderer", "Recreating pipeline after output device change")
                recreateRenderPipeline()
                synchronizer.setRate(1.0, time: .zero)
                startRequestingData()
            }
        }
    }

    /// Tear down the old renderer/synchronizer and create fresh ones.
    /// An output device change leaves the CoreAudio context in a broken state
    /// where the renderer accepts data but doesn't pace it.
    /// Must be called on renderQueue.
    private func recreateRenderPipeline() {
        stopRequestingData()
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .invalid)

        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }

        renderer = Self.makeRenderer()
        renderer.volume = outputVolume
        synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)

        resetRingBuffer()
        observeRouteChanges()

        debugLog("AudioRenderer", "Render pipeline recreated")
    }

    // MARK: - Internal

    /// Resets the ring buffer indices, PTS, and unblocks any waiting writer.
    /// Must be called on renderQueue.
    private func resetRingBuffer() {
        bufferLock.lock()
        isRequestingData = false
        readIndex = 0
        writeIndex = 0
        totalSamplesWritten = 0
        writeStartTime = ProcessInfo.processInfo.systemUptime
        let shouldSignal = writerIsWaiting
        writerIsWaiting = false
        bufferLock.unlock()

        if shouldSignal {
            spaceAvailable.signal()
        }

        currentPTS = .zero
    }

    /// Flushes the renderer and resets the ring buffer.
    /// Must be called on renderQueue.
    private func resetAudioPipeline() {
        stopRequestingData()
        renderer.flush()
        resetRingBuffer()
    }
}
