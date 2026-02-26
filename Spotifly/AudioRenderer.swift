//
//  AudioRenderer.swift
//  Spotifly
//
//  Bridges librespot PCM output to AVSampleBufferAudioRenderer for AirPlay-compatible playback.
//  Audio data flows: Rust FFI callback -> ring buffer -> AVSampleBufferAudioRenderer -> AirPlay/speakers
//

import AVFoundation
import CoreMedia

/// Audio renderer that bridges librespot's push model (Sink::write) to
/// AVSampleBufferAudioRenderer's pull model (requestMediaDataWhenReady).
///
/// Thread safety: `writeAudioData` is called from librespot's Rust player thread.
/// `feedRenderer` runs on a dedicated serial dispatch queue.
/// A ring buffer with lock-based synchronization bridges the two.
final nonisolated class AudioRenderer: @unchecked Sendable {
    // MARK: - Constants

    private static let sampleRate: Float64 = 44100
    private static let channelCount: UInt32 = 2
    private static let bytesPerSample = MemoryLayout<Float>.size // 4

    /// Ring buffer capacity in f32 samples (~2 seconds of stereo audio)
    private static let ringBufferCapacity = 176_400 // 44100 * 2ch * 2s

    /// Chunk size for feeding renderer (~1024 frames = 2048 stereo samples)
    private static let feedChunkSamples = 2048

    // MARK: - AVFoundation Objects

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()

    // MARK: - Ring Buffer

    private let ringBuffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0
    private let bufferLock = NSLock()

    /// Semaphore for backpressure: blocks Rust thread when buffer is full
    private let spaceAvailable = DispatchSemaphore(value: 0)
    private var writerIsWaiting = false

    // MARK: - State

    private let renderQueue = DispatchQueue(label: "com.spotifly.audio-renderer", qos: .userInteractive)
    private var isRendering = false
    private var currentPTS: CMTime = .zero
    private var isRequestingData = false

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

        debugLog("AudioRenderer", "Initialized (44100Hz, 2ch, Float32)")
    }

    deinit {
        renderer.stopRequestingMediaData()
        synchronizer.removeRenderer(renderer, at: .invalid)
        ringBuffer.deallocate()
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

    // MARK: - Push Side (called from Rust player thread)

    /// Write PCM samples into the ring buffer.
    /// Blocks if buffer is full (backpressure to librespot's player thread).
    func writeAudioData(_ samples: UnsafePointer<Float>, count: Int) {
        var remaining = count
        var offset = 0

        while remaining > 0 {
            bufferLock.lock()
            let space = freeSpace

            if space == 0 {
                writerIsWaiting = true
                bufferLock.unlock()
                // Block until pull side consumes data (timeout prevents deadlock on shutdown)
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
            let needsRestart = isRendering && !isRequestingData
            bufferLock.unlock()

            // If renderer stopped requesting data (buffer was empty), restart it
            if needsRestart {
                renderQueue.async { [weak self] in
                    self?.startRequestingData()
                }
            }

            remaining -= toWrite
            offset += toWrite
        }
    }

    // MARK: - Pull Side (called on renderQueue by AVSampleBufferAudioRenderer)

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

    private func feedRenderer() {
        while renderer.isReadyForMoreMediaData {
            // Read a chunk from ring buffer
            bufferLock.lock()
            let available = availableSamples
            let toRead = min(Self.feedChunkSamples, available)

            if toRead == 0 {
                // Buffer empty — stop requesting until more data arrives
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

            // Signal writer if waiting for space
            if writerIsWaiting {
                writerIsWaiting = false
                bufferLock.unlock()
                spaceAvailable.signal()
            } else {
                bufferLock.unlock()
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

    /// Called from Rust player thread via FFI callback. Synchronous dispatch
    /// ensures the caller can rely on state being fully updated on return
    /// (e.g. spotifly_disconnect expects flush to complete before proceeding).
    func start() {
        renderQueue.sync { [self] in
            bufferLock.lock()
            guard !isRendering else {
                bufferLock.unlock()
                return
            }
            isRendering = true
            bufferLock.unlock()

            // Clear stale data from previous playback to prevent timestamp conflicts
            // and loss of real-time pacing (28x speed bug).
            resetAudioPipeline()
            synchronizer.setRate(1.0, time: .zero)
            startRequestingData()
            debugLog("AudioRenderer", "Started playback")
        }
    }

    func stop() {
        renderQueue.sync { [self] in
            bufferLock.lock()
            guard isRendering else {
                bufferLock.unlock()
                return
            }
            isRendering = false
            isRequestingData = false
            bufferLock.unlock()

            synchronizer.setRate(0.0, time: synchronizer.currentTime())
            renderer.stopRequestingMediaData()
            debugLog("AudioRenderer", "Stopped playback")
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

    /// Flushes the renderer, resets the ring buffer, and resets PTS.
    /// Must be called on renderQueue.
    private func resetAudioPipeline() {
        renderer.stopRequestingMediaData()
        renderer.flush()

        bufferLock.lock()
        isRequestingData = false
        readIndex = 0
        writeIndex = 0
        if writerIsWaiting {
            writerIsWaiting = false
            bufferLock.unlock()
            spaceAvailable.signal()
        } else {
            bufferLock.unlock()
        }

        currentPTS = .zero
    }
}
