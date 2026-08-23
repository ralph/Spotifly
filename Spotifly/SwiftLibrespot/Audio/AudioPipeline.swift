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

    /// Shared state for the dedicated decode thread. The loop runs on a
    /// plain pthread-style thread because it blocks for long stretches
    /// (throttled writes); parking it on a Swift-concurrency cooperative
    /// thread starved every actor job — ticks, pause — for the length of a
    /// track.
    private final class DecodeLoopState: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var finished = false
        var playing = false
        var paused = false
        var writtenFrames: Int64 = 0

        func reset() {
            lock.lock(); defer { lock.unlock() }
            cancelled = false
            finished = false
            writtenFrames = 0
        }

        func setCancelled() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }

        func setFinished(frames: Int64) {
            lock.lock(); defer { lock.unlock() }
            finished = true
            writtenFrames = frames
        }

        func addWritten(_ frames: Int64) -> Int64 {
            lock.lock(); defer { lock.unlock() }
            writtenFrames += frames
            return writtenFrames
        }

        func snapshot() -> (cancelled: Bool, finished: Bool, writtenFrames: Int64) {
            lock.lock(); defer { lock.unlock() }
            return (cancelled, finished, writtenFrames)
        }

        func setPlayback(playing: Bool? = nil, paused: Bool? = nil) {
            lock.lock(); defer { lock.unlock() }
            if let playing {
                self.playing = playing
            }
            if let paused {
                self.paused = paused
            }
        }

        func isPaused() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return paused
        }
    }

    private let decodeState = DecodeLoopState()
    private nonisolated(unsafe) var decodeWakeSemaphore: DispatchSemaphore?

    private var positionTimer: Task<Void, Never>?

    private var isPlaying = false
    private var isPaused = false

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

        var metadata = try await spclient.getTrackMetadata(trackId: trackId)

        // /metadata/4 answers a stub without files; the playable list comes
        // from extended-metadata.
        if metadata.files.isEmpty {
            metadata.files = try await spclient.getAudioFiles(entityUri: uri)
        }

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

        debugLog("AudioPipeline", "Opening decoder…")
        let vorbisStream = Self.vorbisStreamOffset(decrypted)
        debugLog("AudioPipeline", "Vorbis stream begins at byte \(vorbisStream.offset), skipped \(vorbisStream.skippedPages) Spotify page(s)")
        let vorbis = try VorbisDecoder(data: decrypted.subdata(in: vorbisStream.offset ..< decrypted.count))
        debugLog("AudioPipeline", "Decoder open: \(vorbis.format.sampleRate)Hz x\(vorbis.format.channels), \(vorbis.totalFrames) frames")

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
        decodeState.setPlayback(paused: true)
        sink.stop()
        stopPositionTimer()
        playbackStateSubject.send(.paused(trackUri: uri))
    }

    func resume() {
        guard let uri = currentTrackUri, isPlaying, isPaused else { return }

        debugLog("AudioPipeline", "Resuming")
        isPaused = false
        decodeState.setPlayback(paused: false)
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

        // Retire the running loop and wait for it to actually finish before
        // the decoder below is touched again: two tasks reading one
        // OggVorbis_File concurrently is undefined behavior, not a glitch.
        await retireDecodeTask()

        startDecoding(from: frame, keepPaused: isPaused)
    }

    /// Cancels the decode loop and waits for its thread to exit.
    ///
    /// The wait is not optional: callers touch the decoder the moment this
    /// returns — `seek` re-enters `ov_pcm_seek`, `teardownTrack` calls
    /// `ov_clear` — and a second party inside `ov_read` on the same
    /// `OggVorbis_File` is undefined behavior, not a glitch.
    ///
    /// Termination is prompt by construction: the writer returns from a full
    /// buffer once the sink has been stopped (backpressure checks rendering),
    /// and the pause park polls a flag. Bounded anyway, so a wedged thread can
    /// never take playback control down with it.
    private func retireDecodeTask() async {
        decodeState.setCancelled()

        // Stop pulling so a writer parked on a full ring wakes up.
        sink.stop()

        guard let semaphore = decodeWakeSemaphore else { return }
        decodeWakeSemaphore = nil

        // The semaphore wait itself must not happen on a cooperative thread —
        // Dispatch forbids blocking there — so it runs on a throwaway thread
        // that resumes us when the decode loop has signalled or the bound
        // expires.
        await withCheckedContinuation { continuation in
            let joiner = Thread {
                _ = semaphore.wait(timeout: .now() + 5)
                continuation.resume()
            }
            joiner.name = "spotifly.decode-join"
            joiner.stackSize = 1 << 18
            joiner.start()
        }
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

        endOfTrackFired = false
        isPlaying = true
        isPaused = keepPaused

        sink.flush()
        if !keepPaused {
            sink.start()
        }

        decodeState.reset()
        decodeState.setPlayback(playing: true, paused: keepPaused)

        // One dedicated thread per track load. It blocks freely — throttled
        // writes, pause polling — without occupying a Swift-concurrency
        // cooperative thread, which would starve this actor's own jobs
        // (position ticks, pause) for the length of the track.
        let semaphore = DispatchSemaphore(value: 0)
        decodeWakeSemaphore = semaphore
        let state = decodeState
        let channels = decoder.format.channels
        let sinkRef = sink

        let thread = Thread {
            defer { semaphore.signal() }
            Self.runDecodeThread(
                decoder: decoder,
                channels: channels,
                sink: sinkRef,
                state: state,
            )
        }
        thread.name = "spotifly.decode"
        thread.stackSize = 1 << 20
        thread.start()

        if keepPaused {
            stopPositionTimer()
        } else {
            startPositionTimer()
        }
        playbackStateSubject.send(keepPaused ? .paused(trackUri: currentTrackUri ?? "") : .playing(trackUri: currentTrackUri ?? ""))
    }

    /// The decode loop. Runs off the actor because `sink.write` blocks on
    /// backpressure; every state touch hops back through `await`.
    ///
    /// The decoder is owned solely by this task from the moment it is passed
    /// in until the task is cancelled or completes — the actor never touches
    /// it concurrently (a seek cancels and replaces the task before opening a
    /// new one).
    /// The decode loop, running on its own thread. Synchronous by design:
    /// every long wait here (throttled writes, pause polling, cancellation
    /// polling) would otherwise occupy a cooperative-concurrency thread and
    /// starve the actor's jobs.
    ///
    /// `decoder` is owned solely by this thread until `state.cancelled`
    /// observes true and the caller has joined the thread.
    private nonisolated static func runDecodeThread(
        decoder: VorbisDecoder,
        channels: Int,
        sink: any AudioSink,
        state: DecodeLoopState,
    ) {
        // The actor publishes these on transitions; the loop only mirrors
        // what it needs to be observed from ticks.
        let chunkFrames = 2048
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: chunkFrames * channels)
        defer { buffer.deallocate() }

        var totalWritten: Int64 = 0

        while !state.snapshot().cancelled {
            // A pause parks here. Polling rather than suspending keeps
            // cancellation honored without a second party waking us.
            var parked = 0
            while !state.snapshot().cancelled, state.isPaused() {
                if parked == 0 {
                    debugLog("AudioPipeline", "decode paused")
                }
                parked += 1
                Thread.sleep(forTimeInterval: 0.05)
            }
            if state.snapshot().cancelled {
                break
            }
            if parked > 0 {
                debugLog("AudioPipeline", "decode resumed after pause")
            }

            let frames = decoder.read(into: buffer, maxFrames: chunkFrames)
            if frames <= 0 {
                break
            }

            sink.write(samples: buffer, count: frames * channels)
            totalWritten += Int64(frames)
            _ = state.addWritten(totalWritten)
        }

        state.setFinished(frames: totalWritten)
        debugLog("AudioPipeline", "Decode finished: \(totalWritten) frames")
    }

    // MARK: - Teardown

    /// Cancels whatever is running and releases the loaded track.
    private func teardownTrack() async {
        await retireDecodeTask()
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

        let snapshot = decodeState.snapshot()
        writtenFrames = snapshot.writtenFrames
        decodingComplete = snapshot.finished

        if snapshot.finished, snapshot.writtenFrames > 0, !endOfTrackFired {
            // Both sides of this comparison count frames decoded *this load*:
            // the playhead relative to the sink clock origin, against frames
            // written since that same origin. Mixing in absolute frames would
            // fire the moment a seek finished decoding, cutting the tail off.
            let playedThisLoad = sink.playedFramesSinceStart
            if playedThisLoad >= writtenFrames - Self.endOfTrackSlackFrames {
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

    /// Finds where the actual Ogg Vorbis stream begins inside a decrypted
    /// Spotify file.
    ///
    /// Spotify prepends its own container page (header flags `0x06`) ahead of
    /// the codec stream — a leftover metadata page libvorbis rejects as a bad
    /// header. Real vorbis pages carry clean flags (`0x02` for BOS), so we
    /// walk pages by their segment tables until one qualifies.
    private nonisolated static func vorbisStreamOffset(_ data: Data) -> (offset: Int, skippedPages: Int) {
        var offset = 0
        var skipped = 0

        while offset + 27 <= data.count,
              data[offset ..< offset + 4] == Data("OggS".utf8)
        {
            let flags = data[data.startIndex + offset + 5]
            let segmentCount = Int(data[data.startIndex + offset + 26])
            guard offset + 27 + segmentCount <= data.count else { break }

            var bodyLength = 0
            for i in 0 ..< segmentCount {
                bodyLength += Int(data[data.startIndex + offset + 27 + i])
            }
            let pageLength = 27 + segmentCount + bodyLength

            // A lone BOS flag marks the codec's own first page.
            if flags == 0x02 {
                return (offset, skipped)
            }

            offset += pageLength
            skipped += 1
        }

        // No recognizable BOS page: hand over everything unchanged so the
        // decoder surfaces the failure.
        return (0, 0)
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
