//
//  ConnectState.swift
//  SwiftLibrespot
//
//  Connect state builder and serialization
//

import Foundation

/// Builder for PutStateRequest messages
/// Note: Primary building is now done in SpircController. This provides convenience helpers.
public struct ConnectStateBuilder: Sendable {
    private let deviceInfo: DeviceInfo

    public init(deviceInfo: DeviceInfo) {
        self.deviceInfo = deviceInfo
    }

    /// Build initial registration state (inactive device)
    public func buildRegistrationState() -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = buildDevice(playerState: nil)
        request.memberType = .connectState
        request.isActive = false
        request.putStateReason = .spircHello
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return request
    }

    /// Build active playback state
    public func buildPlaybackState(
        playerState: SpircController.SpircPlayerState,
        startedPlayingAt: UInt64,
    ) -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = buildDevice(playerState: playerState)
        request.memberType = .connectState
        request.isActive = true
        request.putStateReason = .playerStateChanged
        request.startedPlayingAt = startedPlayingAt
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return request
    }

    /// Build paused state (still active but not playing)
    public func buildPausedState(
        playerState: SpircController.SpircPlayerState,
    ) -> PutStateRequestProto {
        var request = PutStateRequestProto()
        request.device = buildDevice(playerState: playerState)
        request.memberType = .connectState
        request.isActive = true
        request.putStateReason = .playerStateChanged
        request.clientSideTimestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return request
    }

    // MARK: - Private

    private func buildDevice(playerState: SpircController.SpircPlayerState?) -> ConnectDevice {
        var deviceInfoProto = ConnectDeviceInfo()
        deviceInfoProto.canPlay = deviceInfo.supportsPlayback
        deviceInfoProto.volume = 32768 // Default 50%
        deviceInfoProto.name = deviceInfo.deviceName
        deviceInfoProto.deviceId = deviceInfo.deviceId
        deviceInfoProto.deviceType = convertDeviceType(deviceInfo.deviceType)
        deviceInfoProto.deviceSoftwareVersion = deviceInfo.softwareVersion
        deviceInfoProto.clientId = "spotifly"
        deviceInfoProto.brand = deviceInfo.brandName
        deviceInfoProto.model = deviceInfo.modelName

        var caps = ConnectCapabilities()
        caps.canBePlayer = deviceInfo.supportsPlayback
        caps.isObservable = true
        caps.volumeSteps = 64
        caps.supportedTypes = ["audio/track", "audio/episode", "audio/ad"]
        caps.commandAcks = true
        caps.supportsGzipPushes = true
        caps.supportsTransferCommand = true
        caps.supportsCommandRequest = true
        deviceInfoProto.capabilities = caps

        var device = ConnectDevice()
        device.deviceInfo = deviceInfoProto

        if let ps = playerState {
            device.playerState = convertPlayerState(ps)
        }

        return device
    }

    private func convertPlayerState(_ ps: SpircController.SpircPlayerState) -> PlayerState {
        var state = PlayerState()
        state.timestamp = Int64(ps.timestamp)
        state.positionAsOfTimestamp = Int64(ps.positionMs)
        state.duration = Int64(ps.durationMs)
        state.isPlaying = ps.isPlaying
        state.isPaused = ps.isPaused

        if let uri = ps.trackUri {
            var track = ProvidedTrack()
            track.uri = uri
            track.provider = "context"
            state.track = track
        }

        var options = ContextPlayerOptions()
        options.shufflingContext = ps.shuffle
        options.repeatingContext = ps.repeatMode == .context
        options.repeatingTrack = ps.repeatMode == .track
        state.options = options

        return state
    }

    private func convertDeviceType(_ type: SpotifyDeviceType) -> DeviceType {
        switch type {
        case .computer: .computer
        case .tablet: .tablet
        case .smartphone: .smartphone
        case .speaker: .speaker
        case .tv: .tv
        case .avr: .avr
        case .stb: .stb
        case .audiodongle: .audioDongle
        case .gameconsole: .gameConsole
        case .castvideo: .castVideo
        case .castaudio: .castAudio
        case .automobile: .automobile
        case .smartwatch: .smartwatch
        case .chromebook: .chromebook
        case .carThing: .carThing
        case .observer: .observer
        case .homeThing: .homeThing
        default: .unknown
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
