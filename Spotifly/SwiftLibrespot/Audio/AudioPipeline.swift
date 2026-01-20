//
//  AudioPipeline.swift
//  SwiftLibrespot
//
//  Orchestrates audio decryption, decoding, and playback
//

import AudioToolbox
import AVFoundation
import Combine
import Foundation

/// Wrapper to allow AVAudioPCMBuffer to cross actor boundaries
/// Safe because the buffer is only accessed from one context at a time
struct SendableBuffer: @unchecked Sendable {
    nonisolated(unsafe) let buffer: AVAudioPCMBuffer

    nonisolated init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

/// Main audio pipeline for Spotify playback
/// Coordinates downloading, decryption, decoding, and playback
public actor AudioPipeline {
    // MARK: - Properties

    private let accesspoint: Accesspoint
    private let audioKeyProvider: AudioKeyProvider
    private let decryptor: AESDecryptor
    private let downloader: ChunkedDownloader
    private var player: AVFoundationPlayer?
    private let simpleDecoder: SimpleAudioDecoder

    /// SPClient for track metadata and CDN resolution
    private var spclient: SPClient?

    /// Current track being played
    private var currentTrack: TrackInfo?

    /// Current audio format
    private var currentFormat: SPClient.TrackMetadata.AudioFormat?

    /// Playback state
    private var isPlaying = false
    private var isPaused = false
    private var positionMs: UInt64 = 0

    /// Streaming task
    private var streamingTask: Task<Void, Never>?

    /// Position update timer
    private var positionTimer: Task<Void, Never>?

    /// Decoded buffers ready for playback
    private var decodedBuffers: [AVAudioPCMBuffer] = []
    private var bufferScheduleIndex = 0

    // MARK: - Publishers

    private nonisolated(unsafe) let playbackStateSubject = CurrentValueSubject<AudioPlaybackState, Never>(.idle)
    private nonisolated(unsafe) let positionSubject = CurrentValueSubject<UInt64, Never>(0)
    private nonisolated(unsafe) let errorSubject = PassthroughSubject<LibrespotError, Never>()

    public nonisolated var playbackState: AnyPublisher<AudioPlaybackState, Never> {
        playbackStateSubject.eraseToAnyPublisher()
    }

    public nonisolated var position: AnyPublisher<UInt64, Never> {
        positionSubject.eraseToAnyPublisher()
    }

    public nonisolated var errors: AnyPublisher<LibrespotError, Never> {
        errorSubject.eraseToAnyPublisher()
    }

    // MARK: - Types

    public enum AudioPlaybackState: Sendable, Equatable {
        case idle
        case loading(trackUri: String)
        case playing(trackUri: String)
        case paused(trackUri: String)
        case buffering(trackUri: String)
        case error(String)
    }

    public struct TrackInfo: Sendable {
        public let uri: String
        public let fileId: Data
        public let durationMs: UInt64
        public let cdnUrl: URL?
    }

    // MARK: - Initialization

    public init(accesspoint: Accesspoint, accessToken: String? = nil, spclientHost: String? = nil) {
        self.accesspoint = accesspoint
        audioKeyProvider = AudioKeyProvider(accesspoint: accesspoint)
        decryptor = AESDecryptor()
        downloader = ChunkedDownloader()
        simpleDecoder = SimpleAudioDecoder()

        if let token = accessToken {
            spclient = SPClient(accessToken: token, spclientHost: spclientHost)
        }

        debugLog("AudioPipeline", "Initialized")
    }

    /// Set SPClient for track resolution
    public func setSPClient(_ client: SPClient) {
        spclient = client
    }

    /// Start the audio engine (must be called before playback)
    public func start() async {
        // Create player on MainActor
        let newPlayer = await AVFoundationPlayer()
        player = newPlayer
        await newPlayer.start()
    }

    // MARK: - Playback Control

    /// Play a track by URI (resolves metadata and CDN automatically)
    public func playTrack(uri: String, positionMs: UInt64 = 0) async throws {
        guard let spclient else {
            throw LibrespotError.invalidState("SPClient not configured")
        }

        debugLog("AudioPipeline", "Playing track: \(uri)")
        playbackStateSubject.send(.loading(trackUri: uri))

        // Get track ID from URI
        let trackId = extractTrackId(from: uri)

        // Fetch track metadata
        let metadata = try await spclient.getTrackMetadata(trackId: trackId)
        debugLog("AudioPipeline", "Track: \(metadata.name), duration: \(metadata.durationMs)ms, files: \(metadata.files.count)")

        // Select best audio file (prefer MP3 for native decoding support)
        guard let audioFile = metadata.selectFile(allowMP3: true) else {
            throw LibrespotError.trackNotFound("No compatible audio format")
        }

        let isMP3 = SPClient.TrackMetadata.isMP3Format(audioFile.format)
        debugLog("AudioPipeline", "Selected format: \(audioFile.format), isMP3: \(isMP3)")

        currentFormat = audioFile.format

        // Start playback with file ID
        try await play(
            trackUri: uri,
            fileId: audioFile.fileId,
            durationMs: UInt64(metadata.durationMs),
            positionMs: positionMs,
        )
    }

    /// Start playing a track with known file ID
    public func play(trackUri: String, fileId: Data, durationMs: UInt64 = 0, positionMs: UInt64 = 0) async throws {
        debugLog("AudioPipeline", "Playing: \(trackUri) from \(positionMs)ms")

        // Stop any existing playback
        await stopInternal()

        playbackStateSubject.send(.loading(trackUri: trackUri))

        // Get track ID from URI
        let trackId = extractTrackId(from: trackUri)

        // Get audio key from accesspoint
        let audioKey = try await audioKeyProvider.getKey(fileId: fileId, trackId: trackId)
        debugLog("AudioPipeline", "Got audio key (\(audioKey.count) bytes)")

        // Initialize decryptor with key
        decryptor.setKey(audioKey)

        // Resolve CDN URL
        guard let spclient else {
            throw LibrespotError.invalidState("SPClient not configured")
        }

        let cdnInfo = try await spclient.resolveCDNUrl(fileId: fileId)
        debugLog("AudioPipeline", "CDN URL resolved: \(cdnInfo.url.host ?? "?")")

        // Store track info
        currentTrack = TrackInfo(uri: trackUri, fileId: fileId, durationMs: durationMs, cdnUrl: cdnInfo.url)
        self.positionMs = positionMs
        isPlaying = true
        isPaused = false

        // Start streaming and decoding
        streamingTask = Task {
            await streamAndDecode(cdnUrl: cdnInfo.url, startPositionMs: positionMs)
        }

        // Start position tracking
        startPositionTimer()

        playbackStateSubject.send(.buffering(trackUri: trackUri))
    }

    /// Pause playback
    public func pause() async {
        guard let track = currentTrack, isPlaying else { return }

        debugLog("AudioPipeline", "Pausing")
        isPlaying = false
        isPaused = true
        await player?.pause()
        stopPositionTimer()
        playbackStateSubject.send(.paused(trackUri: track.uri))
    }

    /// Resume playback
    public func resume() async {
        guard let track = currentTrack, isPaused else { return }

        debugLog("AudioPipeline", "Resuming")
        isPlaying = true
        isPaused = false
        await player?.resume()
        startPositionTimer()
        playbackStateSubject.send(.playing(trackUri: track.uri))
    }

    /// Stop playback
    public func stop() async {
        debugLog("AudioPipeline", "Stopping")
        await stopInternal()
        playbackStateSubject.send(.idle)
        positionSubject.send(0)
    }

    /// Internal stop (doesn't send state updates)
    private func stopInternal() async {
        streamingTask?.cancel()
        streamingTask = nil
        stopPositionTimer()

        isPlaying = false
        isPaused = false
        currentTrack = nil
        currentFormat = nil
        decodedBuffers.removeAll()
        bufferScheduleIndex = 0

        await downloader.cancelDownload()
        await player?.stop()
    }

    /// Seek to position
    public func seek(positionMs: UInt64) async throws {
        guard let track = currentTrack else {
            throw LibrespotError.invalidState("No track playing")
        }

        debugLog("AudioPipeline", "Seeking to \(positionMs)ms")
        self.positionMs = positionMs

        // For now, seeking requires restarting the stream
        // A proper implementation would support seeking within the encrypted file
        await player?.seek(to: positionMs)
        positionSubject.send(positionMs)

        if isPaused {
            playbackStateSubject.send(.paused(trackUri: track.uri))
        } else {
            playbackStateSubject.send(.playing(trackUri: track.uri))
        }
    }

    /// Set playback volume (0.0 - 1.0)
    public func setVolume(_ volume: Float) async {
        await player?.setVolume(volume)
    }

    /// Get current position in milliseconds
    public func getCurrentPosition() -> UInt64 {
        positionMs
    }

    // MARK: - Streaming & Decoding

    /// Main streaming and decoding loop
    private func streamAndDecode(cdnUrl: URL, startPositionMs _: UInt64) async {
        do {
            // Start downloading from CDN
            try await downloader.startDownload(cdnUrl: cdnUrl, fileId: currentTrack?.fileId ?? Data())

            debugLog("AudioPipeline", "Download started, waiting for data...")

            // Wait for initial data to be ready
            var waitCount = 0
            while await !downloader.isReadyForPlayback() {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                waitCount += 1
                if waitCount > 50 { // 5 seconds timeout
                    throw LibrespotError.timeout("Timed out waiting for initial data")
                }
                if Task.isCancelled { return }
            }

            debugLog("AudioPipeline", "Initial data ready, starting decode")

            // Download and decrypt all data (simplified approach for MP3)
            // A more sophisticated implementation would stream chunks
            let encryptedData = try await downloadAllData()

            if Task.isCancelled { return }

            debugLog("AudioPipeline", "Downloaded \(encryptedData.count) bytes")

            // Decrypt the data
            // Spotify files have a 167-byte header that should not be decrypted
            let headerSize = 167
            // Header contains OGG/MP3 metadata - skip it for decryption
            let encryptedAudio = encryptedData.dropFirst(headerSize)

            decryptor.reset()
            let decryptedAudio = decryptor.decrypt(Data(encryptedAudio))

            debugLog("AudioPipeline", "Decrypted \(decryptedAudio.count) bytes")

            if Task.isCancelled { return }

            // Determine file type and decode
            let fileType: AudioFileType = if let format = currentFormat, SPClient.TrackMetadata.isMP3Format(format) {
                .mp3
            } else {
                .oggVorbis
            }

            // Decode to PCM
            let buffers = try simpleDecoder.decode(data: decryptedAudio, fileType: fileType)

            if Task.isCancelled { return }

            debugLog("AudioPipeline", "Decoded \(buffers.count) buffers")

            // Store decoded buffers
            decodedBuffers = buffers

            // Schedule initial buffers for playback
            await scheduleBuffers()

            // Start playback
            await player?.play()

            if let track = currentTrack {
                playbackStateSubject.send(.playing(trackUri: track.uri))
            }

            debugLog("AudioPipeline", "Playback started")

        } catch {
            if !Task.isCancelled {
                debugLog("AudioPipeline", "Streaming error: \(error)")
                playbackStateSubject.send(.error(error.localizedDescription))
                errorSubject.send(LibrespotError.unknown(error.localizedDescription))
            }
        }
    }

    /// Download all audio data
    private func downloadAllData() async throws -> Data {
        var allData = Data()
        var chunkIndex = 0

        while true {
            do {
                let chunkData = try await downloader.downloadChunk(index: chunkIndex)
                if chunkData.isEmpty {
                    break
                }
                allData.append(chunkData)
                chunkIndex += 1

                // Check if we've downloaded everything
                let progress = await downloader.downloadProgress()
                if progress >= 1.0 {
                    break
                }

                if Task.isCancelled { break }
            } catch {
                // Reached end of file or error
                break
            }
        }

        return allData
    }

    /// Schedule decoded buffers to player
    private func scheduleBuffers() async {
        let buffersToSchedule = min(10, decodedBuffers.count - bufferScheduleIndex)

        for _ in 0 ..< buffersToSchedule {
            guard bufferScheduleIndex < decodedBuffers.count else { break }
            let buffer = decodedBuffers[bufferScheduleIndex]
            // Wrap in SendableBuffer to safely cross actor boundary
            let sendable = SendableBuffer(buffer: buffer)
            await player?.scheduleBuffer(sendable.buffer)
            bufferScheduleIndex += 1
        }
    }

    // MARK: - Position Tracking

    private func startPositionTimer() {
        stopPositionTimer()

        positionTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms

                if isPlaying, !isPaused {
                    if let playerPosition = await player?.currentPositionMs() {
                        positionMs = playerPosition
                    }
                    positionSubject.send(positionMs)

                    // Check if playback finished
                    if let track = currentTrack,
                       track.durationMs > 0,
                       positionMs >= track.durationMs
                    {
                        debugLog("AudioPipeline", "Track finished")
                        await stop()
                    }

                    // Schedule more buffers if needed
                    if bufferScheduleIndex < decodedBuffers.count {
                        await scheduleBuffers()
                    }
                }
            }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.cancel()
        positionTimer = nil
    }

    // MARK: - Helpers

    private func extractTrackId(from uri: String) -> Data {
        // URI format: spotify:track:XXXX
        // Track ID is base62 encoded
        let components = uri.split(separator: ":")
        guard components.count == 3,
              let trackIdString = components.last
        else {
            return Data()
        }

        // Convert base62 to bytes
        return base62Decode(String(trackIdString))
    }

    private func base62Decode(_ string: String) -> Data {
        // Base62 alphabet: 0-9, a-z, A-Z
        let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

        var value = UInt128(0)
        for char in string {
            guard let index = alphabet.firstIndex(of: char) else { continue }
            let digit = alphabet.distance(from: alphabet.startIndex, to: index)
            value = value * UInt128(62) + UInt128(digit)
        }

        // Convert to 16 bytes (track IDs are 128-bit)
        var bytes = [UInt8](repeating: 0, count: 16)
        var v = value
        for i in (0 ..< 16).reversed() {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }

        return Data(bytes)
    }
}

/// 128-bit unsigned integer for base62 decoding
private struct UInt128: Sendable {
    var high: UInt64
    var low: UInt64

    nonisolated init(_ value: Int) {
        high = 0
        low = UInt64(value)
    }

    nonisolated init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    nonisolated static func * (lhs: UInt128, rhs: UInt128) -> UInt128 {
        // Simplified multiplication for our use case (small multiplier)
        let (low, overflow) = lhs.low.multipliedReportingOverflow(by: rhs.low)
        var high = lhs.high * rhs.low + lhs.low * rhs.high
        if overflow {
            high += 1
        }
        return UInt128(high: high, low: low)
    }

    nonisolated static func + (lhs: UInt128, rhs: UInt128) -> UInt128 {
        let (low, overflow) = lhs.low.addingReportingOverflow(rhs.low)
        var high = lhs.high + rhs.high
        if overflow {
            high += 1
        }
        return UInt128(high: high, low: low)
    }

    nonisolated static func >>= (lhs: inout UInt128, rhs: Int) {
        if rhs >= 64 {
            lhs.low = lhs.high >> (rhs - 64)
            lhs.high = 0
        } else {
            lhs.low = (lhs.low >> rhs) | (lhs.high << (64 - rhs))
            lhs.high >>= rhs
        }
    }

    nonisolated static func & (lhs: UInt128, rhs: Int) -> UInt64 {
        lhs.low & UInt64(rhs)
    }
}
