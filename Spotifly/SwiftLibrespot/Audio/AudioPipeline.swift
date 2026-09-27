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
/// on its own thread because pushing PCM blocks on the sink's backpressure —
/// parking it on the actor would freeze every control call behind the audio.
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

    /// Decoder for the loaded track. It holds the decrypted Ogg bytes alive
    /// for as long as it exists, which is what makes a seek a cheap in-memory
    /// `ov_pcm_seek` — nothing else keeps a copy of them.
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

    /// Bumped by every `playTrack`. A load that awaited the network while a
    /// newer one began must not start decoding: both would run a decode thread
    /// into the one sink — two quick presses of Next did exactly that.
    private var loadGeneration = 0

    private var isPlaying = false
    private var isPaused = false

    /// Track frame the sink's playhead clock origin corresponds to — nonzero
    /// after a seek or a start-at-position.
    private var sinkClockOriginFrame: Int64 = 0

    /// Sink frame at which `sinkClockOriginFrame` plays: zero after a load or
    /// a seek, which restart the sink clock, and the boundary for a track that
    /// followed on without a gap, which does not.
    private var trackStartSinkFrame: Int64 = 0
    private var endOfTrackFired = false

    /// The next track, decoding into the sink behind this one so the change
    /// has no gap: the sink is never flushed between them. It becomes the
    /// loaded track once the playhead reaches `startFrame`, the sink frame its
    /// first sample plays at.
    ///
    /// If the queue changes its mind in the last seconds of a track, the start
    /// of this one is heard before the load auto-advance then asks for.
    private var continuation: (track: PreparedTrack, decoder: VorbisDecoder, startFrame: Int64)?

    /// A continuation is waiting for its file.
    private var isPreparingContinuation = false

    /// The track that took over at the last boundary, so the load auto-advance
    /// asks for when it hears of the end does not start it a second time.
    private var continuedUri: String?

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
    ///
    /// - Parameter paused: load and position the track but hold playout until
    ///   `resume()`, as a handover of paused playback needs.
    func playTrack(uri: String, positionMs: UInt64 = 0, paused: Bool = false) async throws {
        let continued = continuedUri
        continuedUri = nil
        if continued == uri, currentTrackUri == uri, positionMs == 0, !paused, isPlaying, !isPaused {
            debugLog("AudioPipeline", "\(uri) is already playing, without a gap")
            // Republished for the position it has actually reached.
            playbackStateSubject.send(.playing(trackUri: uri))
            return
        }

        debugLog("AudioPipeline", "Playing \(uri) at \(positionMs)ms")
        playbackStateSubject.send(.loading(trackUri: uri))

        loadGeneration += 1
        let generation = loadGeneration
        await teardownTrack()

        let track = try await preparedTrack(for: uri)
        let vorbis = try VorbisDecoder(bytes: track.ogg)
        debugLog("AudioPipeline", "Decoder open: \(vorbis.format.sampleRate)Hz x\(vorbis.format.channels), \(vorbis.totalFrames) frames")

        guard generation == loadGeneration else {
            debugLog("AudioPipeline", "Superseded while loading \(uri)")
            vorbis.close()
            throw CancellationError()
        }

        current = track
        currentTrackUri = uri
        durationMs = Int64(track.durationMs)
        sampleRate = vorbis.format.sampleRate
        decoder = vorbis

        let startFrame = positionMs > 0
            ? Int64((Double(positionMs) / 1000.0) * Double(vorbis.format.sampleRate))
            : 0
        startDecoding(from: startFrame, keepPaused: paused)
    }

    // MARK: - Prepared Tracks

    /// A track ready to decode: everything the network had to supply.
    private struct PreparedTrack {
        let uri: String
        let quality: Quality
        let durationMs: Int
        /// Decrypted Ogg Vorbis from the codec's first page on. Shared with the
        /// decoder, not copied.
        let ogg: [UInt8]
    }

    /// The loaded track, kept so playing it again — repeat-one, or previous
    /// near its start — does not download it again.
    private var current: PreparedTrack?

    /// The track expected next, fetched before this one ends so the change
    /// does not wait on the network: the download is most of a track start.
    private var upcoming: (uri: String, fetch: Task<PreparedTrack, Error>)?

    /// What plays after the current track, as the queue has it.
    private var nextUri: String?

    /// The next track is fetched once this one has played a while, so a
    /// press of Next is immediate too, or near its end at the latest —
    /// librespot's `PRELOAD_NEXT_TRACK_BEFORE_END_DURATION_MS`. Skipping
    /// through the first seconds of tracks fetches nothing extra.
    private static let prefetchAfterMs: Int64 = 10000
    private static let prefetchLeadMs: Int64 = 30000

    /// Tells the pipeline what the queue will play next. A fetch already made
    /// for a track that is no longer next is dropped.
    func setNextTrack(_ uri: String?) {
        nextUri = uri
        if let upcoming, upcoming.uri != uri {
            upcoming.fetch.cancel()
            self.upcoming = nil
        }
    }

    /// The loaded track when it is played again, the fetched-ahead one when it
    /// is the one expected, and otherwise a fresh fetch.
    private func preparedTrack(for uri: String) async throws -> PreparedTrack {
        if let current, current.uri == uri, current.quality == quality {
            return current
        }
        if let upcoming, upcoming.uri == uri {
            self.upcoming = nil
            if let track = try? await upcoming.fetch.value, track.quality == quality {
                debugLog("AudioPipeline", "Using \(uri) fetched ahead")
                return track
            }
        }
        return try await prepare(uri)
    }

    /// Metadata, then the audio key and the CDN url side by side, then the
    /// download and decryption.
    private func prepare(_ uri: String) async throws -> PreparedTrack {
        guard let spclient else {
            throw LibrespotError.invalidState("SPClient not configured")
        }

        let trackId = try Self.trackGid(fromUri: uri)
        var metadata = try await spclient.getTrackMetadata(trackId: trackId)

        // /metadata/4 answers a stub without files; the playable list comes
        // from extended-metadata.
        if metadata.files.isEmpty {
            metadata.files = try await spclient.getAudioFiles(entityUri: uri)
        }

        debugLog("AudioPipeline", "Track '\(metadata.name)': \(metadata.files.count) file(s), \(metadata.durationMs)ms")

        let quality = quality
        guard let file = Self.selectVorbisFile(metadata.files, preferring: quality) else {
            throw LibrespotError.trackNotFound("No Ogg Vorbis file available")
        }

        // Independent requests on different transports — the key over the
        // accesspoint socket, the url over HTTP — so neither waits for the other.
        async let key = audioKeyProvider.getKey(fileId: file.fileId, trackId: trackId)
        async let cdnUrl = spclient.resolveCDNUrl(fileId: file.fileId)

        let encrypted = try await Self.downloadWholeFile(cdnUrl.url)

        // The whole file is ciphertext, keystream from block 0. Nothing is
        // skipped: the stream opens with the Ogg capture pattern once decrypted.
        let decrypted = try await AESDecryptor(key: key).decrypt(encrypted)
        let vorbisStream = Self.vorbisStreamOffset(decrypted)
        debugLog("AudioPipeline", "Decrypted \(decrypted.count) bytes; Vorbis begins at \(vorbisStream.offset) after \(vorbisStream.skippedPages) Spotify page(s)")

        return PreparedTrack(
            uri: uri,
            quality: quality,
            durationMs: metadata.durationMs,
            ogg: [UInt8](decrypted[(decrypted.startIndex + vorbisStream.offset)...]),
        )
    }

    /// Starts fetching the next track once the current one is due for it.
    private func fetchNextIfDue(positionMs: Int64) {
        guard upcoming == nil, continuation == nil, let next = nextUri, next != current?.uri,
              positionMs >= Self.prefetchAfterMs || durationMs - positionMs < Self.prefetchLeadMs
        else { return }

        debugLog("AudioPipeline", "Fetching \(next) ahead")
        upcoming = (next, Task { [weak self] in
            guard let self else { throw CancellationError() }
            return try await prepare(next)
        })
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
        // Nothing is going to play, so neither the loaded file nor the next one
        // is worth the memory.
        current = nil
        upcoming?.fetch.cancel()
        upcoming = nil
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
        await retireDecodeThread()
        dropContinuation()

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
    private func retireDecodeThread() async {
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
    /// actor: the work itself happens on the decode thread started below.
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
        trackStartSinkFrame = 0

        endOfTrackFired = false
        isPlaying = true
        isPaused = keepPaused

        sink.flush()
        if !keepPaused {
            sink.start()
        }

        decodeState.setPlayback(playing: true, paused: keepPaused)
        startDecodeThread(decoder)

        if keepPaused {
            stopPositionTimer()
        } else {
            startPositionTimer()
        }
        playbackStateSubject.send(keepPaused ? .paused(trackUri: currentTrackUri ?? "") : .playing(trackUri: currentTrackUri ?? ""))
    }

    /// One dedicated thread per decoder. It blocks freely — throttled writes,
    /// pause polling — without occupying a Swift-concurrency cooperative
    /// thread, which would starve this actor's own jobs (position ticks,
    /// pause) for the length of the track.
    private func startDecodeThread(_ decoder: VorbisDecoder) {
        decodeState.reset()

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
    }

    // MARK: - Gapless Continuation

    /// Starts decoding the next track behind this one, which has been decoded
    /// to its end. The sink still holds the last seconds of this track, so
    /// the next one's first samples land directly after its last.
    private func prepareContinuation(of uri: String) async {
        defer { isPreparingContinuation = false }

        // Under repeat-one the next track is this one, already in memory;
        // otherwise it is the one fetched ahead, done by now or nearly.
        var track: PreparedTrack?
        if let current, current.uri == uri {
            track = current
        } else if let upcoming, upcoming.uri == uri {
            track = try? await upcoming.fetch.value
        }

        // The wait may have let anything happen: a load, a seek, a change of
        // queue, or the end of this track, which auto-advance then loads the
        // ordinary way from the same fetch.
        let decoded = decodeState.snapshot()
        guard let track, track.quality == quality, nextUri == uri, continuation == nil,
              isPlaying, !endOfTrackFired, decoded.finished, !decoded.cancelled,
              let decoder = try? VorbisDecoder(bytes: track.ogg)
        else { return }

        if upcoming?.uri == uri {
            upcoming = nil
        }
        let startFrame = trackStartSinkFrame + decoded.writtenFrames
        continuation = (track, decoder, startFrame)
        debugLog("AudioPipeline", "Decoding \(uri) behind the current track, from sink frame \(startFrame)")
        startDecodeThread(decoder)
    }

    /// The playhead has reached the continuation: it is now the loaded track,
    /// and the one before it has ended.
    private func adoptContinuation() {
        guard let continuation else { return }
        self.continuation = nil
        let ended = currentTrackUri ?? ""
        let uri = continuation.track.uri

        // The previous decoder's thread finished before this one started.
        decoder?.close()
        decoder = continuation.decoder
        current = continuation.track
        currentTrackUri = uri
        durationMs = Int64(continuation.track.durationMs)
        sampleRate = continuation.decoder.format.sampleRate
        sinkClockOriginFrame = 0
        trackStartSinkFrame = continuation.startFrame
        endOfTrackFired = false
        continuedUri = uri

        // Auto-advance moves the queue on and asks for this track, and that
        // request publishes it; publishing it here, ahead of the queue, would
        // report it with the previous track's place in the context.
        debugLog("AudioPipeline", "End of track; \(uri) follows without a gap")
        endOfTrackSubject.send(ended)
    }

    /// Forgets the continuation, once its thread has been retired. Its file is
    /// kept, for when that track is asked for after all.
    private func dropContinuation() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.decoder.close()
        debugLog("AudioPipeline", "Dropped the continuation into \(continuation.track.uri)")
        if upcoming == nil, continuation.track.uri != current?.uri {
            let track = continuation.track
            upcoming = (track.uri, Task<PreparedTrack, Error> { track })
        }
    }

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
        }

        state.setFinished(frames: totalWritten)
        debugLog("AudioPipeline", "Decode finished: \(totalWritten) frames")
    }

    // MARK: - Teardown

    /// Cancels whatever is running and releases the loaded track.
    private func teardownTrack() async {
        await retireDecodeThread()
        dropContinuation()
        positionTimer?.cancel()
        positionTimer = nil

        isPlaying = false
        isPaused = false
        endOfTrackFired = false
        continuedUri = nil
        sinkClockOriginFrame = 0
        trackStartSinkFrame = 0

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

        if let continuation, sink.playedFramesSinceStart >= continuation.startFrame {
            adoptContinuation()
        }

        let positionMs = frameToMs(currentTrackFrame())
        positionSubject.send(UInt64(positionMs))
        fetchNextIfDue(positionMs: Int64(positionMs))

        // `writtenFrames` is only meaningful once the loop has finished, which
        // is the only moment it is read: the loop writes its running total once,
        // on the way out. An in-flight count was being accumulated on top of an
        // already-cumulative value — quadratic nonsense that nothing consumed.
        // While a continuation waits for the playhead, the loop is its.
        let snapshot = decodeState.snapshot()
        guard continuation == nil, snapshot.finished, snapshot.writtenFrames > 0, !endOfTrackFired else { return }

        if !isPreparingContinuation, let next = nextUri {
            isPreparingContinuation = true
            Task { await prepareContinuation(of: next) }
        }

        // Both sides of this comparison count frames decoded *this load*: the
        // playhead relative to where the track started in the sink, against
        // frames written since. Mixing in absolute frames would fire the
        // moment a seek finished decoding, cutting the tail off. Without a
        // continuation the sink is flushed for whatever plays next, so this
        // waits for the very last frame.
        if sink.playedFramesSinceStart - trackStartSinkFrame >= snapshot.writtenFrames {
            endOfTrackFired = true
            debugLog("AudioPipeline", "End of track")
            endOfTrackSubject.send(currentTrackUri ?? "")
        }
    }

    /// The track frame currently audible: the sink's own playhead, from where
    /// the track started in it, plus the track offset that start stands for.
    private func currentTrackFrame() -> Int64 {
        sinkClockOriginFrame + sink.playedFramesSinceStart - trackStartSinkFrame
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
