//
//  EntityConversions.swift
//  Spotifly
//
//  What is left of the wire-type → entity conversions after the partner-API migration.
//  Everything pathfinder and spclient return is converted in `PartnerAPI/`; these two are
//  the stragglers, one from the FFI and one shared by both playlist sources.
//

import Foundation

// MARK: - Device

/// A Connect device as Rust hands it over the FFI. The field names are the cluster's, which is
/// why they arrive snake-cased.
struct DeviceCodable: Decodable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool?
    let isPrivateSession: Bool?
    let isRestricted: Bool?
    let volumePercent: Int?
    let disableVolume: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active"
        case isPrivateSession = "is_private_session"
        case isRestricted = "is_restricted"
        case volumePercent = "volume_percent"
        case disableVolume = "disable_volume"
    }

    func toDevice() -> Device? {
        guard let id else { return nil }
        return Device(
            id: id,
            name: name,
            type: type,
            isActive: isActive ?? false,
            isPrivateSession: isPrivateSession ?? false,
            isRestricted: isRestricted ?? false,
            volumePercent: volumePercent,
            // Absent means nothing was declared, which is not a declaration that volume is
            // refused — so the slider stays live and the command decides, as before.
            disableVolume: disableVolume ?? false,
        )
    }
}

// MARK: - Playlist

extension String? {
    /// Spotify's playlist list answers with the literal string `"null"` when a playlist has no
    /// description, and the detail header rendered it verbatim — the view's `?? ""` never saw a
    /// nil to fall back from. Normalised at the entity boundary rather than in the view, so
    /// every reader gets the same answer.
    var normalizedPlaylistDescription: String? {
        guard let self, self != "null", !self.isEmpty else { return nil }
        return self
    }
}
