//
//  AVFoundationPlayer.swift
//  SwiftLibrespot
//
//  AVAudioEngine-based audio output
//

import AVFoundation
import Combine
import Foundation

/// Audio output using AVAudioEngine
/// Supports AirPlay 2 and system audio routing
/// Note: AVAudioEngine requires main thread execution
@MainActor
public final class AVFoundationPlayer: Sendable {
    // MARK: - Properties

    private var engine: AVAudioEngine
    private var playerNode: AVAudioPlayerNode
    private var mixerNode: AVAudioMixerNode

    /// Output format
    private let format: AVAudioFormat

    /// Current volume (0.0 - 1.0)
    private var volume: Float = 1.0

    /// Whether playback is active
    private var isActive = false

    /// Buffer scheduling queue
    private var bufferQueue: [AVAudioPCMBuffer] = []

    /// Position tracking
    private var startSampleTime: AVAudioFramePosition = 0
    private var pausedSampleTime: AVAudioFramePosition = 0

    // MARK: - Publishers

    private let playbackEndedSubject = PassthroughSubject<Void, Never>()

    public var playbackEnded: AnyPublisher<Void, Never> {
        playbackEndedSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        mixerNode = engine.mainMixerNode

        // Standard Spotify format: 44.1kHz, stereo, float32
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 2,
            interleaved: false,
        )!

        // Setup is done in start() instead of init due to actor isolation
        debugLog("AVFoundationPlayer", "Initialized")
    }

    /// Start the audio engine (must be called before playback)
    public func start() {
        setupAudioEngine()
    }

    // MARK: - Setup

    private func setupAudioEngine() {
        // Attach player node
        engine.attach(playerNode)

        // Connect player to mixer
        engine.connect(playerNode, to: mixerNode, format: format)

        // Set initial volume
        playerNode.volume = volume

        // Start engine
        do {
            try engine.start()
            debugLog("AVFoundationPlayer", "Audio engine started")
        } catch {
            debugLog("AVFoundationPlayer", "Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Playback

    /// Schedule a buffer for playback
    public func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer) { [weak self] in
            // Callback runs on audio thread, dispatch to main
            Task { @MainActor [weak self] in
                self?.bufferCompleted()
            }
        }
    }

    /// Start playback
    public func play() {
        guard !isActive else { return }

        if !engine.isRunning {
            try? engine.start()
        }

        playerNode.play()
        isActive = true
        startSampleTime = playerNode.lastRenderTime?.sampleTime ?? 0

        debugLog("AVFoundationPlayer", "Playback started")
    }

    /// Pause playback
    public func pause() {
        guard isActive else { return }

        playerNode.pause()
        pausedSampleTime = currentSampleTime()
        isActive = false

        debugLog("AVFoundationPlayer", "Playback paused")
    }

    /// Resume playback
    public func resume() {
        guard !isActive else { return }

        playerNode.play()
        isActive = true

        debugLog("AVFoundationPlayer", "Playback resumed")
    }

    /// Stop playback
    public func stop() {
        playerNode.stop()
        isActive = false
        bufferQueue.removeAll()
        startSampleTime = 0
        pausedSampleTime = 0

        debugLog("AVFoundationPlayer", "Playback stopped")
    }

    /// Seek to position (in milliseconds)
    public func seek(to positionMs: UInt64) {
        // Note: Seeking requires re-scheduling buffers from the new position
        // This is a simplified implementation
        debugLog("AVFoundationPlayer", "Seek to \(positionMs)ms")

        // Clear current buffers
        playerNode.stop()
        bufferQueue.removeAll()

        // Update position tracking
        let sampleRate = format.sampleRate
        startSampleTime = Int64(Double(positionMs) * sampleRate / 1000.0)

        // Resume if was playing
        if isActive {
            playerNode.play()
        }
    }

    // MARK: - Volume

    /// Set playback volume (0.0 - 1.0)
    public func setVolume(_ newVolume: Float) {
        volume = max(0, min(1, newVolume))
        playerNode.volume = volume
        debugLog("AVFoundationPlayer", "Volume set to \(volume)")
    }

    /// Get current volume
    public func getVolume() -> Float {
        volume
    }

    // MARK: - Position

    /// Get current playback position in milliseconds
    public func currentPositionMs() -> UInt64 {
        let samples = currentSampleTime()
        let sampleRate = format.sampleRate
        return UInt64(Double(samples) * 1000.0 / sampleRate)
    }

    private func currentSampleTime() -> AVAudioFramePosition {
        if isActive {
            if let nodeTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
            {
                return playerTime.sampleTime
            }
        }
        return pausedSampleTime
    }

    // MARK: - Audio Session

    /// Configure audio session for playback
    public func configureAudioSession() {
        #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
                try session.setActive(true)
                debugLog("AVFoundationPlayer", "Audio session configured")
            } catch {
                debugLog("AVFoundationPlayer", "Audio session configuration failed: \(error)")
            }
        #endif
    }

    // MARK: - Private

    private func bufferCompleted() {
        // Remove completed buffer from queue
        if !bufferQueue.isEmpty {
            bufferQueue.removeFirst()
        }

        // Signal if all buffers completed
        if bufferQueue.isEmpty, isActive {
            playbackEndedSubject.send()
        }
    }

    // MARK: - Cleanup

    public func cleanup() {
        stop()
        engine.stop()
        debugLog("AVFoundationPlayer", "Cleaned up")
    }
}

// MARK: - Audio Route Handling

public extension AVFoundationPlayer {
    /// Get available audio output routes
    func getAvailableRoutes() -> [AudioRoute] {
        var routes: [AudioRoute] = []

        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if let outputs = session.currentRoute.outputs.first {
                routes.append(AudioRoute(
                    id: outputs.uid,
                    name: outputs.portName,
                    type: mapPortType(outputs.portType),
                ))
            }
        #else
            // macOS: Use default output
            routes.append(AudioRoute(
                id: "default",
                name: "System Output",
                type: .builtIn,
            ))
        #endif

        return routes
    }

    struct AudioRoute: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let type: RouteType

        public enum RouteType: Sendable {
            case builtIn
            case headphones
            case bluetooth
            case airPlay
            case hdmi
            case other
        }
    }

    #if os(iOS)
        private func mapPortType(_ portType: AVAudioSession.Port) -> AudioRoute.RouteType {
            switch portType {
            case .builtInSpeaker, .builtInReceiver:
                .builtIn
            case .headphones, .headsetMic:
                .headphones
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                .bluetooth
            case .airPlay:
                .airPlay
            case .HDMI:
                .hdmi
            default:
                .other
            }
        }
    #endif
}
