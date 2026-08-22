//
//  PacketTypes.swift
//  SwiftLibrespot
//
//  Spotify protocol packet types and structures
//

import Foundation

/// Packet command types for the Spotify protocol
public enum PacketType: UInt8, Sendable {
    // Connection
    case secretBlock = 0x02
    case ping = 0x04
    case streamChunk = 0x08
    case streamChunkRes = 0x09
    case channelError = 0x0A
    case channelAbort = 0x0B
    case requestKey = 0x0C
    case aesKey = 0x0D
    case aesKeyError = 0x0E

    // Authentication
    case login = 0xAB
    case apWelcome = 0xAC
    case authFailure = 0xAD
    case encryptedApWelcome = 0xAE

    // Mercury (Protobuf RPC)
    case mercuryReq = 0xB2
    case mercurySub = 0xB3
    case mercuryUnsub = 0xB4
    case mercuryEvent = 0xB5

    // Country/License
    case countryCode = 0x1B
    case licenseVersion = 0x76

    // Product info
    case productInfo = 0x50
    case legacyWelcome = 0x69

    // Note: audioKey is same as aesKey (0x0d), audioKeyError is same as aesKeyError (0x0e)

    /// Pong response
    case pong = 0x49

    /// Unknown/reserved (use 0x00 as we have no real unknown packet type)
    case unknown = 0x00
}

/// A packet in the Spotify protocol
public struct SpotifyPacket: Sendable {
    /// Command type
    public let command: PacketType

    /// Raw command byte (for unknown types)
    public let rawCommand: UInt8

    /// Packet payload
    public let payload: Data

    public nonisolated init(command: PacketType, payload: Data) {
        self.command = command
        rawCommand = command.rawValue
        self.payload = payload
    }

    public nonisolated init(rawCommand: UInt8, payload: Data) {
        self.rawCommand = rawCommand
        command = PacketType(rawValue: rawCommand) ?? .unknown
        self.payload = payload
    }

    /// Serialize packet for sending (command + length + payload)
    public nonisolated func serialize() -> Data {
        var data = Data()
        data.append(rawCommand)
        // Length is big-endian 16-bit
        let length = UInt16(payload.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }
}

