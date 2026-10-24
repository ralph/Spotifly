//
//  AudioOutput.swift
//  Spotifly
//
//  The audio output: the pipeline's PCM played by an AVPlayer, as one stream
//

import AVFoundation
import CoreMedia
import Synchronization

/// Plays the pipeline's PCM through an `AVPlayer`: the one player macOS lets the AirPlay picker
/// send to a receiver alone, the rest of the Mac's audio staying where it is
/// (`plans/done/avplayer-output.md`).
///
/// The pipeline pushes interleaved 44.1 kHz stereo Float32 PCM and paces itself on `enqueue`,
/// which suspends until the output wants more; a paused output wants nothing, so the decode waits
/// out a pause inside it. The first buffer after a `restart` plays at playhead zero and each one
/// after it directly follows, which is all the pipeline's gapless playback is: the next track is
/// decoded into the same stream behind the current one.
///
/// The player's item is that stream: a CAF written as the pipeline pushes, served through a
/// resource loader under a custom scheme, its data chunk declared a week long. One item serves the
/// session: an item started while a receiver is chosen never asks its loader for a byte, so a
/// `restart` (a load, a seek) is a seek within it to where the new audio begins, the end of what
/// is written. Nothing is decoded ahead as a whole file: `enqueue` returns once what is written
/// ahead of the playhead is under `aheadTarget`.
///
/// A buffer waiting in `enqueue` across a `restart` or a `stop` is the pipeline's to retire: it
/// cancels its decode, and awaits it, before either.
actor AudioOutput {
    nonisolated static let sampleRate = 44100
    nonisolated static let channelCount = 2
    nonisolated static let bytesPerFrame = MemoryLayout<Float>.size * channelCount

    /// What became of a buffer handed to `enqueue`.
    enum Enqueued {
        case accepted
        /// The caller's task was cancelled.
        case flushed
        /// The player's item failed, and plays nothing more until the next restart.
        case failed
    }

    /// Written ahead of the playhead before `enqueue` waits: about what the player reads ahead of
    /// what is heard, measured as 30 s here and 25 s on a HomePod. With 10 s the HomePod ran the
    /// player's buffer empty about 5 s after a seek, the Mac sending well ahead of what it plays;
    /// with 3 s the player starved here after a resume.
    private static let aheadTarget = 30.0
    /// Written ahead at most, while the player is meant to play and its playhead stands still.
    ///
    /// A receiver such as a HomePod takes in what is written at once, so the player's reader
    /// soon stands at the end of the stream, waiting for bytes with a lock held that a seek, a
    /// pause and even reading the item's time wait for (sampled: 85 s on the main thread).
    /// Written ahead of a playhead that does not move, nothing more came: a seek never finished
    /// while the receiver played on, or a playhead froze after one. Bytes beyond the reader let
    /// it go on. Writing 120 s ahead all the time did the same, at about 150 MB more.
    private static let aheadLimit = 120.0
    /// The playhead when it last moved, and when that was.
    private var lastPlayhead: (frames: Int64, at: ContinuousClock.Instant) = (0, .now)
    /// Whether the output writes past the target for a playhead that stands still, to log once.
    private var feedingStillPlayhead = false

    /// The session's stream.
    private var stream: PCMStream?
    private var streams = 0
    /// Frames written to the stream, all runs together.
    private var streamFrames: Int64 = 0
    /// Where the current run begins in the stream: the playhead's zero. Read from any thread.
    private nonisolated let origin = Mutex<Int64>(0)
    /// Frames a stream holds before the next restart begins a new one: a week, less ten minutes.
    private static let streamCapacity = PCMStream.declaredFrames - Int64(sampleRate * 600)
    /// The latest volume asked for, which the player takes on the main actor.
    private nonisolated let requestedVolume = Mutex<Float>(1)

    /// The player itself, on the main actor, as its KVO and the AirPlay picker are.
    nonisolated var output: AudioOutputPlayer {
        AudioOutputPlayer.shared
    }

    // MARK: - Feeding

    /// Queues `frames` interleaved frames, suspending until the player wants more.
    func enqueue(_ samples: Data, frames: Int) async -> Enqueued {
        guard !Task.isCancelled, let stream else { return .flushed }

        stream.append(samples)
        streamFrames += Int64(frames)

        while !Task.isCancelled {
            let state = output.state
            if state.failed {
                return .failed
            }
            let played = playedFrames
            if played != lastPlayhead.frames {
                lastPlayhead = (played, .now)
            }
            let written = streamFrames - origin.withLock { $0 }
            let ahead = Double(written - played) / Double(Self.sampleRate)
            let standsStill = state.wantsToPlay && lastPlayhead.at.duration(to: .now) > .milliseconds(500)
            if standsStill != feedingStillPlayhead {
                feedingStillPlayhead = standsStill
                if standsStill {
                    debugLog("AudioOutput", "The playhead stands still; writing up to \(Int(Self.aheadLimit)) s ahead")
                }
            }
            if ahead < Self.aheadTarget || (standsStill && ahead < Self.aheadLimit) {
                return .accepted
            }
            // Asleep until a second under the target, so the decode fills that second in one
            // go: checked every 50 ms, the wait woke the app 12 times a second, against 3 for the
            // renderer this replaced. A playhead that stops is noticed within the second; a
            // paused player, which takes nothing, is looked at every 5 s.
            let cap = state.wantsToPlay ? 1.0 : 5.0
            try? await Task.sleep(for: .seconds(min(cap, max(0.05, ahead - (Self.aheadTarget - 1)))))
        }
        return .flushed
    }

    // MARK: - Playback Control

    /// Discards everything queued and starts the playhead again at zero, running or held.
    func restart(paused: Bool) async {
        // A failed item plays nothing more, so it is replaced, as a full stream is.
        if stream != nil, streamFrames < Self.streamCapacity, !output.state.failed {
            origin.withLock { $0 = streamFrames }
            await output.seek(toFrame: streamFrames, paused: paused)
            return
        }
        stream?.close()
        streams += 1
        streamFrames = 0
        origin.withLock { $0 = 0 }
        let stream = PCMStream(number: streams)
        self.stream = stream
        await output.play(stream, paused: paused)
    }

    func pause() async {
        await output.pause()
    }

    func resume() async {
        // Stood still while paused: from now on, standing still is a stall.
        lastPlayhead = (playedFrames, .now)
        await output.resume()
    }

    /// Holds the item where it is: the next `restart` seeks past what it played.
    func stop() async {
        await output.pause()
    }

    /// Frames played out since the last `restart`, the audible playhead: the item's, from the
    /// run's origin. Until a seek to the origin has taken, the item is behind it: zero.
    nonisolated var playedFrames: Int64 {
        let seconds = output.playheadSeconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return max(0, Int64(seconds * Double(Self.sampleRate)) - origin.withLock { $0 })
    }

    // MARK: - Volume

    /// Sets the player's gain (0…1), after the perceptual curve; the player keeps it across items.
    /// A receiver's volume is its own, set in the AirPlay picker: no public API reaches it, and
    /// this gain does not (measured on a HomePod, 70 % and 30 % alike).
    nonisolated func setVolume(_ volume: Float) {
        requestedVolume.withLock { $0 = max(0, min(1, volume)) }
        Task { @MainActor in
            AudioOutputPlayer.shared.player.volume = self.requestedVolume.withLock { $0 }
        }
    }
}

// MARK: - Output

/// The `AVPlayer` the output plays its stream through, and the one the AirPlay picker binds.
@MainActor
final class AudioOutputPlayer {
    nonisolated static let shared = AudioOutputPlayer()

    let player: AVPlayer

    /// What the output's actor reads of the player and its item, from any thread.
    struct State {
        var status = AVPlayer.TimeControlStatus.paused
        /// The item's timebase, for the playhead.
        var timebase: UncheckedTimebase?
        /// Whether the item has failed, after which it plays nothing more.
        var failed = false
        /// Whether the output means the player to play, whatever it does.
        var wantsToPlay = false
    }

    private nonisolated let lockedState = Mutex(State())

    private let playerObservation: NSKeyValueObservation
    private var itemObservation: NSKeyValueObservation?
    private var stream: PCMStream?
    /// Whether the output means the player to play. A player that stalls with nothing to wait for
    /// pauses itself, and stays paused: measured on resuming on a HomePod, where it flipped to
    /// paused 70 ms after playing, with data loaded beyond the playhead.
    private var wantsToPlay = false {
        didSet { lockedState.withLock { $0.wantsToPlay = wantsToPlay } }
    }
    /// Numbers the seeks, so only the latest plays when done, or is made again.
    private var seeks = 0
    /// Whether a seek is under way: the player is held for it, which is not a stall.
    private var seekInFlight = false

    private nonisolated init() {
        let player = AVPlayer()
        // Waiting to minimise stalls, the player waited for good: it holds out for a rate of data
        // the output, which writes as the playhead moves, never shows it.
        player.automaticallyWaitsToMinimizeStalling = false
        // The Mac renders and sends the audio to a receiver itself. Allowed to, the player hands
        // a new item's URL to the receiver, which cannot open this app's scheme: an item started
        // on the HomePod (after a seek) never asked the loader for a byte.
        player.allowsExternalPlayback = false
        self.player = player
        // KVO calls in on any thread: the handlers are `@Sendable` and hop to the main actor.
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { @Sendable player, _ in
            let status = player.timeControlStatus
            let reason = player.reasonForWaitingToPlay?.rawValue
            Task { @MainActor in AudioOutputPlayer.shared.timeControlStatusChanged(status, reason: reason) }
        }
    }

    nonisolated var state: State {
        lockedState.withLock { $0 }
    }

    nonisolated var playheadSeconds: Double {
        lockedState.withLock { $0.timebase.map { CMTimebaseGetTime($0.timebase).seconds } } ?? 0
    }

    func play(_ stream: PCMStream, paused: Bool) {
        self.stream = stream
        lockedState.withLock { $0.timebase = nil; $0.failed = false }

        let asset = AVURLAsset(url: stream.url)
        asset.resourceLoader.setDelegate(stream, queue: stream.queue)
        let item = AVPlayerItem(asset: asset)
        item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        itemObservation = item.observe(\.status, options: [.new]) { @Sendable item, _ in
            let status = item.status
            let error = item.error.map { "\($0)" }
            let timebase = item.timebase.map { UncheckedTimebase(timebase: $0) }
            Task { @MainActor in
                AudioOutputPlayer.shared.itemStatusChanged(status, timebase: timebase, error: error, stream: stream.number)
            }
        }

        player.replaceCurrentItem(with: item)
        wantsToPlay = !paused
        if paused {
            player.pause()
        } else {
            player.playImmediately(atRate: 1)
        }
        debugLog("AudioOutput", "Stream \(stream.number): new item, \(paused ? "held" : "playing")")
    }

    /// Moves the item to `frame`, where the next run's audio will be written, and plays from
    /// there or holds. The loader answers the range request this makes as the audio arrives.
    ///
    /// Held while it seeks, and played only once the seek is done: playing at once cancelled the
    /// seek now and then ("superseded after 0 ms"), and the player went on through what it had
    /// buffered of the old position, 2.4 s of the track before, on the HomePod. A seek cancelled
    /// otherwise is made again, unless a newer one has replaced it.
    func seek(toFrame frame: Int64, paused: Bool) {
        seeks += 1
        seekInFlight = true
        wantsToPlay = !paused
        player.pause()
        seek(to: CMTime(value: frame, timescale: CMTimeScale(AudioOutput.sampleRate)), number: seeks, attempt: 1)
        // Seeks take milliseconds. On a HomePod one waited for the player's reader, which waits
        // for bytes at the end of the stream, while the item played on (`aheadLimit`,
        // `plans/open/airplay-stalls.md`): say so if it happens, with whether the item plays.
        Task { @MainActor [number = seeks] in
            try? await Task.sleep(for: .seconds(2))
            guard number == seeks, seekInFlight else { return }
            let rate = player.currentItem?.timebase.map { CMTimebaseGetRate($0) } ?? 0
            debugLog("AudioOutput", "Seek \(number) not done after 2 s; the item plays at rate \(rate)")
        }
    }

    private func seek(to time: CMTime, number: Int, attempt: Int) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                let output = AudioOutputPlayer.shared
                debugLog("AudioOutput", "Seek to \(String(format: "%.2f", time.seconds)) s \(finished ? "done" : "superseded")")
                guard number == output.seeks else { return }
                if !finished, attempt < 3 {
                    output.seek(to: time, number: number, attempt: attempt + 1)
                    return
                }
                output.seekInFlight = false
                if output.wantsToPlay {
                    output.player.playImmediately(atRate: 1)
                }
            }
        }
    }

    func pause() {
        wantsToPlay = false
        player.pause()
    }

    /// Mid-seek it only says so: the seek plays when done.
    func resume() {
        wantsToPlay = true
        if !seekInFlight {
            player.playImmediately(atRate: 1)
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, timebase: UncheckedTimebase?, error: String?, stream number: Int) {
        guard number == stream?.number else { return }
        switch status {
        case .readyToPlay:
            lockedState.withLock { $0.timebase = timebase }
            debugLog("AudioOutput", "Stream \(number): ready")
        case .failed:
            lockedState.withLock { $0.failed = true }
            debugLog("AudioOutput", "Stream \(number): failed: \(error ?? "?")")
        default:
            break
        }
    }

    private func timeControlStatusChanged(_ status: AVPlayer.TimeControlStatus, reason: String?) {
        lockedState.withLock { $0.status = status }
        switch status {
        case .playing:
            debugLog("AudioOutput", "Playing")
        case .waitingToPlayAtSpecifiedRate:
            debugLog("AudioOutput", "Waiting: \(reason ?? "?")")
        case .paused where wantsToPlay && !seekInFlight:
            // Stalled: nothing else will start it again. Often only the status of a seek's pause,
            // read after the seek is done: the player then plays already.
            debugLog("AudioOutput", "Paused by itself; playing again")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, wantsToPlay, !seekInFlight, player.timeControlStatus == .paused else { return }
                player.playImmediately(atRate: 1)
            }
        case .paused:
            debugLog("AudioOutput", "Paused")
        @unknown default:
            break
        }
    }
}

/// A timebase carried across threads. `CMTimebase` is thread-safe; it is only not marked
/// `Sendable`.
struct UncheckedTimebase: @unchecked Sendable {
    let timebase: CMTimebase
}

// MARK: - Stream

/// One item's bytes: a CAF header, then PCM as the output writes it, served to the player's
/// resource loader from a window of what has been written.
///
/// Kept as the chunks the pipeline pushed, dropped whole from the front: trimming one `Data`
/// with `removeFirst` only re-slices it, and the allocation grew with the stream, 21 MB a minute.
///
/// Confined to `queue`, the loader's delegate queue: appends hop onto it, and the loader calls
/// in on it. Requests for bytes not yet written wait for them.
final nonisolated class PCMStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let number: Int
    let url: URL
    let queue: DispatchQueue

    /// The data chunk's declared length: a week of audio. Only a load or a seek begins a new
    /// stream, so gapless playback runs on in one: declared a day long, a day of it would have
    /// reached the end and stopped.
    static let declaredFrames = Int64(AudioOutput.sampleRate * 86400 * 7)
    private static let declaredDataBytes = declaredFrames * Int64(AudioOutput.bytesPerFrame)

    private let headerLength: Int64
    /// What is kept of the stream, in the pieces it was written in, and the stream offset of each.
    private var chunks: [Data] = []
    private var offsets: [Int64] = []
    private var written: Int64 = 0
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var closed = false

    init(number: Int) {
        self.number = number
        url = URL(string: "spotifly-stream://pcm/\(number).caf")!
        queue = DispatchQueue(label: "PCMStream \(number)")
        let header = Self.cafHeader(dataBytes: Self.declaredDataBytes)
        headerLength = Int64(header.count)
        super.init()
        keep(header)
    }

    /// How close to the declared end a request must start to be the player's look at the end, and
    /// how far past what is written one must start to be its other look ahead.
    private static let tailLength: Int64 = 1024 * 1024
    private static let farAhead: Int64 = 256 * 1024 * 1024

    private var declaredLength: Int64 {
        headerLength + Self.declaredDataBytes
    }

    func append(_ samples: Data) {
        queue.async { [self] in
            guard !closed else { return }
            keep(samples)
            serve()
        }
    }

    func close() {
        queue.async { [self] in
            closed = true
            for request in pending where !request.isFinished {
                request.finishLoading(with: CancellationError())
            }
            pending.removeAll()
            chunks.removeAll()
            offsets.removeAll()
        }
    }

    private func keep(_ chunk: Data) {
        chunks.append(chunk)
        offsets.append(written)
        written += Int64(chunk.count)
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else { return false }
        if let info = request.contentInformationRequest {
            info.contentType = "com.apple.coreaudio-format"
            info.contentLength = declaredLength
            info.isByteRangeAccessSupported = true
        }
        if let data = request.dataRequest {
            debugLog("AudioOutput", "Stream \(number): request at \(data.requestedOffset), \(data.requestsAllDataToEndOfResource ? "to the end" : "\(data.requestedLength) bytes"), \(written) written")
            // Before it plays, the player reads two places far ahead, and waits for both: the
            // declared end, to look for chunks after the data, and byte 1,667,301,376 (0x63610000),
            // whatever the length. The end is a week of audio in, which no one reaches: silence
            // answers it. The other is finished empty. Answered with silence, it was kept and
            // would have played as 12 s of silence 79 minutes in, and the player's one range
            // request stopped there; finished empty, the request runs to the declared end.
            if data.requestedOffset >= declaredLength - Self.tailLength {
                let length = declaredLength - data.requestedOffset
                data.respond(with: Data(count: Int(data.requestsAllDataToEndOfResource ? length : min(length, Int64(data.requestedLength)))))
                request.finishLoading()
                return true
            }
            if data.requestedOffset > written + Self.farAhead {
                request.finishLoading()
                return true
            }
            pending.append(request)
            serve()
        } else {
            request.finishLoading()
        }
        return true
    }

    func resourceLoader(_: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
    }

    /// Answers every waiting request with what has been written for it, finishes those that have
    /// all they asked for, and lets go of chunks no request can still want.
    private func serve() {
        pending.removeAll { request in
            guard !request.isFinished, !request.isCancelled, let data = request.dataRequest else { return true }
            guard let first = offsets.first, data.currentOffset >= first else {
                debugLog("AudioOutput", "Stream \(number): asked for \(data.currentOffset), before what is kept")
                request.finishLoading(with: URLError(.dataNotAllowed))
                return true
            }
            let end = data.requestsAllDataToEndOfResource
                ? written
                : min(written, data.requestedOffset + Int64(data.requestedLength))
            respond(to: data, upTo: end)
            if !data.requestsAllDataToEndOfResource, data.currentOffset >= data.requestedOffset + Int64(data.requestedLength) {
                request.finishLoading()
                return true
            }
            return false
        }
        trim()
    }

    /// Hands a request the kept bytes from where it is up to `end`, a chunk or part of one at a
    /// time, without copying them first.
    private func respond(to data: AVAssetResourceLoadingDataRequest, upTo end: Int64) {
        // The chunk holding the request's offset: the last that starts at or before it.
        var index = (offsets.lastIndex { $0 <= data.currentOffset }) ?? 0
        while data.currentOffset < end, index < chunks.count {
            let chunk = chunks[index]
            let from = Int(data.currentOffset - offsets[index])
            let to = Int(min(end, offsets[index] + Int64(chunk.count)) - offsets[index])
            if from < to {
                data.respond(with: chunk[(chunk.startIndex + from) ..< (chunk.startIndex + to)])
            }
            index += 1
        }
    }

    /// Keeps a minute of audio, about 20 MB, behind the earliest offset a waiting request is at,
    /// for a player that asks again a little way back, dropping whole chunks. The player reads
    /// about as far ahead as the output writes, 30 s, so this reaches some 30 s behind what plays.
    private func trim() {
        let earliest = pending.compactMap { $0.dataRequest?.currentOffset }.min() ?? written
        let keepFrom = earliest - Int64(AudioOutput.sampleRate * AudioOutput.bytesPerFrame * 60)
        var drop = 0
        while drop + 1 < offsets.count, offsets[drop + 1] <= keepFrom {
            drop += 1
        }
        if drop > 0 {
            chunks.removeFirst(drop)
            offsets.removeFirst(drop)
        }
    }

    // MARK: CAF

    /// A CAF header for interleaved little-endian Float32 stereo at 44.1 kHz: the file header,
    /// the `desc` chunk, and the `data` chunk's header and edit count, 68 bytes.
    static func cafHeader(dataBytes: Int64) -> Data {
        var data = Data()
        func append(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func append(_ value: some FixedWidthInteger) {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }

        append("caff")
        append(UInt16(1)) // version
        append(UInt16(0)) // flags

        append("desc")
        append(Int64(32))
        append(Float64(AudioOutput.sampleRate).bitPattern)
        append("lpcm")
        append(UInt32(1 | 2)) // float, little-endian
        append(UInt32(AudioOutput.bytesPerFrame)) // bytes per packet
        append(UInt32(1)) // frames per packet
        append(UInt32(AudioOutput.channelCount))
        append(UInt32(32)) // bits per channel

        append("data")
        append(dataBytes + 4) // the edit count is part of the chunk
        append(UInt32(0)) // edit count
        return data
    }
}
