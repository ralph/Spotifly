//
//  Authentication.swift
//  SwiftLibrespot
//
//  Spotify authentication protocol messages (manual protobuf implementation)
//

import Foundation

// MARK: - Enums

/// Authentication type
public enum AuthenticationType: UInt32, Sendable {
    case userPass = 0
    case storedSpotifyCredentials = 1
    case storedFacebookCredentials = 2
    case spotifyToken = 3
    case facebookToken = 4
}

/// CPU family
public enum CpuFamily: UInt32, Sendable {
    case unknown = 0
    case x86 = 1
    case x8664 = 2
    case ppc = 3
    case ppc64 = 4
    case arm = 5
    case ia64 = 6
    case sh = 7
    case mips = 8
    case blackfin = 9
}

/// Operating system
public enum SpotifyOS: UInt32, Sendable {
    case unknown = 0
    case windows = 1
    case osx = 2
    case iphone = 3
    case s60 = 4
    case linux = 5
    case windowsCE = 6
    case android = 7
    case palm = 8
    case freebsd = 9
    case blackberry = 10
    case sonos = 11
    case logitech = 12
}

/// Account type
public enum AccountType: UInt32, Sendable {
    case spotify = 0
    case facebook = 1
}

// MARK: - Login Credentials

/// Login credentials for authentication
public struct LoginCredentials: Sendable {
    public let username: String?
    public let typ: AuthenticationType
    public let authData: Data?

    public nonisolated init(username: String?, typ: AuthenticationType, authData: Data?) {
        self.username = username
        self.typ = typ
        self.authData = authData
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): username (string, optional)
        if let username {
            let usernameData = username.data(using: .utf8)!
            data.append(contentsOf: [0x52]) // wire type 2, field 10
            data.append(contentsOf: encodeVarint(UInt64(usernameData.count)))
            data.append(usernameData)
        }

        // Field 20 (0x14): typ (varint, required)
        data.append(contentsOf: [0xA0, 0x01]) // wire type 0, field 20
        data.append(contentsOf: encodeVarint(UInt64(typ.rawValue)))

        // Field 30 (0x1e): auth_data (bytes, optional)
        if let authData {
            data.append(contentsOf: [0xF2, 0x01]) // wire type 2, field 30
            data.append(contentsOf: encodeVarint(UInt64(authData.count)))
            data.append(authData)
        }

        return data
    }
}

// MARK: - System Info

/// System information for device identification
public struct SystemInfo: Sendable {
    public let cpuFamily: CpuFamily
    public let os: SpotifyOS
    public let systemInformationString: String?
    public let deviceId: String?

    public nonisolated init(
        cpuFamily: CpuFamily,
        os: SpotifyOS,
        systemInformationString: String? = nil,
        deviceId: String? = nil
    ) {
        self.cpuFamily = cpuFamily
        self.os = os
        self.systemInformationString = systemInformationString
        self.deviceId = deviceId
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): cpu_family (varint)
        data.append(contentsOf: [0x50]) // wire type 0, field 10
        data.append(contentsOf: encodeVarint(UInt64(cpuFamily.rawValue)))

        // Field 60 (0x3c): os (varint)
        data.append(contentsOf: [0xE0, 0x03]) // wire type 0, field 60
        data.append(contentsOf: encodeVarint(UInt64(os.rawValue)))

        // Field 90 (0x5a): system_information_string (string)
        if let sysInfo = systemInformationString {
            let sysInfoData = sysInfo.data(using: .utf8)!
            data.append(contentsOf: [0xD2, 0x05]) // wire type 2, field 90
            data.append(contentsOf: encodeVarint(UInt64(sysInfoData.count)))
            data.append(sysInfoData)
        }

        // Field 100 (0x64): device_id (string)
        if let deviceId {
            let deviceIdData = deviceId.data(using: .utf8)!
            data.append(contentsOf: [0xA2, 0x06]) // wire type 2, field 100
            data.append(contentsOf: encodeVarint(UInt64(deviceIdData.count)))
            data.append(deviceIdData)
        }

        return data
    }
}

// MARK: - Client Response Encrypted

/// Encrypted client response with credentials
public struct ClientResponseEncrypted: Sendable {
    public let loginCredentials: LoginCredentials
    public let systemInfo: SystemInfo
    public let versionString: String?

    public nonisolated init(
        loginCredentials: LoginCredentials,
        systemInfo: SystemInfo,
        versionString: String? = nil
    ) {
        self.loginCredentials = loginCredentials
        self.systemInfo = systemInfo
        self.versionString = versionString
    }

    public nonisolated func serialize() -> Data {
        var data = Data()

        // Field 10 (0xa): login_credentials (message)
        let credsData = loginCredentials.serialize()
        data.append(contentsOf: [0x52]) // wire type 2, field 10
        data.append(contentsOf: encodeVarint(UInt64(credsData.count)))
        data.append(credsData)

        // Field 50 (0x32): system_info (message)
        let sysInfoData = systemInfo.serialize()
        data.append(contentsOf: [0x92, 0x03]) // wire type 2, field 50
        data.append(contentsOf: encodeVarint(UInt64(sysInfoData.count)))
        data.append(sysInfoData)

        // Field 70 (0x46): version_string (string)
        if let versionString {
            let versionData = versionString.data(using: .utf8)!
            data.append(contentsOf: [0xB2, 0x04]) // wire type 2, field 70
            data.append(contentsOf: encodeVarint(UInt64(versionData.count)))
            data.append(versionData)
        }

        return data
    }
}

// MARK: - AP Welcome

/// Welcome message after successful authentication
public struct APWelcome: Sendable {
    public let canonicalUsername: String
    public let accountTypeLoggedIn: AccountType
    public let credentialsTypeLoggedIn: AccountType
    public let reusableAuthCredentialsType: AuthenticationType
    public let reusableAuthCredentials: Data

    public nonisolated init(
        canonicalUsername: String,
        accountTypeLoggedIn: AccountType,
        credentialsTypeLoggedIn: AccountType,
        reusableAuthCredentialsType: AuthenticationType,
        reusableAuthCredentials: Data
    ) {
        self.canonicalUsername = canonicalUsername
        self.accountTypeLoggedIn = accountTypeLoggedIn
        self.credentialsTypeLoggedIn = credentialsTypeLoggedIn
        self.reusableAuthCredentialsType = reusableAuthCredentialsType
        self.reusableAuthCredentials = reusableAuthCredentials
    }

    /// Parse from protobuf binary data
    public static nonisolated func parse(from data: Data) throws -> APWelcome {
        var canonicalUsername: String?
        var accountTypeLoggedIn: AccountType = .spotify
        var credentialsTypeLoggedIn: AccountType = .spotify
        var reusableAuthCredentialsType: AuthenticationType = .storedSpotifyCredentials
        var reusableAuthCredentials = Data()

        var offset = 0
        while offset < data.count {
            let (fieldNumber, wireType, newOffset) = try parseTag(data: data, offset: offset)
            offset = newOffset

            switch (fieldNumber, wireType) {
            case (10, 2): // canonical_username
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                canonicalUsername = String(data: bytes, encoding: .utf8)

            case (20, 0): // account_type_logged_in
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                accountTypeLoggedIn = AccountType(rawValue: UInt32(value)) ?? .spotify

            case (25, 0): // credentials_type_logged_in
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                credentialsTypeLoggedIn = AccountType(rawValue: UInt32(value)) ?? .spotify

            case (30, 0): // reusable_auth_credentials_type
                let (value, nextOffset) = try parseVarint(data: data, offset: offset)
                offset = nextOffset
                reusableAuthCredentialsType = AuthenticationType(rawValue: UInt32(value)) ?? .storedSpotifyCredentials

            case (40, 2): // reusable_auth_credentials
                let (bytes, nextOffset) = try parseBytes(data: data, offset: offset)
                offset = nextOffset
                reusableAuthCredentials = bytes

            default:
                offset = try skipField(data: data, offset: offset, wireType: wireType)
            }
        }

        guard let username = canonicalUsername else {
            throw LibrespotError.authenticationFailed("Missing canonical username in APWelcome")
        }

        return APWelcome(
            canonicalUsername: username,
            accountTypeLoggedIn: accountTypeLoggedIn,
            credentialsTypeLoggedIn: credentialsTypeLoggedIn,
            reusableAuthCredentialsType: reusableAuthCredentialsType,
            reusableAuthCredentials: reusableAuthCredentials
        )
    }
}
