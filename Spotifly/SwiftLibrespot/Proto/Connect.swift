//
//  Connect.swift
//  SwiftLibrespot
//
//  Spotify Connect protocol messages (manual protobuf implementation)
//  Based on spotify/connectstate/connect.proto and player.proto
//

import Foundation

// MARK: - Enums

/// Member type for PutStateRequest
public enum MemberType: UInt32, Sendable {
    case spircV2 = 0
    case spircV3 = 1
    case connectState = 2
    case connectStateExtended = 5
    case activeDeviceTracker = 6
    case playToken = 7
}

/// Reason for PutStateRequest
public enum PutStateReason: UInt32, Sendable {
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
public enum DeviceType: UInt32, Sendable {
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
public enum ClusterUpdateReason: UInt32, Sendable {
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
public struct ConnectCapabilities: Sendable {
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

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 2: can_be_player
        if canBePlayer {
            data.append(contentsOf: [0x10, 0x01])
        }

        // Field 3: restrict_to_local
        if restrictToLocal {
            data.append(contentsOf: [0x18, 0x01])
        }

        // Field 5: gaia_eq_connect_id
        if gaiaEqConnectId {
            data.append(contentsOf: [0x28, 0x01])
        }

        // Field 6: supports_logout
        if supportsLogout {
            data.append(contentsOf: [0x30, 0x01])
        }

        // Field 7: is_observable
        if isObservable {
            data.append(contentsOf: [0x38, 0x01])
        }

        // Field 8: volume_steps
        data.append(0x40)
        data.append(contentsOf: encodeVarint(UInt64(volumeSteps)))

        // Field 9: supported_types (repeated string)
        for supportedType in supportedTypes {
            let typeData = supportedType.data(using: .utf8)!
            data.append(0x4A)
            data.append(contentsOf: encodeVarint(UInt64(typeData.count)))
            data.append(typeData)
        }

        // Field 10: command_acks
        if commandAcks {
            data.append(contentsOf: [0x50, 0x01])
        }

        // Field 11: supports_rename
        if supportsRename {
            data.append(contentsOf: [0x58, 0x01])
        }

        // Field 12: hidden
        if hidden {
            data.append(contentsOf: [0x60, 0x01])
        }

        // Field 13: disable_volume
        if disableVolume {
            data.append(contentsOf: [0x68, 0x01])
        }

        // Field 14: connect_disabled
        if connectDisabled {
            data.append(contentsOf: [0x70, 0x01])
        }

        // Field 15: supports_playlist_v2
        if supportsPlaylistV2 {
            data.append(contentsOf: [0x78, 0x01])
        }

        // Field 16: is_controllable
        if isControllable {
            data.append(contentsOf: [0x80, 0x01, 0x01])
        }

        // Field 17: supports_external_episodes
        if supportsExternalEpisodes {
            data.append(contentsOf: [0x88, 0x01, 0x01])
        }

        // Field 18: supports_set_backend_metadata
        if supportsSetBackendMetadata {
            data.append(contentsOf: [0x90, 0x01, 0x01])
        }

        // Field 19: supports_transfer_command
        if supportsTransferCommand {
            data.append(contentsOf: [0x98, 0x01, 0x01])
        }

        // Field 20: supports_command_request
        if supportsCommandRequest {
            data.append(contentsOf: [0xA0, 0x01, 0x01])
        }

        // Field 22: needs_full_player_state
        if needsFullPlayerState {
            data.append(contentsOf: [0xB0, 0x01, 0x01])
        }

        // Field 23: supports_gzip_pushes
        if supportsGzipPushes {
            data.append(contentsOf: [0xB8, 0x01, 0x01])
        }

        // Field 25: supports_set_options_command
        if supportsSetOptionsCommand {
            data.append(contentsOf: [0xC8, 0x01, 0x01])
        }

        return data
    }

    public nonisolated static func parse(from data: Data) throws -> ConnectCapabilities {
        var caps = ConnectCapabilities()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (2, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                caps.canBePlayer = value != 0

            case (7, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                caps.isObservable = value != 0

            case (8, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                caps.volumeSteps = Int32(value)

            case (9, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                if let str = String(data: bytes, encoding: .utf8) {
                    caps.supportedTypes.append(str)
                }

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return caps
    }
}

// MARK: - ConnectDeviceInfo

/// Device information for Connect state
public struct ConnectDeviceInfo: Sendable {
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

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: can_play
        if canPlay {
            data.append(contentsOf: [0x08, 0x01])
        }

        // Field 2: volume
        data.append(0x10)
        data.append(contentsOf: encodeVarint(UInt64(volume)))

        // Field 3: name
        let nameData = name.data(using: .utf8)!
        data.append(0x1A)
        data.append(contentsOf: encodeVarint(UInt64(nameData.count)))
        data.append(nameData)

        // Field 4: capabilities
        let capsData = capabilities.serialize()
        data.append(0x22)
        data.append(contentsOf: encodeVarint(UInt64(capsData.count)))
        data.append(capsData)

        // Field 6: device_software_version
        let versionData = deviceSoftwareVersion.data(using: .utf8)!
        data.append(0x32)
        data.append(contentsOf: encodeVarint(UInt64(versionData.count)))
        data.append(versionData)

        // Field 7: device_type
        data.append(0x38)
        data.append(contentsOf: encodeVarint(UInt64(deviceType.rawValue)))

        // Field 9: spirc_version
        let spircData = spircVersion.data(using: .utf8)!
        data.append(0x4A)
        data.append(contentsOf: encodeVarint(UInt64(spircData.count)))
        data.append(spircData)

        // Field 10: device_id
        let deviceIdData = deviceId.data(using: .utf8)!
        data.append(0x52)
        data.append(contentsOf: encodeVarint(UInt64(deviceIdData.count)))
        data.append(deviceIdData)

        // Field 11: is_private_session
        if isPrivateSession {
            data.append(contentsOf: [0x58, 0x01])
        }

        // Field 12: is_social_connect
        if isSocialConnect {
            data.append(contentsOf: [0x60, 0x01])
        }

        // Field 13: client_id
        if !clientId.isEmpty {
            let clientIdData = clientId.data(using: .utf8)!
            data.append(0x6A)
            data.append(contentsOf: encodeVarint(UInt64(clientIdData.count)))
            data.append(clientIdData)
        }

        // Field 14: brand
        let brandData = brand.data(using: .utf8)!
        data.append(0x72)
        data.append(contentsOf: encodeVarint(UInt64(brandData.count)))
        data.append(brandData)

        // Field 15: model
        let modelData = model.data(using: .utf8)!
        data.append(0x7A)
        data.append(contentsOf: encodeVarint(UInt64(modelData.count)))
        data.append(modelData)

        return data
    }

    public nonisolated static func parse(from data: Data) throws -> ConnectDeviceInfo {
        var info = ConnectDeviceInfo()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                info.canPlay = value != 0

            case (2, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                info.volume = UInt32(value)

            case (3, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                info.name = String(data: bytes, encoding: .utf8) ?? ""

            case (4, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                info.capabilities = try ConnectCapabilities.parse(from: bytes)

            case (7, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                info.deviceType = DeviceType(rawValue: UInt32(value)) ?? .unknown

            case (10, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                info.deviceId = String(data: bytes, encoding: .utf8) ?? ""

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return info
    }
}

// MARK: - ProvidedTrack

/// Track in player state
public struct ProvidedTrack: Sendable {
    public var uri: String = ""
    public var uid: String = ""
    public var metadata: [String: String] = [:]
    public var provider: String = ""
    public var albumUri: String = ""
    public var artistUri: String = ""

    public nonisolated init() {}

    public nonisolated init(uri: String, uid: String = "", provider: String = "context") {
        self.uri = uri
        self.uid = uid
        self.provider = provider
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: uri
        let uriData = uri.data(using: .utf8)!
        data.append(0x0A)
        data.append(contentsOf: encodeVarint(UInt64(uriData.count)))
        data.append(uriData)

        // Field 2: uid
        if !uid.isEmpty {
            let uidData = uid.data(using: .utf8)!
            data.append(0x12)
            data.append(contentsOf: encodeVarint(UInt64(uidData.count)))
            data.append(uidData)
        }

        // Field 3: metadata (map<string, string>)
        for (key, value) in metadata {
            var mapEntry = Data()
            // Key (field 1)
            let keyData = key.data(using: .utf8)!
            mapEntry.append(0x0A)
            mapEntry.append(contentsOf: encodeVarint(UInt64(keyData.count)))
            mapEntry.append(keyData)
            // Value (field 2)
            let valueData = value.data(using: .utf8)!
            mapEntry.append(0x12)
            mapEntry.append(contentsOf: encodeVarint(UInt64(valueData.count)))
            mapEntry.append(valueData)

            data.append(0x1A)
            data.append(contentsOf: encodeVarint(UInt64(mapEntry.count)))
            data.append(mapEntry)
        }

        // Field 6: provider
        if !provider.isEmpty {
            let providerData = provider.data(using: .utf8)!
            data.append(0x32)
            data.append(contentsOf: encodeVarint(UInt64(providerData.count)))
            data.append(providerData)
        }

        // Field 8: album_uri
        if !albumUri.isEmpty {
            let albumData = albumUri.data(using: .utf8)!
            data.append(0x42)
            data.append(contentsOf: encodeVarint(UInt64(albumData.count)))
            data.append(albumData)
        }

        // Field 10: artist_uri
        if !artistUri.isEmpty {
            let artistData = artistUri.data(using: .utf8)!
            data.append(0x52)
            data.append(contentsOf: encodeVarint(UInt64(artistData.count)))
            data.append(artistData)
        }

        return data
    }

    public nonisolated static func parse(from data: Data) throws -> ProvidedTrack {
        var track = ProvidedTrack()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                track.uri = String(data: bytes, encoding: .utf8) ?? ""

            case (2, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                track.uid = String(data: bytes, encoding: .utf8) ?? ""

            case (3, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                // Parse map entry
                let (key, value) = try parseMapEntry(from: bytes)
                track.metadata[key] = value

            case (6, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                track.provider = String(data: bytes, encoding: .utf8) ?? ""

            case (8, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                track.albumUri = String(data: bytes, encoding: .utf8) ?? ""

            case (10, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                track.artistUri = String(data: bytes, encoding: .utf8) ?? ""

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return track
    }
}

// MARK: - ContextPlayerOptions

/// Player options (shuffle, repeat)
public struct ContextPlayerOptions: Sendable {
    public var shufflingContext: Bool = false
    public var repeatingContext: Bool = false
    public var repeatingTrack: Bool = false

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: shuffling_context
        if shufflingContext {
            data.append(contentsOf: [0x08, 0x01])
        }

        // Field 2: repeating_context
        if repeatingContext {
            data.append(contentsOf: [0x10, 0x01])
        }

        // Field 3: repeating_track
        if repeatingTrack {
            data.append(contentsOf: [0x18, 0x01])
        }

        return data
    }

    public nonisolated static func parse(from data: Data) throws -> ContextPlayerOptions {
        var options = ContextPlayerOptions()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                options.shufflingContext = value != 0

            case (2, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                options.repeatingContext = value != 0

            case (3, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                options.repeatingTrack = value != 0

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return options
    }
}

// MARK: - PlayerState

/// Current player state
public struct PlayerState: Sendable {
    public var timestamp: Int64 = 0
    public var contextUri: String = ""
    public var positionAsOfTimestamp: Int64 = 0
    public var duration: Int64 = 0
    public var isPlaying: Bool = false
    public var isPaused: Bool = false
    public var isBuffering: Bool = false
    public var isSystemInitiated: Bool = false
    public var options: ContextPlayerOptions = .init()
    public var track: ProvidedTrack?
    public var prevTracks: [ProvidedTrack] = []
    public var nextTracks: [ProvidedTrack] = []
    public var playbackId: String = ""
    public var sessionId: String = ""
    public var position: Int64 = 0

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: timestamp
        data.append(0x08)
        data.append(contentsOf: encodeVarint(UInt64(bitPattern: timestamp)))

        // Field 2: context_uri
        if !contextUri.isEmpty {
            let uriData = contextUri.data(using: .utf8)!
            data.append(0x12)
            data.append(contentsOf: encodeVarint(UInt64(uriData.count)))
            data.append(uriData)
        }

        // Field 7: track
        if let track {
            let trackData = track.serialize()
            data.append(0x3A)
            data.append(contentsOf: encodeVarint(UInt64(trackData.count)))
            data.append(trackData)
        }

        // Field 8: playback_id
        if !playbackId.isEmpty {
            let pbData = playbackId.data(using: .utf8)!
            data.append(0x42)
            data.append(contentsOf: encodeVarint(UInt64(pbData.count)))
            data.append(pbData)
        }

        // Field 10: position_as_of_timestamp
        data.append(0x50)
        data.append(contentsOf: encodeVarint(UInt64(bitPattern: positionAsOfTimestamp)))

        // Field 11: duration
        data.append(0x58)
        data.append(contentsOf: encodeVarint(UInt64(bitPattern: duration)))

        // Field 12: is_playing
        if isPlaying {
            data.append(contentsOf: [0x60, 0x01])
        }

        // Field 13: is_paused
        if isPaused {
            data.append(contentsOf: [0x68, 0x01])
        }

        // Field 14: is_buffering
        if isBuffering {
            data.append(contentsOf: [0x70, 0x01])
        }

        // Field 15: is_system_initiated
        if isSystemInitiated {
            data.append(contentsOf: [0x78, 0x01])
        }

        // Field 16: options
        let optionsData = options.serialize()
        if !optionsData.isEmpty {
            data.append(contentsOf: [0x82, 0x01])
            data.append(contentsOf: encodeVarint(UInt64(optionsData.count)))
            data.append(optionsData)
        }

        // Field 19: prev_tracks
        for prevTrack in prevTracks {
            let trackData = prevTrack.serialize()
            data.append(contentsOf: [0x9A, 0x01])
            data.append(contentsOf: encodeVarint(UInt64(trackData.count)))
            data.append(trackData)
        }

        // Field 20: next_tracks
        for nextTrack in nextTracks {
            let trackData = nextTrack.serialize()
            data.append(contentsOf: [0xA2, 0x01])
            data.append(contentsOf: encodeVarint(UInt64(trackData.count)))
            data.append(trackData)
        }

        // Field 23: session_id
        if !sessionId.isEmpty {
            let sessData = sessionId.data(using: .utf8)!
            data.append(contentsOf: [0xBA, 0x01])
            data.append(contentsOf: encodeVarint(UInt64(sessData.count)))
            data.append(sessData)
        }

        // Field 25: position
        data.append(contentsOf: [0xC8, 0x01])
        data.append(contentsOf: encodeVarint(UInt64(bitPattern: position)))

        return data
    }

    public nonisolated static func parse(from data: Data) throws -> PlayerState {
        var state = PlayerState()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.timestamp = Int64(bitPattern: value)

            case (2, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                state.contextUri = String(data: bytes, encoding: .utf8) ?? ""

            case (7, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                state.track = try ProvidedTrack.parse(from: bytes)

            case (8, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                state.playbackId = String(data: bytes, encoding: .utf8) ?? ""

            case (10, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.positionAsOfTimestamp = Int64(bitPattern: value)

            case (11, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.duration = Int64(bitPattern: value)

            case (12, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.isPlaying = value != 0

            case (13, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.isPaused = value != 0

            case (14, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.isBuffering = value != 0

            case (15, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.isSystemInitiated = value != 0

            case (16, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                state.options = try ContextPlayerOptions.parse(from: bytes)

            case (19, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                try state.prevTracks.append(ProvidedTrack.parse(from: bytes))

            case (20, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                try state.nextTracks.append(ProvidedTrack.parse(from: bytes))

            case (23, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                state.sessionId = String(data: bytes, encoding: .utf8) ?? ""

            case (25, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                state.position = Int64(bitPattern: value)

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return state
    }
}

// MARK: - Device (for PutStateRequest)

/// Device wrapper containing device info and player state
public struct ConnectDevice: Sendable {
    public var deviceInfo: ConnectDeviceInfo = .init()
    public var playerState: PlayerState?
    public var transferData: Data?

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: device_info
        let infoData = deviceInfo.serialize()
        data.append(0x0A)
        data.append(contentsOf: encodeVarint(UInt64(infoData.count)))
        data.append(infoData)

        // Field 2: player_state
        if let playerState {
            let stateData = playerState.serialize()
            data.append(0x12)
            data.append(contentsOf: encodeVarint(UInt64(stateData.count)))
            data.append(stateData)
        }

        // Field 4: transfer_data
        if let transferData {
            data.append(0x22)
            data.append(contentsOf: encodeVarint(UInt64(transferData.count)))
            data.append(transferData)
        }

        return data
    }
}

// MARK: - PutStateRequest

/// Request to update device state in Spotify Connect cluster
public struct PutStateRequestProto: Sendable {
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

    public nonisolated init() {}

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 1: callback_url (only if non-empty)
        if !callbackUrl.isEmpty {
            let urlData = callbackUrl.data(using: .utf8)!
            data.append(0x0A)
            data.append(contentsOf: encodeVarint(UInt64(urlData.count)))
            data.append(urlData)
        }

        // Field 2: device
        let deviceData = device.serialize()
        data.append(0x12)
        data.append(contentsOf: encodeVarint(UInt64(deviceData.count)))
        data.append(deviceData)

        // Field 3: member_type
        data.append(0x18)
        data.append(contentsOf: encodeVarint(UInt64(memberType.rawValue)))

        // Field 4: is_active
        if isActive {
            data.append(contentsOf: [0x20, 0x01])
        }

        // Field 5: put_state_reason
        data.append(0x28)
        data.append(contentsOf: encodeVarint(UInt64(putStateReason.rawValue)))

        // Field 6: message_id
        if messageId > 0 {
            data.append(0x30)
            data.append(contentsOf: encodeVarint(UInt64(messageId)))
        }

        // Field 7: last_command_sent_by_device_id
        if !lastCommandSentByDeviceId.isEmpty {
            let devIdData = lastCommandSentByDeviceId.data(using: .utf8)!
            data.append(0x3A)
            data.append(contentsOf: encodeVarint(UInt64(devIdData.count)))
            data.append(devIdData)
        }

        // Field 8: last_command_message_id
        if lastCommandMessageId > 0 {
            data.append(0x40)
            data.append(contentsOf: encodeVarint(UInt64(lastCommandMessageId)))
        }

        // Field 9: started_playing_at
        if startedPlayingAt > 0 {
            data.append(0x48)
            data.append(contentsOf: encodeVarint(startedPlayingAt))
        }

        // Field 11: has_been_playing_for_ms
        if hasBeenPlayingForMs > 0 {
            data.append(0x58)
            data.append(contentsOf: encodeVarint(hasBeenPlayingForMs))
        }

        // Field 12: client_side_timestamp
        data.append(0x60)
        data.append(contentsOf: encodeVarint(clientSideTimestamp))

        // Field 13: only_write_player_state
        if onlyWritePlayerState {
            data.append(contentsOf: [0x68, 0x01])
        }

        return data
    }
}

// MARK: - Cluster

/// Cluster containing all devices in the Connect group
public struct Cluster: Sendable {
    public var changedTimestampMs: Int64 = 0
    public var activeDeviceId: String = ""
    public var playerState: PlayerState?
    public var devices: [String: ConnectDeviceInfo] = [:]
    public var transferData: Data?
    public var transferDataTimestamp: UInt64 = 0
    public var needFullPlayerState: Bool = false
    public var serverTimestampMs: Int64 = 0

    public nonisolated init() {}

    public nonisolated static func parse(from data: Data) throws -> Cluster {
        var cluster = Cluster()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                cluster.changedTimestampMs = Int64(bitPattern: value)

            case (2, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                cluster.activeDeviceId = String(data: bytes, encoding: .utf8) ?? ""

            case (3, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                cluster.playerState = try PlayerState.parse(from: bytes)

            case (4, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                // Parse map<string, ConnectDeviceInfo> entry
                let (key, deviceInfo) = try parseDeviceMapEntry(from: bytes)
                cluster.devices[key] = deviceInfo

            case (5, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                cluster.transferData = bytes

            case (6, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                cluster.transferDataTimestamp = value

            case (8, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                cluster.needFullPlayerState = value != 0

            case (9, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                cluster.serverTimestampMs = Int64(bitPattern: value)

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return cluster
    }
}

// MARK: - ClusterUpdateProto

/// Cluster update message from dealer
public struct ClusterUpdateProto: Sendable {
    public var cluster: Cluster = .init()
    public var updateReason: ClusterUpdateReason = .unknown
    public var ackId: String = ""
    public var devicesThatChanged: [String] = []

    public nonisolated init() {}

    public nonisolated static func parse(from data: Data) throws -> ClusterUpdateProto {
        var update = ClusterUpdateProto()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                update.cluster = try Cluster.parse(from: bytes)

            case (2, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                update.updateReason = ClusterUpdateReason(rawValue: UInt32(value)) ?? .unknown

            case (3, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                update.ackId = String(data: bytes, encoding: .utf8) ?? ""

            case (4, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                if let deviceId = String(data: bytes, encoding: .utf8) {
                    update.devicesThatChanged.append(deviceId)
                }

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return update
    }
}

// MARK: - SetVolumeCommand

/// Volume command from dealer
public struct SetVolumeCommandProto: Sendable {
    public var volume: Int32 = 0
    public var messageId: Int32 = 0
    public var sentByDeviceId: String = ""

    public nonisolated static func parse(from data: Data) throws -> SetVolumeCommandProto {
        var cmd = SetVolumeCommandProto()
        var offset = 0

        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (1, 0):
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                cmd.volume = Int32(value)

            case (2, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                // Parse command_options
                var optOffset = 0
                while optOffset < bytes.count {
                    let (optField, optWire, optNext) = try parseTag(data: bytes, offset: optOffset)
                    optOffset = optNext
                    if optField == 1, optWire == 0 {
                        let (value, nextOpt) = try parseVarint(data: bytes, offset: optOffset)
                        optOffset = nextOpt
                        cmd.messageId = Int32(value)
                    } else {
                        optOffset = try skipField(data: bytes, offset: optOffset, wireType: optWire)
                    }
                }

            case (5, 2):
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                cmd.sentByDeviceId = String(data: bytes, encoding: .utf8) ?? ""

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        return cmd
    }
}

// MARK: - Helpers

/// Parse a string-string map entry
private nonisolated func parseMapEntry(from data: Data) throws -> (String, String) {
    var key = ""
    var value = ""
    var offset = 0

    while offset < data.count {
        let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
        offset = newOffset

        switch (fieldNumber, wireType) {
        case (1, 2):
            let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
            offset = nextOffset
            key = String(data: bytes, encoding: .utf8) ?? ""

        case (2, 2):
            let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
            offset = nextOffset
            value = String(data: bytes, encoding: .utf8) ?? ""

        default:
            offset = try skipField(data: data, offset: offset, wireType: wireType)
        }
    }

    return (key, value)
}

/// Parse a device map entry (string -> ConnectDeviceInfo)
private nonisolated func parseDeviceMapEntry(from data: Data) throws -> (String, ConnectDeviceInfo) {
    var key = ""
    var deviceInfo = ConnectDeviceInfo()
    var offset = 0

    while offset < data.count {
        let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
        offset = newOffset

        switch (fieldNumber, wireType) {
        case (1, 2):
            let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
            offset = nextOffset
            key = String(data: bytes, encoding: .utf8) ?? ""

        case (2, 2):
            let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
            offset = nextOffset
            deviceInfo = try ConnectDeviceInfo.parse(from: bytes)

        default:
            offset = try skipField(data: data, offset: offset, wireType: wireType)
        }
    }

    return (key, deviceInfo)
}
