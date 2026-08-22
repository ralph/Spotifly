//
//  AudioPipeline.swift
//  SwiftLibrespot
//
//  Orchestrates fetching, decryption, decoding, and output of Spotify audio.
//
//  A track moves through five stages, all coordinated here:
//  metadata (spclient) → audio key (AP socket) → CDN download → AES-CTR
//  decrypt → Ogg Vorbis decode → PCM push into the sink.
//
//  The decrypted file is held in memory for the life of the track, so a seek
//  is a cheap in-memory `ov_pcm_seek` rather than a re-download.
//

import AVFoundation
import Combine
import Foundation

/// Coordinates downloading, decryption, decoding, and playback of a track.
///
/// Concurrency: the actor owns all playback state; the decode loop itself runs
/// detached because pushing PCM blocks on the sink's backpressure — parking it
/// on the actor would freeze every control call behind the audio.
actor AudioPipeline {
    // MARK: - Dependencies

    private let accesspoint: Accesspoint
    private let audioKeyProvider: AudioKeyProvider
    private let spclient: SPClient?
    private let sink: any AudioSink

    // MARK: - Publishers

    private nonisolated(unsafe) let playbackStateSubject = CurrentValueSubject<AudioPlaybackState, Never>(.idle)
    private nonisolated(unsafe) let positionSubject = CurrentValueSubject<UInt64, Never>(0)
    private nonisolated(unsafe) let errorSubject = PassthroughSubject<LibrespotError, Never>()
    private nonisolated(unsafe) let endOfTrackSubject = PassthroughSubject<String, Never>()

    nonisolated var playbackState: AnyPublisher<AudioPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    nonisolated var position: AnyPublisher<UInt64, Never> {
        positionSubject.eraseToAnyPublisher()
    }

    nonisolated var errors: AnyPublisher<LibrespotError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    /// Fires once when a track has fully played out — the hook auto-advance
    /// uses. Not fired for stop, skip, or replacement.
    nonisolated var endOfTrack: AnyPublisher<String, Never> {
        endOfTrackSubject.eraseToAnyPublisher()
    }

    // MARK: - Types

    enum AudioPlaybackState: Sendable, Equatable {
        case idle
        case loading(trackUri: String)
        case playing(trackUri: String)
        case paused(trackUri: String)
    }

    /// Streaming quality, expressed as kbps to compare against file formats.
    enum Quality: Int, Sendable {
        case low = 96
        case normal = 160
        case high = 320
    }

    // MARK: - Playback State

    private var quality: Quality = .normal

    private(set) var currentTrackUri: String?
    private var durationMs: Int64 = 0
    private var sampleRate: Int = 44100

    /// Decoders hold their source data alive, so `decryptedData` is only kept
    /// separately for logging/diagnostics.
    private var decoder: VorbisDecoder?

    private var decodeTask: Task<Void, Never>?
    private var positionTimer: Task<Void, Never>?

    private var isPlaying = false
    private var isPaused = false
    /// Continuations of decode-loop passes parked while paused.
    private var resumeWakers: [CheckedContinuation<Void, Never>] = []

    /// Track frames pushed into the sink for the current load.
    private var writtenFrames: Int64 = 0
    /// Track frame the sink's playhead clock origin corresponds to — nonzero
    /// after a seek or a start-at-position.
    private var sinkClockOriginFrame: Int64 = 0
    private var decodingComplete = false
    private var endOfTrackFired = false

    /// How close the playhead must be to the last written frame before the
    /// track counts as finished. One feed chunk of slack covers the samples
    /// still queued inside the renderer when the final frame is read.
    private static let endOfTrackSlackFrames: Int64 = 4096

    // MARK: - Initialization

    init(accesspoint: Accesspoint, spclient: SPClient?, sink: any AudioSink) {
        self.accesspoint = accesspoint
        self.spclient = spclient
        self.sink = sink
        audioKeyProvider = AudioKeyProvider(accesspoint: accesspoint)
        debugLog("AudioPipeline", "Initialized")
    }

    // MARK: - Settings

    func setQuality(_ quality: Quality) {
        self.quality = quality
    }

    // MARK: - Playback Control

    /// Plays a track by URI, resolving everything needed along the way.
    func playTrack(uri: String, positionMs: UInt64 = 0) async throws {
        guard let spclient else {
            throw LibrespotError.invalidState("SPClient not configured")
        }

        debugLog("AudioPipeline", "Playing \(uri) at \(positionMs)ms")
        playbackStateSubject.send(.loading(trackUri: uri))

        await teardownTrack()

        let trackId = try Self.trackGid(fromUri: uri)

        let metadata = try await spclient.getTrackMetadata(trackId: trackId)
        debugLog("AudioPipeline", "Track '\(metadata.name)': \(metadata.files.count) file(s), \(metadata.durationMs)ms")

        guard let file = Self.selectVorbisFile(metadata.files, preferring: quality) else {
            throw LibrespotError.trackNotFound("No Ogg Vorbis file available")
        }

        let key = try await audioKeyProvider.getKey(fileId: file.fileId, trackId: trackId)
        let cdnUrl = try await spclient.resolveCDNUrl(fileId: file.fileId)

        let encrypted = try await Self.downloadWholeFile(cdnUrl.url)

        // The whole file is ciphertext, keystream from block 0. Nothing is
        // skipped: the stream opens with the Ogg capture pattern once decrypted.
        let decryptor = AESDecryptor()
        decryptor.setKey(key)
        let decrypted = decryptor.decrypt(encrypted)

        #if DEBUG
            let head = decrypted.prefix(8).map { String(format: "%02X", $0) }.joined()
            debugLog("AudioPipeline", "Decrypted \(decrypted.count) bytes, head: \(head)")
        #endif

        let vorbis = try VorbisDecoder(data: decrypted)

        currentTrackUri = uri
        durationMs = Int64(metadata.durationMs)
        sampleRate = vorbis.format.sampleRate
        decoder = vorbis

        let startFrame = positionMs > 0
            ? Int64((Double(positionMs) / 1000.0) * Double(vorbis.format.sampleRate))
            : 0
        startDecoding(from: startFrame)
    }

    func pause() {
        guard let uri = currentTrackUri, isPlaying, !isPaused else { return }

        debugLog("AudioPipeline", "Pausing")
        isPaused = true
        sink.stop()
        stopPositionTimer()
        playbackStateSubject.send(.paused(trackUri: uri))
    }

    func resume() {
        guard let uri = currentTrackUri, isPlaying, isPaused else { return }

        debugLog("AudioPipeline", "Resuming")
        isPaused = false
        wakeDecoders()
        sink.resume()
        startPositionTimer()
        playbackStateSubject.send(.playing(trackUri: uri))
    }

    func stop() async {
        debugLog("AudioPipeline", "Stopping")
        await teardownAndGoIdle()
    }

    /// Stops the current track and tears down its resources, publishing idle.
    private func teardownAndGoIdle() async {
        await teardownTrack()
        isPlaying = false
        playbackStateSubject.send(.idle)
        positionSubject.send(0)
    }

    /// Seeks within the current track. Works while playing or paused; either
    /// way the decode restarts from the new offset and holds there if paused.
    func seek(positionMs: UInt64) async throws {
        guard currentTrackUri != nil, let decoder else {
            throw LibrespotError.invalidState("No track loaded")
        }

        debugLog("AudioPipeline", "Seeking to \(positionMs)ms")
        let frame = Int64((Double(positionMs) / 1000.0) * Double(decoder.format.sampleRate))

        // Cancel the running loop and wake it so cancellation is observed even
        // though it is parked on pause.
        decodeTask?.cancel()
        wakeDecoders()
        decodeTask = nil

        startDecoding(from: frame, keepPaused: isPaused)
    }

    /// Sets output volume (0…1). Gain is applied at the sink, which takes
    /// effect immediately rather than after buffered audio drains.
    func setVolume(_ volume: Float) {
        sink.setVolume(volume)
    }

    /// Duration of the loaded track, from its metadata.
    var currentDurationMs: Int64 {
        durationMs
    }

    /// Current position in milliseconds, derived from the sink playhead.
    func currentPositionMs() -> UInt64 {
        guard currentTrackUri != nil, isPlaying else {
            return UInt64(max(0, min(durationMs, Int64(frameToMs(sinkClockOriginFrame)))))
        }
        return UInt64(max(0, min(durationMs, Int64(frameToMs(currentTrackFrame())))))
    }

    // MARK: - Decode Orchestration

    /// Starts (or restarts) the decode loop at `frame`. Synchronous on the
    /// actor: the work itself happens on a detached task.
    ///
    /// `keepPaused` preserves a paused state across a seek: the decoder is in
    /// place and position is published, but nothing is written or played until
    /// `resume()`.
    private func startDecoding(from frame: Int64, keepPaused: Bool = false) {
        guard let decoder else { return }
        guard decoder.isOpen else {
            errorSubject.send(.decodingFailed("decoder closed"))
            return
        }

        if frame > 0, !decoder.seek(toFrame: frame) {
            debugLog("AudioPipeline", "Seek to frame \(frame) failed; continuing at current position")
            sinkClockOriginFrame = decoder.currentFrame
        } else {
            sinkClockOriginFrame = frame
        }

        writtenFrames = 0
        decodingComplete = false
        endOfTrackFired = false
        isPlaying = true
        isPaused = keepPaused

        sink.flush()
        if !keepPaused {
            sink.start()
        }

        let uri = currentTrackUri ?? ""
        let channels = decoder.format.channels
        let sinkRef = sink

        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runDecodeLoop(decoder: decoder, channels: channels, sink: sinkRef)
        }

        if keepPaused {
            stopPositionTimer()
        } else {
            startPositionTimer()
        }
        playbackStateSubject.send(keepPaused ? .paused(trackUri: uri) : .playing(trackUri: uri))
    }

    /// The decode loop. Runs off the actor because `sink.write` blocks on
    /// backpressure; every state touch hops back through `await`.
    ///
    /// The decoder is owned solely by this task from the moment it is passed
    /// in until the task is cancelled or completes — the actor never touches
    /// it concurrently (a seek cancels and replaces the task before opening a
    /// new one).
    private func runDecodeLoop(
        decoder: VorbisDecoder,
        channels: Int,
        sink: any AudioSink,
    ) async {
        let chunkFrames = 2048
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * channels)
        defer { buffer.deallocate() }

        var totalWritten: Int64 = 0

        while !Task.isCancelled {
            if await shouldPark() {
                await waitForResume()
                if Task.isCancelled {
                    break
                }
            }

            let frames = decoder.read(into: buffer, maxFrames: chunkFrames)
            if frames <= 0 {
                break
            }

            sink.write(samples: buffer, count: frames * channels)
            totalWritten += Int64(frames)
            await noteProgress(totalWritten)
        }

        if Task.isCancelled {
            return
        }
        await markDecodingComplete(totalWritten)
    }

    private func shouldPark() -> Bool {
        isPaused
    }

    /// Parks the caller until `resume()` wakes it.
    private func waitForResume() async {
        await withCheckedContinuation { continuation in
            resumeWakers.append(continuation)
        }
    }

    private func wakeDecoders() {
        let wakers = resumeWakers
        resumeWakers = []
        wakers.forEach { $0.resume() }
    }

    private func noteProgress(_ frames: Int64) {
        writtenFrames = frames
        positionSubject.send(UInt64(frameToMs(currentTrackFrame())))
    }

    private func markDecodingComplete(_ frames: Int64) {
        writtenFrames = frames
        decodingComplete = true
        debugLog("AudioPipeline", "Decode complete: \(frames) frames")
    }

    // MARK: - Teardown

    /// Cancels whatever is running and releases the loaded track.
    private func teardownTrack() async {
        decodeTask?.cancel()
        wakeDecoders()
        decodeTask = nil
        positionTimer?.cancel()
        positionTimer = nil

        isPlaying = false
        isPaused = false
        decodingComplete = false
        endOfTrackFired = false
        writtenFrames = 0
        sinkClockOriginFrame = 0

        decoder?.close()
        decoder = nil

        sink.stop()
        sink.flush()
    }

    // MARK: - Position Tracking

    private func startPositionTimer() {
        positionTimer?.cancel()
        positionTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.tick()
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.cancel()
        positionTimer = nil
    }

    /// Periodic tick: publish position, detect end of track.
    private func tick() {
        guard currentTrackUri != nil, isPlaying, !isPaused else { return }

        positionSubject.send(UInt64(frameToMs(currentTrackFrame())))

        if decodingComplete, !endOfTrackFired, writtenFrames > 0 {
            let played = currentTrackFrame()
            if played >= writtenFrames - Self.endOfTrackSlackFrames {
                endOfTrackFired = true
                debugLog("AudioPipeline", "End of track")
                endOfTrackSubject.send(currentTrackUri ?? "")
            }
        }
    }

    /// The track frame currently audible: the sink's own playhead plus the
    /// track offset its clock origin stands for.
    private func currentTrackFrame() -> Int64 {
        sinkClockOriginFrame + sink.playedFramesSinceStart
    }

    private func frameToMs(_ frame: Int64) -> Double {
        Double(frame) / Double(sampleRate) * 1000.0
    }

    // MARK: - Helpers

    /// Picks the best Ogg Vorbis file for the quality preference: nearest
    /// match wins, ties go to the higher quality.
    private static func selectVorbisFile(_ files: [SPClient.TrackMetadata.AudioFile], preferring quality: Quality) -> SPClient.TrackMetadata.AudioFile? {
        let vorbisFiles = files.filter(\.format.isVorbis)
        guard !vorbisFiles.isEmpty else { return nil }

        return vorbisFiles.min {
            let d0 = abs($0.format.kbps - quality.rawValue)
            let d1 = abs($1.format.kbps - quality.rawValue)
            return d0 == d1 ? $0.format.kbps > $1.format.kbps : d0 < d1
        }
    }

    /// Downloads a complete CDN file. Tracks are a few MB; streaming them
    /// chunk-by-chunk bought nothing over one request and complicated seeking.
    private static func downloadWholeFile(_ url: URL) async throws -> Data {
        debugLog("AudioPipeline", "Downloading from \(url.host ?? "?")")

        let (location, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LibrespotError.cdnError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try Data(contentsOf: location)
    }

    /// Extracts the base62 track id from a URI or open.spotify.com link and
    /// decodes it to the 16-byte gid the protocol speaks.
    private static func trackGid(fromUri uri: String) throws -> Data {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        let base62: Substring
        if let range = trimmed.range(of: "spotify:track:") {
            base62 = trimmed[range.upperBound...].prefix { $0 != ":" }
        } else if let range = trimmed.range(of: "open.spotify.com/track/") {
            base62 = trimmed[range.upperBound...].prefix { $0 != "?" && $0 != "/" }
        } else {
            throw LibrespotError.trackNotFound("not a track uri: \(trimmed.prefix(60))")
        }

        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value: UInt128 = 0
        for char in base62 {
            guard let index = alphabet.firstIndex(of: char) else {
                throw LibrespotError.trackNotFound("bad track id: \(base62)")
            }
            value = value &* UInt128(62) &+ UInt128(index)
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 15, through: 0, by: -1) {
            bytes[i] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        return Data(bytes)
    }
}
