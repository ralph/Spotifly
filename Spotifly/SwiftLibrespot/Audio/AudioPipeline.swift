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
/// Concurrency: the actor owns all playback state, and the decode loop runs on
/// it too. It spends nearly all its time suspended in `AudioRenderer.enqueue`,
/// which lets every control call through meanwhile.
actor AudioPipeline {
    // MARK: - Dependencies

    /// Asks the session for its socket each time, so a reconnect, which
    /// replaces the socket, leaves the pipeline as it is.
    private let audioKeyProvider: AudioKeyProvider
    private let spclient: SPClient?
    private let sink: AudioRenderer

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
    private var gapless = true

    private(set) var currentTrackUri: String?
    private var durationMs: Int64 = 0
    private var sampleRate: Int = 44100

    /// Decoder for the loaded track. It holds the decrypted Ogg bytes alive
    /// for as long as it exists, which is what makes a seek a cheap in-memory
    /// `ov_pcm_seek` — nothing else keeps a copy of them.
    private var decoder: VorbisDecoder?

    /// The running decode, feeding the sink chunk by chunk.
    private var decodeTask: Task<Void, Never>?

    /// What the running decode has handed to the sink, and whether it has
    /// reached the end of the track.
    private var decoded: (frames: Int64, finished: Bool) = (0, false)

    /// Numbers each decode, so a refill a decode asked for is dropped once
    /// another has replaced it, and a replaced decode's last chunk is not
    /// counted as the new one's.
    private var decodeRun = 0

    /// Frames per chunk handed to the sink, 93 ms. The renderer takes about
    /// six at a time.
    private static let chunkFrames = 4096

    private var positionTimer: Task<Void, Never>?

    /// Bumped by every `playTrack`. A load that awaited the network while a
    /// newer one began must not start decoding: both would run a decode
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
    private var continuation: Continuation?
    private typealias Continuation = (track: PreparedTrack, decoder: VorbisDecoder, startFrame: Int64)

    /// A continuation is waiting for its file.
    private var isPreparingContinuation = false

    /// The track that took over at the last boundary, so the load auto-advance
    /// asks for when it hears of the end does not start it a second time.
    private var continuedUri: String?

    // MARK: - Initialization

    init(audioKeyProvider: AudioKeyProvider, spclient: SPClient?, sink: AudioRenderer) {
        self.audioKeyProvider = audioKeyProvider
        self.spclient = spclient
        self.sink = sink
        debugLog("AudioPipeline", "Initialized")
    }

    /// Whether nothing is loaded or loading: after a stop, and before the
    /// first track.
    var isStopped: Bool {
        playbackStateSubject.value == .idle
    }

    // MARK: - Settings

    func setQuality(_ quality: Quality) {
        self.quality = quality
    }

    /// Whether the next track follows on without a gap; see `continuation`.
    /// Off, every track change is a fresh load from a flushed sink.
    func setGapless(_ enabled: Bool) {
        gapless = enabled
    }

    // MARK: - Transitions

    /// Whether a transition — loading, seeking, pausing, resuming, stopping,
    /// refilling — is under way; see `transition`.
    private var transitionInProgress = false
    private var waitingTransitions: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` as the only transition under way. Others wait their turn,
    /// in order, and ticks and continuations stand aside until it is done.
    ///
    /// A transition awaits the renderer and the decode it retires, and this
    /// actor lets anything in at those awaits. Interleaved there, a stop was
    /// overridden by the start it landed in, a tick adopted a continuation a
    /// seek was retiring, and a seek positioned a track loaded meanwhile —
    /// each once guarded at its own await. One at a time, none can happen.
    private func transition<T>(_ body: () async throws -> T) async rethrows -> T {
        if transitionInProgress {
            await withCheckedContinuation { waitingTransitions.append($0) }
        } else {
            transitionInProgress = true
        }
        defer {
            if waitingTransitions.isEmpty {
                transitionInProgress = false
            } else {
                waitingTransitions.removeFirst().resume()
            }
        }
        return try await body()
    }

    // MARK: - Playback Control

    /// Plays a track by URI, resolving everything needed along the way.
    ///
    /// Two transitions with the download between them, so neither a pause
    /// nor a newer load waits for the network: the newer load bumps the
    /// generation, and this one then gives way.
    ///
    /// - Parameter paused: load and position the track but hold playout until
    ///   `resume()`, as a handover of paused playback needs.
    func playTrack(uri: String, positionMs: UInt64 = 0, paused: Bool = false) async throws {
        var generation = 0
        let alreadyPlaying = await transition {
            let continued = continuedUri
            continuedUri = nil
            if continued == uri, currentTrackUri == uri, positionMs == 0, !paused, isPlaying, !isPaused {
                debugLog("AudioPipeline", "\(uri) is already playing, without a gap")
                // Republished for the position it has actually reached.
                playbackStateSubject.send(.playing(trackUri: uri))
                return true
            }

            debugLog("AudioPipeline", "Playing \(uri) at \(positionMs)ms")
            playbackStateSubject.send(.loading(trackUri: uri))

            loadGeneration += 1
            generation = loadGeneration
            await teardownTrack()
            return false
        }
        guard !alreadyPlaying else { return }

        let track = try await preparedTrack(for: uri)
        let vorbis = try VorbisDecoder(bytes: track.ogg)
        debugLog("AudioPipeline", "Decoder open: \(vorbis.format.sampleRate)Hz x\(vorbis.format.channels), \(vorbis.totalFrames) frames")

        try await transition {
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
            await startDecoding(from: startFrame, keepPaused: paused)
        }
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
        // Both are in before the download starts: a key refused by a dead
        // socket would otherwise cost the whole file first.
        async let key = audioKeyProvider.getKey(fileId: file.fileId, trackId: trackId)
        async let cdnUrl = spclient.resolveCDNUrl(fileId: file.fileId)
        let (fileKey, source) = try await (key, cdnUrl)

        let encrypted = try await Self.downloadWholeFile(source.url)

        // The whole file is ciphertext, keystream from block 0. Nothing is
        // skipped: the stream opens with the Ogg capture pattern once decrypted.
        let decrypted = try await AESDecryptor(key: fileKey).decrypt(encrypted)
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

    /// The decode, if still running, waits out the pause inside the sink: a
    /// paused renderer takes nothing more once it is full.
    func pause() async {
        await transition {
            guard let uri = currentTrackUri, isPlaying, !isPaused else { return }

            debugLog("AudioPipeline", "Pausing")
            isPaused = true
            stopPositionTimer()
            await sink.pause()
            playbackStateSubject.send(.paused(trackUri: uri))
        }
    }

    func resume() async {
        await transition {
            guard let uri = currentTrackUri, isPlaying, isPaused else { return }

            debugLog("AudioPipeline", "Resuming")
            isPaused = false
            await sink.resume()
            startPositionTimer()
            playbackStateSubject.send(.playing(trackUri: uri))
        }
    }

    /// Also supersedes a load waiting on the network, which would otherwise
    /// start playing once its download arrived.
    func stop() async {
        await transition {
            debugLog("AudioPipeline", "Stopping")
            loadGeneration += 1
            await teardownAndGoIdle()
        }
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
        try await transition {
            try await performSeek(positionMs: positionMs)
        }
    }

    /// `seek`, inside a transition that is already under way.
    private func performSeek(positionMs: UInt64) async throws {
        guard currentTrackUri != nil, let decoder else {
            throw LibrespotError.invalidState("No track loaded")
        }

        debugLog("AudioPipeline", "Seeking to \(positionMs)ms")
        let frame = Int64((Double(positionMs) / 1000.0) * Double(decoder.format.sampleRate))

        await retireDecoding()
        dropContinuation()
        await startDecoding(from: frame, keepPaused: isPaused)
    }

    /// Cancels the decode and waits for it to end. Once cancelled it neither
    /// reads the decoder again nor gets a buffer into the sink: a waiting
    /// `enqueue` returns at once, paused or not, and a new one is refused.
    private func retireDecoding() async {
        guard let task = decodeTask else { return }
        decodeTask = nil
        task.cancel()
        await task.value
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

    /// Starts (or restarts) decoding at `frame`, from a flushed sink.
    ///
    /// `keepPaused` preserves a paused state across a seek: the decoder is in
    /// place and position is published, but nothing plays until `resume()`.
    private func startDecoding(from frame: Int64, keepPaused: Bool = false) async {
        guard let decoder else { return }
        guard decoder.isOpen else {
            errorSubject.send(.decodingFailed("decoder closed"))
            return
        }

        // Also for frame 0: a decoder that has already read on is not at the
        // start, and a restart of the track — Previous past its first seconds,
        // which other clients send as a seek to 0 — played on from where
        // decoding had got to, or at the end skipped to the next track.
        if !decoder.seek(toFrame: frame) {
            debugLog("AudioPipeline", "Seek to frame \(frame) failed; continuing at current position")
            sinkClockOriginFrame = decoder.currentFrame
        } else {
            sinkClockOriginFrame = frame
        }
        trackStartSinkFrame = 0

        endOfTrackFired = false
        isPlaying = true
        isPaused = keepPaused

        await sink.restart(paused: keepPaused)
        startDecodeTask(decoder)

        if keepPaused {
            stopPositionTimer()
        } else {
            startPositionTimer()
        }
        playbackStateSubject.send(keepPaused ? .paused(trackUri: currentTrackUri ?? "") : .playing(trackUri: currentTrackUri ?? ""))
    }

    private func startDecodeTask(_ decoder: VorbisDecoder) {
        decodeTask?.cancel()
        decodeRun += 1
        let run = decodeRun
        decoded = (0, false)
        decodeTask = Task { await self.decode(decoder, run: run) }
    }

    /// Decodes into the sink until the track ends or the task is cancelled.
    ///
    /// Each `enqueue` suspends until the renderer wants the chunk, which paces
    /// the loop, holds it through a pause and frees this actor meanwhile.
    /// Decoding a chunk takes about a tenth of a millisecond.
    private func decode(_ decoder: VorbisDecoder, run: Int) async {
        let channels = decoder.format.channels
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: Self.chunkFrames * channels)
        defer { samples.deallocate() }

        while !Task.isCancelled {
            let frames = decoder.read(into: samples, maxFrames: Self.chunkFrames)
            guard frames > 0 else {
                if run == decodeRun {
                    decoded.finished = true
                    debugLog("AudioPipeline", "Decode finished: \(decoded.frames) frames")
                }
                return
            }

            let pcm = Data(bytes: samples, count: frames * channels * MemoryLayout<Float>.size)
            switch await sink.enqueue(pcm, frames: frames) {
            case .accepted where run == decodeRun:
                decoded.frames += Int64(frames)
            case .accepted, .flushed:
                return
            case .outputChanged:
                // Refilled from a task of its own: the refill retires this
                // decode, and awaiting that from inside it would never end.
                Task { await self.refill(after: run) }
                return
            case .failed:
                errorSubject.send(.decodingFailed("the audio output refused a buffer"))
                return
            }
        }
    }

    /// The output changed or stalled and the renderer dropped what it had
    /// queued: load again from the playhead, as a seek to the same place would.
    /// What played in the meantime was silence, and is skipped.
    private func refill(after run: Int) async {
        await transition {
            guard run == decodeRun, currentTrackUri != nil, isPlaying else { return }
            // A stall is noticed a second or so after it starts, so near the
            // end of a track the clock may have run into the next one before a
            // tick made it the loaded track. Measured against this one, the
            // playhead would sit at its end, and the refill would decode
            // nothing more of it.
            adoptContinuationIfReached()
            debugLog("AudioPipeline", "Refilling the output from the playhead")
            try? await performSeek(positionMs: currentPositionMs())
        }
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
        guard let track, track.quality == quality, nextUri == uri, continuation == nil,
              !transitionInProgress, isPlaying, !endOfTrackFired, decoded.finished,
              let decoder = try? VorbisDecoder(bytes: track.ogg)
        else { return }

        if upcoming?.uri == uri {
            upcoming = nil
        }
        let startFrame = trackStartSinkFrame + decoded.frames
        continuation = (track, decoder, startFrame)
        debugLog("AudioPipeline", "Decoding \(uri) behind the current track, from sink frame \(startFrame)")
        startDecodeTask(decoder)
    }

    private func adoptContinuationIfReached() {
        if let continuation, sink.playedFrames >= continuation.startFrame {
            adoptContinuation()
        }
    }

    /// The playhead has reached the continuation: it is now the loaded track,
    /// and the one before it has ended.
    private func adoptContinuation() {
        guard let continuation else { return }
        self.continuation = nil
        let ended = currentTrackUri ?? ""
        let uri = continuation.track.uri

        // The previous decode finished before this one started.
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

    /// Forgets the continuation, once its decode has been retired. Its file is
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

    // MARK: - Teardown

    /// Cancels whatever is running and releases the loaded track.
    private func teardownTrack() async {
        await retireDecoding()
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

        await sink.stop()
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

    /// Periodic tick: publish position, detect end of track and a stalled output.
    private func tick() async {
        // A transition under way owns the state this reads and changes.
        guard !transitionInProgress, currentTrackUri != nil, isPlaying, !isPaused else { return }

        adoptContinuationIfReached()

        let positionMs = frameToMs(currentTrackFrame())
        positionSubject.send(UInt64(positionMs))
        fetchNextIfDue(positionMs: Int64(positionMs))

        // While a continuation waits for the playhead, the decode is its. A
        // decode that finished having produced nothing — a seek to the very
        // end — ends the track at once; waiting for frames kept it silent.
        if continuation == nil, decoded.finished, !endOfTrackFired {
            if gapless, !isPreparingContinuation, let next = nextUri {
                isPreparingContinuation = true
                Task { await prepareContinuation(of: next) }
            }

            // Both sides of this comparison count frames decoded *this load*:
            // the playhead relative to where the track started in the sink,
            // against frames written since. Mixing in absolute frames would
            // fire the moment a seek finished decoding, cutting the tail off.
            // Without a continuation the sink is flushed for whatever plays
            // next, so this waits for the very last frame.
            if sink.playedFrames - trackStartSinkFrame >= decoded.frames {
                endOfTrackFired = true
                debugLog("AudioPipeline", "End of track")
                endOfTrackSubject.send(currentTrackUri ?? "")
                return
            }
        }

        // Last, because it awaits the renderer: a stop can land meanwhile, and
        // nothing may act afterwards on what was true before it.
        let run = decodeRun
        if decodeTask != nil, await sink.isStalled {
            debugLog("AudioPipeline", "The output stopped taking audio")
            Task { await refill(after: run) }
        }
    }

    /// The track frame currently audible: the sink's own playhead, from where
    /// the track started in it, plus the track offset that start stands for.
    private func currentTrackFrame() -> Int64 {
        sinkClockOriginFrame + sink.playedFrames - trackStartSinkFrame
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
