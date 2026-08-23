//
//  EntityConversions.swift
//  Spotifly
//
//  What is left of the wire-type → entity conversions after the partner-API migration.
//  Everything pathfinder and spclient return is converted in `PartnerAPI/`; this one
//  straggler is shared by both playlist sources.
//

import Foundation

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
