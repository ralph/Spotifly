//
//  DealerMessage.swift
//  SwiftLibrespot
//
//  JSON message types for the Spotify dealer WebSocket
//

@preconcurrency import Foundation

// MARK: - Incoming Messages

/// Wrapper for dealer messages
public struct DealerMessage: Sendable {
    public let type: String?
    public let uri: String?
    public let headers: [String: String]?
    public let payloads: [DealerPayload]?
    public let method: String?
    public let key: String?

    /// Connection info message
    public nonisolated var connectionId: String? {
        guard type == "message",
              uri == "hm://pusher/v1/connections/"
        else { return nil }
        return headers?["Spotify-Connection-Id"]
    }
}

extension DealerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, uri, headers, payloads, method, key
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        payloads = try container.decodeIfPresent([DealerPayload].self, forKey: .payloads)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        key = try container.decodeIfPresent(String.self, forKey: .key)
    }
}

/// Payload wrapper in dealer messages
public struct DealerPayload: Sendable {
    /// Base64-encoded protobuf or JSON payload
    public let payload: String?

    /// Decoded payload data
    public nonisolated var decodedData: Data? {
        guard let payload else { return nil }
        return Data(base64Encoded: payload)
    }
}

extension DealerPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case payload
    }

    public nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
    }
}

// MARK: - Cluster Update

/// ClusterUpdate message from dealer (contains device list and player state)
public struct ClusterUpdate: Sendable {
    public let cluster: Cluster

    public struct Cluster: Sendable {
        public let activeDeviceId: String?
        public let playerState: PlayerStateProto?
        public let devices: [DeviceProto]
        public let transferDataTimestamp: UInt64?
    }

    public struct PlayerStateProto: Sendable {
        public let timestamp: UInt64
        public let positionAsOfTimestamp: UInt64
        public let isPaused: Bool
        public let isPlaying: Bool
        public let isSystemInitiated: Bool
        public let track: TrackProto?
        public let contextUri: String?
        public let shuffle: Bool
        public let repeatMode: RepeatMode
    }

    public struct TrackProto: Sendable {
        public let uri: String
        public let uid: String?
        public let metadata: TrackMetadata?
        public let provider: String?
    }

    public struct TrackMetadata: Sendable {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let imageUri: String?
        public let durationMs: UInt64?
    }

    public struct DeviceProto: Sendable {
        public let deviceId: String
        public let deviceName: String
        public let deviceType: String
        public let isActive: Bool
        public let volume: UInt32
        public let capabilities: DeviceCapabilities?
    }

    public struct DeviceCapabilities: Sendable {
        public let canBePlayer: Bool
        public let gaplessTrack: Bool
        public let supportsLogout: Bool
        public let isObservable: Bool
        public let volumeSteps: Int
        public let supportedTypes: [String]
    }

    public enum RepeatMode: Int, Sendable {
        case off = 0
        case context = 1
        case track = 2
    }
}

// MARK: - SPIRC Commands

/// Commands that can be received from other Spotify clients
public enum SpircCommand: Sendable {
    case play(PlayCommand)
    case pause
    case resume
    case seekTo(positionMs: UInt64)
    case next
    case prev
    case setVolume(UInt32)
    case setShuffle(Bool)
    case setRepeat(ClusterUpdate.RepeatMode)
    case transfer(TransferCommand)
    case addToQueue(uri: String)
    case unknown(String)

    public struct PlayCommand: Sendable {
        public let contextUri: String?
        public let trackUri: String?
        public let trackUris: [String]?
        public let index: Int?
        public let positionMs: UInt64?
    }

    public struct TransferCommand: Sendable {
        public let targetDeviceId: String
        public let transferData: Data?
    }
}

// MARK: - Outgoing Messages

/// PutStateRequest for publishing device state
public struct PutStateRequest: Sendable {
    public let memberType: String // "CONNECT_STATE"
    public let device: PutStateDevice
    public let isActive: Bool
    public let startedPlayingAt: UInt64?
    public let lastCommandMessageId: UInt64?
    public let lastCommandSentByDeviceId: String?

    public struct PutStateDevice: Sendable {
        public let deviceInfo: PutStateDeviceInfo
        public let playerState: PutStatePlayerState?
    }

    public struct PutStateDeviceInfo: Sendable {
        public let canPlay: Bool
        public let volume: UInt32
        public let name: String
        public let deviceId: String
        public let deviceType: String
        public let deviceSoftwareVersion: String
        public let clientId: String
        public let brand: String
        public let model: String
        public let capabilities: PutStateCapabilities
    }

    public struct PutStateCapabilities: Sendable {
        public let canBePlayer: Bool
        public let gaplessTrack: Bool
        public let supportsLogout: Bool
        public let isObservable: Bool
        public let volumeSteps: Int
        public let supportedTypes: [String]
        public let commandAcks: Bool
    }

    public struct PutStatePlayerState: Sendable {
        public let timestamp: UInt64
        public let positionAsOfTimestamp: UInt64
        public let isPaused: Bool
        public let isPlaying: Bool
        public let track: ClusterUpdate.TrackProto?
        public let contextUri: String?
        public let shuffle: Bool
        public let repeatMode: ClusterUpdate.RepeatMode
        public let nextTracks: [ClusterUpdate.TrackProto]
        public let prevTracks: [ClusterUpdate.TrackProto]
    }
}
