//
//  Connect.swift
//  SwiftLibrespot
//
//  Spotify Connect messages, from librespot's connect.proto and player.proto
//  (package spotify.connectstate).
//

import Foundation

// MARK: - Enums

/// Member type for PutStateRequest
public nonisolated enum MemberType: UInt32, Sendable {
    case spircV2 = 0
    case spircV3 = 1
    case connectState = 2
    case connectStateExtended = 5
    case activeDeviceTracker = 6
    case playToken = 7
}

/// Reason for PutStateRequest
public nonisolated enum PutStateReason: UInt32, Sendable {
    case unknown = 0
    case spircHello = 1
    case spircNotify = 2
    case newDevice = 3
    case playerStateChanged = 4
    case volumeChanged = 5
    case pickerOpened = 6
    case becameInactive = 7
    case aliasChanged = 8
    case newConnection = 9
    case pullPlayback = 10
    case audioDriverInfoChanged = 11
    case putStateRateLimited = 12
    case backendMetadataApplied = 13
}

/// Device type
public nonisolated enum DeviceType: UInt32, Sendable {
    case unknown = 0
    case computer = 1
    case tablet = 2
    case smartphone = 3
    case speaker = 4
    case tv = 5
    case avr = 6
    case stb = 7
    case audioDongle = 8
    case gameConsole = 9
    case castVideo = 10
    case castAudio = 11
    case automobile = 12
    case smartwatch = 13
    case chromebook = 14
    case unknownSpotify = 100
    case carThing = 101
    case observer = 102
    case homeThing = 103
}

/// Cluster update reason
public nonisolated enum ClusterUpdateReason: UInt32, Sendable {
    case unknown = 0
    case devicesDisappeared = 1
    case deviceStateChanged = 2
    case newDeviceAppeared = 3
    case deviceVolumeChanged = 4
    case deviceAliasChanged = 5
    case deviceNewConnection = 6
}

// MARK: - ConnectCapabilities

/// Device capabilities for Connect
public nonisolated struct ConnectCapabilities: Sendable {
    public var canBePlayer: Bool = true
    public var restrictToLocal: Bool = false
    public var gaiaEqConnectId: Bool = true
    public var supportsLogout: Bool = false
    public var isObservable: Bool = true
    public var volumeSteps: Int32 = 64
    public var supportedTypes: [String] = ["audio/track", "audio/episode"]
    public var commandAcks: Bool = true
    public var supportsRename: Bool = false
    public var hidden: Bool = false
    public var disableVolume: Bool = false
    public var connectDisabled: Bool = false
    public var supportsPlaylistV2: Bool = true
    public var isControllable: Bool = true
    public var supportsExternalEpisodes: Bool = true
    public var supportsSetBackendMetadata: Bool = true
    public var supportsTransferCommand: Bool = true
    public var supportsCommandRequest: Bool = true
    public var supportsGzipPushes: Bool = true
    public var supportsSetOptionsCommand: Bool = true
    public var needsFullPlayerState: Bool = false

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.flag(field: 2, canBePlayer)
            $0.flag(field: 3, restrictToLocal)
            $0.flag(field: 5, gaiaEqConnectId)
            $0.flag(field: 6, supportsLogout)
            $0.flag(field: 7, isObservable)
            $0.varint(field: 8, volumeSteps)
            for supportedType in supportedTypes {
                $0.string(field: 9, supportedType)
            }
            $0.flag(field: 10, commandAcks)
            $0.flag(field: 11, supportsRename)
            $0.flag(field: 12, hidden)
            $0.flag(field: 13, disableVolume)
            $0.flag(field: 14, connectDisabled)
            $0.flag(field: 15, supportsPlaylistV2)
            $0.flag(field: 16, isControllable)
            $0.flag(field: 17, supportsExternalEpisodes)
            $0.flag(field: 18, supportsSetBackendMetadata)
            $0.flag(field: 19, supportsTransferCommand)
            $0.flag(field: 20, supportsCommandRequest)
            $0.flag(field: 22, needsFullPlayerState)
            $0.flag(field: 23, supportsGzipPushes)
            $0.flag(field: 25, supportsSetOptionsCommand)
        }
    }

    /// Reads another device's capabilities. Only these four fields are read; everything
    /// else keeps this device's defaults, and the supported types add to them.
    /// Another device's capabilities, as the cluster lists them.
    ///
    /// `disable_volume` is the one the app acts on — Speakers hides the slider
    /// of a device that refuses volume — and it was never read, so every
    /// device got one. The defaults above are this device's own; a peer's
    /// supported types replace them rather than add to them.
    public static func parse(from data: Data) -> ConnectCapabilities {
        var caps = ConnectCapabilities()
        caps.supportedTypes = []
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 2: caps.canBePlayer = field.bool
            case 7: caps.isObservable = field.bool
            case 8: caps.volumeSteps = Int32(truncatingIfNeeded: field.value)
            case 9: caps.supportedTypes.append(field.string)
            case 13: caps.disableVolume = field.bool
            default: break
            }
        }
        return caps
    }
}

// MARK: - ConnectDeviceInfo

/// Device information for Connect state
public nonisolated struct ConnectDeviceInfo: Sendable {
    public var canPlay: Bool = true
    public var volume: UInt32 = 65535
    public var name: String = "Spotifly"
    public var capabilities: ConnectCapabilities = .init()
    public var deviceSoftwareVersion: String = "1.0.0"
    public var deviceType: DeviceType = .computer
    public var spircVersion: String = "3.2.6"
    public var deviceId: String = ""
    public var isPrivateSession: Bool = false
    public var isSocialConnect: Bool = false
    public var clientId: String = ""
    public var brand: String = "Apple"
    public var model: String = "Mac"

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.flag(field: 1, canPlay)
            $0.varint(field: 2, volume)
            $0.string(field: 3, name)
            $0.bytes(field: 4, capabilities.serialize())
            $0.string(field: 6, deviceSoftwareVersion)
            $0.varint(field: 7, deviceType.rawValue)
            $0.string(field: 9, spircVersion)
            $0.string(field: 10, deviceId)
            $0.flag(field: 11, isPrivateSession)
            $0.flag(field: 12, isSocialConnect)
            $0.nonEmptyString(field: 13, clientId)
            $0.string(field: 14, brand)
            $0.string(field: 15, model)
        }
    }

    /// Reads another device's entry in the cluster; fields not read keep this device's
    /// defaults.
    public static func parse(from data: Data) -> ConnectDeviceInfo {
        var info = ConnectDeviceInfo()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: info.canPlay = field.bool
            case 2: info.volume = UInt32(truncatingIfNeeded: field.value)
            case 3: info.name = field.string
            case 4: info.capabilities = ConnectCapabilities.parse(from: field.bytes)
            case 7: info.deviceType = DeviceType(rawValue: UInt32(truncatingIfNeeded: field.value)) ?? .unknown
            case 10: info.deviceId = field.string
            default: break
            }
        }
        return info
    }
}

// MARK: - ProvidedTrack

/// Track in player state
/// A context's metadata, as the resolver answers it and a player state's `context_metadata`
/// carries it.
public nonisolated extension [String: String] {
    /// What the context calls itself: `context_description`, where it is not empty.
    var contextName: String? {
        self["context_description"].flatMap { $0.isEmpty ? nil : $0 }
    }
}

public nonisolated struct ProvidedTrack: Sendable {
    public var uri: String = ""
    public var uid: String = ""
    public var metadata: [String: String] = [:]
    public var provider: String = ""
    public var albumUri: String = ""
    public var artistUri: String = ""

    public init() {}

    public init(uri: String, uid: String = "", provider: String = "context") {
        self.uri = uri
        self.uid = uid
        self.provider = provider
    }

    /// Whether other devices leave the row out of the queue they show: a delimiter, or a row
    /// the context will not play. Kept in `metadata`, as `"hidden": "true"`.
    public var isHidden: Bool {
        get { metadata["hidden"] == "true" }
        set { metadata["hidden"] = newValue ? "true" : nil }
    }

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.string(field: 1, uri)
            $0.nonEmptyString(field: 2, uid)
            $0.map(field: 3, metadata)
            $0.nonEmptyString(field: 6, provider)
            $0.nonEmptyString(field: 8, albumUri)
            $0.nonEmptyString(field: 10, artistUri)
        }
    }

    public static func parse(from data: Data) -> ProvidedTrack {
        var track = ProvidedTrack()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: track.uri = field.string
            case 2: track.uid = field.string
            case 3:
                let entry = field.mapEntry
                track.metadata[entry.key] = entry.value
            case 6: track.provider = field.string
            case 8: track.albumUri = field.string
            case 10: track.artistUri = field.string
            default: break
            }
        }
        return track
    }
}

// MARK: - ContextIndex

/// Where in its context the current track sits.
public nonisolated struct ContextIndex: Sendable, Equatable {
    public var page: UInt32
    public var track: UInt32

    public init(page: UInt32 = 0, track: UInt32 = 0) {
        self.page = page
        self.track = track
    }

    public func serialize() -> Data {
        ProtobufWriter.message {
            if page != 0 {
                $0.varint(field: 1, page)
            }
            if track != 0 {
                $0.varint(field: 2, track)
            }
        }
    }

    public static func parse(from data: Data) -> ContextIndex {
        var index = ContextIndex()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: index.page = UInt32(truncatingIfNeeded: field.value)
            case 2: index.track = UInt32(truncatingIfNeeded: field.value)
            default: break
            }
        }
        return index
    }
}

// MARK: - ContextPlayerOptions

/// Player options (shuffle, repeat)
public nonisolated struct ContextPlayerOptions: Sendable {
    public var shufflingContext: Bool = false
    public var repeatingContext: Bool = false
    public var repeatingTrack: Bool = false

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.flag(field: 1, shufflingContext)
            $0.flag(field: 2, repeatingContext)
            $0.flag(field: 3, repeatingTrack)
        }
    }

    public static func parse(from data: Data) -> ContextPlayerOptions {
        var options = ContextPlayerOptions()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: options.shufflingContext = field.bool
            case 2: options.repeatingContext = field.bool
            case 3: options.repeatingTrack = field.bool
            default: break
            }
        }
        return options
    }
}

// MARK: - PlayerState

/// Current player state
public nonisolated struct PlayerState: Sendable {
    public var timestamp: Int64 = 0
    public var contextUri: String = ""
    public var contextUrl: String = ""
    public var index: ContextIndex?
    public var positionAsOfTimestamp: Int64 = 0
    public var duration: Int64 = 0
    public var playbackSpeed: Double = 0
    public var isPlaying: Bool = false
    public var isPaused: Bool = false
    public var isBuffering: Bool = false
    public var isSystemInitiated: Bool = false
    public var options: ContextPlayerOptions = .init()
    public var track: ProvidedTrack?
    public var prevTracks: [ProvidedTrack] = []
    public var nextTracks: [ProvidedTrack] = []
    public var contextMetadata: [String: String] = [:]
    public var playbackId: String = ""
    public var sessionId: String = ""
    public var queueRevision: String = ""
    public var position: Int64 = 0
    /// Whether the device says Next cannot be pressed: its `restrictions` (field 17) name a
    /// `disallow_skipping_next_reason` (their field 7). Read, never written.
    public var disallowsSkippingNext = false

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.varint(field: 1, timestamp)
            $0.nonEmptyString(field: 2, contextUri)
            $0.nonEmptyString(field: 3, contextUrl)
            if let index {
                $0.bytes(field: 6, index.serialize())
            }
            if let track {
                $0.bytes(field: 7, track.serialize())
            }
            $0.nonEmptyString(field: 8, playbackId)
            if playbackSpeed != 0 {
                $0.double(field: 9, playbackSpeed)
            }
            $0.varint(field: 10, positionAsOfTimestamp)
            $0.varint(field: 11, duration)
            $0.flag(field: 12, isPlaying)
            $0.flag(field: 13, isPaused)
            $0.flag(field: 14, isBuffering)
            $0.flag(field: 15, isSystemInitiated)
            let optionsData = options.serialize()
            if !optionsData.isEmpty {
                $0.bytes(field: 16, optionsData)
            }
            for track in prevTracks {
                $0.bytes(field: 19, track.serialize())
            }
            for track in nextTracks {
                $0.bytes(field: 20, track.serialize())
            }
            $0.map(field: 21, contextMetadata)
            $0.nonEmptyString(field: 23, sessionId)
            $0.nonEmptyString(field: 24, queueRevision)
            $0.varint(field: 25, position)
        }
    }

    public static func parse(from data: Data) -> PlayerState {
        var state = PlayerState()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: state.timestamp = field.int64
            case 2: state.contextUri = field.string
            case 3: state.contextUrl = field.string
            case 6: state.index = ContextIndex.parse(from: field.bytes)
            case 7: state.track = ProvidedTrack.parse(from: field.bytes)
            case 8: state.playbackId = field.string
            case 9: state.playbackSpeed = field.double
            case 10: state.positionAsOfTimestamp = field.int64
            case 11: state.duration = field.int64
            case 12: state.isPlaying = field.bool
            case 13: state.isPaused = field.bool
            case 14: state.isBuffering = field.bool
            case 15: state.isSystemInitiated = field.bool
            case 16: state.options = ContextPlayerOptions.parse(from: field.bytes)
            case 17: state.disallowsSkippingNext = field.fields.contains { $0.number == 7 }
            case 19: state.prevTracks.append(ProvidedTrack.parse(from: field.bytes))
            case 20: state.nextTracks.append(ProvidedTrack.parse(from: field.bytes))
            case 21:
                let entry = field.mapEntry
                state.contextMetadata[entry.key] = entry.value
            case 23: state.sessionId = field.string
            case 24: state.queueRevision = field.string
            case 25: state.position = field.int64
            default: break
            }
        }
        return state
    }
}

// MARK: - Device (for PutStateRequest)

/// Device wrapper containing device info and player state
public nonisolated struct ConnectDevice: Sendable {
    public var deviceInfo: ConnectDeviceInfo = .init()
    public var playerState: PlayerState?
    public var transferData: Data?

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.bytes(field: 1, deviceInfo.serialize())
            if let playerState {
                $0.bytes(field: 2, playerState.serialize())
            }
            if let transferData {
                $0.bytes(field: 4, transferData)
            }
        }
    }
}

// MARK: - PutStateRequest

/// Request to update device state in Spotify Connect cluster
public nonisolated struct PutStateRequestProto: Sendable {
    public var callbackUrl: String = ""
    public var device: ConnectDevice = .init()
    public var memberType: MemberType = .connectState
    public var isActive: Bool = false
    public var putStateReason: PutStateReason = .newDevice
    public var messageId: UInt32 = 0
    public var lastCommandSentByDeviceId: String = ""
    public var lastCommandMessageId: UInt32 = 0
    public var startedPlayingAt: UInt64 = 0
    public var hasBeenPlayingForMs: UInt64 = 0
    public var clientSideTimestamp: UInt64 = 0
    public var onlyWritePlayerState: Bool = false

    public init() {}

    public func serialize() -> Data {
        ProtobufWriter.message {
            $0.nonEmptyString(field: 1, callbackUrl)
            $0.bytes(field: 2, device.serialize())
            $0.varint(field: 3, memberType.rawValue)
            $0.flag(field: 4, isActive)
            $0.varint(field: 5, putStateReason.rawValue)
            if messageId > 0 {
                $0.varint(field: 6, messageId)
            }
            $0.nonEmptyString(field: 7, lastCommandSentByDeviceId)
            if lastCommandMessageId > 0 {
                $0.varint(field: 8, lastCommandMessageId)
            }
            if startedPlayingAt > 0 {
                $0.varint(field: 9, startedPlayingAt)
            }
            if hasBeenPlayingForMs > 0 {
                $0.varint(field: 11, hasBeenPlayingForMs)
            }
            $0.varint(field: 12, clientSideTimestamp)
            $0.flag(field: 13, onlyWritePlayerState)
        }
    }
}

// MARK: - Cluster

/// Cluster containing all devices in the Connect group
public nonisolated struct Cluster: Sendable {
    public var changedTimestampMs: Int64 = 0
    public var activeDeviceId: String = ""
    public var playerState: PlayerState?
    public var devices: [String: ConnectDeviceInfo] = [:]
    public var transferData: Data?
    public var transferDataTimestamp: UInt64 = 0
    public var needFullPlayerState: Bool = false
    public var serverTimestampMs: Int64 = 0

    public init() {}

    /// Reads leniently, like every reader here, so it has nothing to throw; `throws` stays
    /// for the dealer's call sites.
    public static func parse(from data: Data) throws -> Cluster {
        var cluster = Cluster()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: cluster.changedTimestampMs = field.int64
            case 2: cluster.activeDeviceId = field.string
            case 3: cluster.playerState = PlayerState.parse(from: field.bytes)
            case 4:
                // map<string, DeviceInfo>: the entry's key in 1, the device in 2.
                let entry = field.fields
                cluster.devices[entry.last(1)?.string ?? ""] = ConnectDeviceInfo.parse(from: entry.last(2)?.bytes ?? Data())
            case 5: cluster.transferData = field.bytes
            case 6: cluster.transferDataTimestamp = field.value
            case 8: cluster.needFullPlayerState = field.bool
            case 9: cluster.serverTimestampMs = field.int64
            default: break
            }
        }
        return cluster
    }
}

// MARK: - ClusterUpdateProto

/// Cluster update message from dealer
public nonisolated struct ClusterUpdateProto: Sendable {
    public var cluster: Cluster = .init()
    public var updateReason: ClusterUpdateReason = .unknown
    public var ackId: String = ""
    public var devicesThatChanged: [String] = []

    public init() {}

    public static func parse(from data: Data) throws -> ClusterUpdateProto {
        var update = ClusterUpdateProto()
        for field in ProtobufReader.fields(in: data) {
            switch field.number {
            case 1: update.cluster = try Cluster.parse(from: field.bytes)
            case 2: update.updateReason = ClusterUpdateReason(rawValue: UInt32(truncatingIfNeeded: field.value)) ?? .unknown
            case 3: update.ackId = field.string
            case 4: update.devicesThatChanged.append(field.string)
            default: break
            }
        }
        return update
    }
}
