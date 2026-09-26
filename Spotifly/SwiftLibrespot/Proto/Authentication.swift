//
//  Authentication.swift
//  SwiftLibrespot
//
//  The accesspoint login, from librespot's authentication.proto: the
//  ClientResponseEncrypted we send and the APWelcome it is answered with.
//

import Foundation

/// What a login authenticates with. An APWelcome names the type of the reusable credentials
/// it hands back, and that raw value is stored beside them.
public nonisolated enum AuthenticationType: UInt32, Sendable {
    case userPass = 0
    case storedSpotifyCredentials = 1
    case storedFacebookCredentials = 2
    case spotifyToken = 3
    case facebookToken = 4
}

public nonisolated enum CpuFamily: UInt32, Sendable {
    case unknown = 0
    case x8664 = 2
    case arm = 5
}

public nonisolated enum SpotifyOS: UInt32, Sendable {
    case osx = 2
    case iphone = 3
    case linux = 5
}

nonisolated enum Authentication {
    /// `ClientResponseEncrypted`, the login packet: the credentials, plus the device they are
    /// used from. `version` is sent both as the system information string and as the version
    /// string, as librespot does.
    static func clientResponseEncrypted(
        username: String,
        authType: AuthenticationType,
        authData: Data,
        cpuFamily: CpuFamily,
        os: SpotifyOS,
        deviceId: String,
        version: String,
    ) -> Data {
        ProtobufWriter.message {
            $0.message(field: 10) { credentials in
                credentials.string(field: 10, username)
                credentials.varint(field: 20, authType.rawValue) // typ
                credentials.bytes(field: 30, authData)
            }
            $0.message(field: 50) { systemInfo in
                systemInfo.varint(field: 10, cpuFamily.rawValue)
                systemInfo.varint(field: 60, os.rawValue)
                systemInfo.string(field: 90, version) // system_information_string
                systemInfo.string(field: 100, deviceId)
            }
            $0.string(field: 70, version) // version_string
        }
    }
}

/// The accesspoint's answer to a successful login.
public nonisolated struct APWelcome: Sendable {
    public let canonicalUsername: String
    /// What later logins authenticate with instead of a fresh OAuth token.
    public let reusableAuthCredentials: Data
    public let reusableAuthCredentialsType: AuthenticationType

    /// `APWelcome { 10: canonical_username, 30: reusable_auth_credentials_type,
    /// 40: reusable_auth_credentials }`.
    static func parse(from data: Data) throws -> APWelcome {
        let fields = ProtobufReader.fields(in: data)
        guard let username = fields.last(10)?.string else {
            throw LibrespotError.authenticationFailed("Missing canonical username in APWelcome")
        }
        let type = fields.last(30).flatMap { AuthenticationType(rawValue: UInt32(truncatingIfNeeded: $0.value)) }

        return APWelcome(
            canonicalUsername: username,
            reusableAuthCredentials: fields.last(40)?.bytes ?? Data(),
            reusableAuthCredentialsType: type ?? .storedSpotifyCredentials,
        )
    }
}
