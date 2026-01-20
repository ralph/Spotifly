//
//  DeviceInfo.swift
//  SwiftLibrespot
//
//  Device identification and capabilities
//

import Foundation

/// Device type as defined by Spotify Connect protocol
public enum SpotifyDeviceType: Int, Sendable {
    case unknown = 0
    case computer = 1
    case tablet = 2
    case smartphone = 3
    case speaker = 4
    case tv = 5
    case avr = 6
    case stb = 7
    case audiodongle = 8
    case gameconsole = 9
    case castvideo = 10
    case castaudio = 11
    case automobile = 12
    case smartwatch = 13
    case chromebook = 14
    case unknownspotify = 100
    case carThing = 101
    case observer = 102
    case homeThing = 103
}

/// Information about this device for Spotify Connect registration
public struct DeviceInfo: Sendable {
    /// Unique device identifier (persisted across sessions)
    public let deviceId: String

    /// Human-readable device name shown in Spotify clients
    public let deviceName: String

    /// Device type for Spotify Connect
    public let deviceType: SpotifyDeviceType

    /// Brand name (e.g., "Apple")
    public let brandName: String

    /// Model name (e.g., "MacBook Pro")
    public let modelName: String

    /// Software version
    public let softwareVersion: String

    /// Whether this device supports audio playback
    public let supportsPlayback: Bool

    /// Whether this device supports volume control
    public let supportsVolume: Bool

    /// Whether this device supports gapless playback
    public let supportsGapless: Bool

    /// Whether this device can be a Spotify Connect controller
    public let canBeController: Bool

    /// Maximum supported audio bitrate
    public let maxBitrate: Int

    public init(
        deviceId: String,
        deviceName: String,
        deviceType: SpotifyDeviceType = .computer,
        brandName: String = "Apple",
        modelName: String = "Mac",
        softwareVersion: String = "1.0.0",
        supportsPlayback: Bool = true,
        supportsVolume: Bool = true,
        supportsGapless: Bool = true,
        canBeController: Bool = true,
        maxBitrate: Int = 320,
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.brandName = brandName
        self.modelName = modelName
        self.softwareVersion = softwareVersion
        self.supportsPlayback = supportsPlayback
        self.supportsVolume = supportsVolume
        self.supportsGapless = supportsGapless
        self.canBeController = canBeController
        self.maxBitrate = maxBitrate
    }

    /// Creates a DeviceInfo with auto-generated device ID from Keychain
    public static func create(name: String) -> DeviceInfo {
        let deviceId = getOrCreateDeviceId()
        return DeviceInfo(
            deviceId: deviceId,
            deviceName: name,
            deviceType: .computer,
            brandName: "Apple",
            modelName: getMacModel(),
            softwareVersion: getAppVersion(),
        )
    }

    /// Gets or creates a persistent device ID
    private static func getOrCreateDeviceId() -> String {
        let key = "SpotifyDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        // Generate a random 40-character hex string (like librespot)
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let deviceId = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(deviceId, forKey: key)
        return deviceId
    }

    /// Gets the Mac model identifier
    private static func getMacModel() -> String {
        #if os(macOS)
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            return String(cString: model)
        #else
            return "Apple Device"
        #endif
    }

    /// Gets the app version
    private static func getAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
