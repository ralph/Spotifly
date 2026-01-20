//
//  APResolver.swift
//  SwiftLibrespot
//
//  Resolves Spotify accesspoint and dealer endpoints
//

import Foundation

/// Resolved endpoints from apresolve.spotify.com
public struct ResolvedEndpoints: Sendable {
    public let accesspoints: [String]
    public let dealers: [String]
    public let spclients: [String]
}

/// Resolves Spotify backend endpoints
public struct APResolver: Sendable {
    private let baseURL = "https://apresolve.spotify.com"

    public nonisolated init() {}

    /// Resolve all endpoint types
    public func resolve() async throws -> ResolvedEndpoints {
        let url = URL(string: "\(baseURL)?type=accesspoint&type=dealer&type=spclient")!

        debugLog("APResolver", "Resolving endpoints from \(url)")

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw LibrespotError.connectionFailed("AP resolve failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibrespotError.connectionFailed("Invalid AP resolve response")
        }

        let accesspoints = json["accesspoint"] as? [String] ?? []
        let dealers = json["dealer"] as? [String] ?? []
        let spclients = json["spclient"] as? [String] ?? []

        debugLog("APResolver", "Resolved: \(accesspoints.count) APs, \(dealers.count) dealers, \(spclients.count) spclients")

        return ResolvedEndpoints(
            accesspoints: accesspoints,
            dealers: dealers,
            spclients: spclients,
        )
    }

    /// Resolve only accesspoint endpoints
    public func resolveAccesspoints() async throws -> [String] {
        let url = URL(string: "\(baseURL)?type=accesspoint")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accesspoints = json["accesspoint"] as? [String]
        else {
            throw LibrespotError.connectionFailed("Failed to resolve accesspoints")
        }

        return accesspoints
    }

    /// Resolve only dealer endpoints
    public func resolveDealers() async throws -> [String] {
        let url = URL(string: "\(baseURL)?type=dealer")!
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dealers = json["dealer"] as? [String]
        else {
            throw LibrespotError.connectionFailed("Failed to resolve dealers")
        }

        return dealers
    }
}
