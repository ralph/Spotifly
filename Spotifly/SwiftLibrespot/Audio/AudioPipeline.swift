//
//  AudioPipeline.swift
//  SwiftLibrespot
//
//  Orchestrates audio decryption, decoding, and playback
//

import AVFoundation
import Combine
import Foundation

/// Main audio pipeline for Spotify playback
/// Coordinates downloading, decryption, decoding, and playback
public actor AudioPipeline {
    // MARK: - Properties

    private let accesspoint: Accesspoint
    private let audioKeyProvider: AudioKeyProvider
    private let decryptor: AESDecryptor
    private let downloader: ChunkedDownloader
    private let player: AVFoundationPlayer

    /// Current track being played
    private var currentTrack: TrackInfo?

    /// Playback state
    private var isPlaying = false
    private var isPaused = false
    private var positionMs: UInt64 = 0

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
    }

    // MARK: - Initialization

    public init(accesspoint: Accesspoint) {
        self.accesspoint = accesspoint
        audioKeyProvider = AudioKeyProvider(accesspoint: accesspoint)
        decryptor = AESDecryptor()
        downloader = ChunkedDownloader()
        player = AVFoundationPlayer()

        debugLog("AudioPipeline", "Initialized")
    }

    // MARK: - Playback Control

    /// Start playing a track
    public func play(trackUri: String, fileId: Data, positionMs: UInt64 = 0) async throws {
        debugLog("AudioPipeline", "Playing: \(trackUri) from \(positionMs)ms")

        playbackStateSubject.send(.loading(trackUri: trackUri))

        // Get track ID from URI
        let trackId = extractTrackId(from: trackUri)

        // Get audio key from accesspoint
        let audioKey = try await audioKeyProvider.getKey(fileId: fileId, trackId: trackId)
        debugLog("AudioPipeline", "Got audio key (\(audioKey.count) bytes)")

        // Initialize decryptor with key
        decryptor.setKey(audioKey)

        // TODO: Resolve CDN URL and start downloading
        // TODO: Feed decrypted chunks to decoder
        // TODO: Feed decoded PCM to player

        currentTrack = TrackInfo(uri: trackUri, fileId: fileId, durationMs: 0)
        self.positionMs = positionMs
        isPlaying = true
        isPaused = false

        playbackStateSubject.send(.playing(trackUri: trackUri))
        positionSubject.send(positionMs)

        debugLog("AudioPipeline", "Playback started (stub)")
    }

    /// Pause playback
    public func pause() async {
        guard let track = currentTrack, isPlaying else { return }

        debugLog("AudioPipeline", "Pausing")
        isPlaying = false
        isPaused = true
        await player.pause()
        playbackStateSubject.send(.paused(trackUri: track.uri))
    }

    /// Resume playback
    public func resume() async {
        guard let track = currentTrack, isPaused else { return }

        debugLog("AudioPipeline", "Resuming")
        isPlaying = true
        isPaused = false
        await player.resume()
        playbackStateSubject.send(.playing(trackUri: track.uri))
    }

    /// Stop playback
    public func stop() async {
        debugLog("AudioPipeline", "Stopping")
        isPlaying = false
        isPaused = false
        currentTrack = nil
        await player.stop()
        playbackStateSubject.send(.idle)
        positionSubject.send(0)
    }

    /// Seek to position
    public func seek(positionMs: UInt64) async throws {
        guard let track = currentTrack else {
            throw LibrespotError.invalidState("No track playing")
        }

        debugLog("AudioPipeline", "Seeking to \(positionMs)ms")
        self.positionMs = positionMs
        await player.seek(to: positionMs)
        positionSubject.send(positionMs)

        if isPaused {
            playbackStateSubject.send(.paused(trackUri: track.uri))
        } else {
            playbackStateSubject.send(.playing(trackUri: track.uri))
        }
    }

    /// Set playback volume (0.0 - 1.0)
    public func setVolume(_ volume: Float) async {
        await player.setVolume(volume)
    }

    /// Get current position in milliseconds
    public func getCurrentPosition() -> UInt64 {
        positionMs
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
