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
    ///
    /// The description is HTML, and shown as the text it reads as (`String.htmlAsPlainText`).
    nonisolated var normalizedPlaylistDescription: String? {
        guard let self, self != "null" else { return nil }
        let text = self.htmlAsPlainText
        return text.isEmpty ? nil : text
    }
}

extension String {
    /// The text a playlist description's HTML reads as. Measured on the start page on 2026-10-02:
    /// Spotify's mixes link the artists in theirs, `<a href=spotify:playlist:…>Brian Fallon</a>`,
    /// and a user's description comes escaped, `Terri Hooley&#x27;s life`. The header showed
    /// both as they came.
    ///
    /// The tags go first, then the entities: a `<` the user typed arrives as `&lt;`, so a literal
    /// tag is Spotify's own. A bare `&`, as in "Fest & Flauschig", stays.
    nonisolated var htmlAsPlainText: String {
        replacing(/<\/?[a-zA-Z][^<>]*>/, with: "")
            .replacing(/&(#[0-9]+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos);/) { match in
                switch match.1 {
                case "amp": "&"
                case "lt": "<"
                case "gt": ">"
                case "quot": "\""
                case "apos": "'"
                default: Self.character(numbered: match.1) ?? String(match.0)
                }
            }
    }

    /// The character a numeric entity names, `#39` or `#x27`.
    private nonisolated static func character(numbered entity: Substring) -> String? {
        let hex = entity.hasPrefix("#x") || entity.hasPrefix("#X")
        guard let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
              let scalar = Unicode.Scalar(code)
        else { return nil }
        return String(Character(scalar))
    }
}
