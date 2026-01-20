//
//  ConnectState.swift
//  SwiftLibrespot
//
//  Connect state builder and serialization
//

import Foundation

/// Builder for PutStateRequest messages
public struct ConnectStateBuilder: Sendable {
    private let deviceInfo: DeviceInfo

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
    }

    /// Build initial registration state (inactive device)
    public func buildRegistrationState() -> PutStateRequest {
        buildState(
            isActive: false,
            playerState: nil,
            startedPlayingAt: nil,
        )
    }

    /// Build active playback state
    func buildPlaybackState(
        playerState: SpircController.PlayerState,
        queue: SpircQueueState,
        startedPlayingAt: UInt64,
    ) -> PutStateRequest {
        let psProto = convertPlayerState(playerState, queue: queue)
        return buildState(
            isActive: true,
            playerState: psProto,
            startedPlayingAt: startedPlayingAt,
        )
    }

    /// Build paused state (still active but not playing)
    func buildPausedState(
        playerState: SpircController.PlayerState,
        queue: SpircQueueState,
    ) -> PutStateRequest {
        let psProto = convertPlayerState(playerState, queue: queue)
        return buildState(
            isActive: true,
            playerState: psProto,
            startedPlayingAt: nil,
        )
    }

    // MARK: - Private

    private func buildState(
        isActive: Bool,
        playerState: PutStateRequest.PutStatePlayerState?,
        startedPlayingAt: UInt64?,
    ) -> PutStateRequest {
        let deviceInfoProto = PutStateRequest.PutStateDeviceInfo(
            canPlay: deviceInfo.supportsPlayback,
            volume: 32768, // Default 50%
            name: deviceInfo.deviceName,
            deviceId: deviceInfo.deviceId,
            deviceType: deviceTypeString(deviceInfo.deviceType),
            deviceSoftwareVersion: deviceInfo.softwareVersion,
            clientId: "spotifly",
            brand: deviceInfo.brandName,
            model: deviceInfo.modelName,
            capabilities: PutStateRequest.PutStateCapabilities(
                canBePlayer: deviceInfo.supportsPlayback,
                gaplessTrack: deviceInfo.supportsGapless,
                supportsLogout: false,
                isObservable: true,
                volumeSteps: 64,
                supportedTypes: ["audio/track", "audio/episode", "audio/ad"],
                commandAcks: true,
            ),
        )

        return PutStateRequest(
            memberType: "CONNECT_STATE",
            device: PutStateRequest.PutStateDevice(
                deviceInfo: deviceInfoProto,
                playerState: playerState,
            ),
            isActive: isActive,
            startedPlayingAt: startedPlayingAt,
            lastCommandMessageId: nil,
            lastCommandSentByDeviceId: nil,
        )
    }

    private func convertPlayerState(
        _ ps: SpircController.PlayerState,
        queue: SpircQueueState,
    ) -> PutStateRequest.PutStatePlayerState {
        let track: ClusterUpdate.TrackProto? = if let uri = ps.trackUri {
            ClusterUpdate.TrackProto(
                uri: uri,
                uid: nil,
                metadata: nil,
                provider: "context",
            )
        } else {
            nil
        }

        let nextTracks = queue.nextTracks.map { item in
            ClusterUpdate.TrackProto(
                uri: item.uri,
                uid: nil,
                metadata: ClusterUpdate.TrackMetadata(
                    title: item.name,
                    artist: item.artistName,
                    album: nil,
                    imageUri: item.imageURLString,
                    durationMs: UInt64(item.durationMs),
                ),
                provider: item.provider,
            )
        }

        let prevTracks = (queue.previousTracks ?? []).map { item in
            ClusterUpdate.TrackProto(
                uri: item.uri,
                uid: nil,
                metadata: ClusterUpdate.TrackMetadata(
                    title: item.name,
                    artist: item.artistName,
                    album: nil,
                    imageUri: item.imageURLString,
                    durationMs: UInt64(item.durationMs),
                ),
                provider: item.provider,
            )
        }

        return PutStateRequest.PutStatePlayerState(
            timestamp: ps.timestamp,
            positionAsOfTimestamp: ps.positionMs,
            isPaused: ps.isPaused,
            isPlaying: ps.isPlaying,
            track: track,
            contextUri: nil,
            shuffle: ps.shuffle,
            repeatMode: convertRepeatMode(ps.repeatMode),
            nextTracks: nextTracks,
            prevTracks: prevTracks,
        )
    }

    private func convertRepeatMode(_ mode: SpircController.PlayerState.RepeatMode) -> ClusterUpdate.RepeatMode {
        switch mode {
        case .off: .off
        case .context: .context
        case .track: .track
        }
    }

    private func deviceTypeString(_ type: SpotifyDeviceType) -> String {
        switch type {
        case .computer: "COMPUTER"
        case .tablet: "TABLET"
        case .smartphone: "SMARTPHONE"
        case .speaker: "SPEAKER"
        case .tv: "TV"
        case .avr: "AVR"
        case .stb: "STB"
        case .audiodongle: "AUDIO_DONGLE"
        case .gameconsole: "GAME_CONSOLE"
        case .castvideo: "CAST_VIDEO"
        case .castaudio: "CAST_AUDIO"
        case .automobile: "AUTOMOBILE"
        case .smartwatch: "SMARTWATCH"
        case .chromebook: "CHROMEBOOK"
        case .carThing: "CAR_THING"
        case .observer: "OBSERVER"
        case .homeThing: "HOME_THING"
        default: "UNKNOWN"
        }
    }
}

/// Queue state for building PutStateRequest
struct SpircQueueState: Sendable {
    let currentTrack: QueueItem?
    let nextTracks: [QueueItem]
    let previousTracks: [QueueItem]?

    init(
        currentTrack: QueueItem?,
        nextTracks: [QueueItem],
        previousTracks: [QueueItem]?,
    ) {
        self.currentTrack = currentTrack
        self.nextTracks = nextTracks
        self.previousTracks = previousTracks
    }
}
