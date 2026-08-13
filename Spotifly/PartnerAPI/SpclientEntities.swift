//
//  SpclientEntities.swift
//  Spotifly
//
//  Turning spclient metadata into the entities AppStore holds.
//

import Foundation

/// # Identity
///
/// spclient is **id-faithful**: asked for a track it returns that track, relinking nothing and
/// exposing no relationship between a recording and its market substitute. So it hydrates
/// whatever identity the caller already holds without ever introducing a second one, which is
/// what makes it the right endpoint for `ensureTracksLoaded` — that path exists to fill in ids
/// the store already has.
///
/// The conversion still keys on the **requested** id rather than the returned `gid`. They have
/// always matched in testing, and keying on the request means a day when they stop matching
/// leaves a track unfilled instead of quietly adding a second entity for the same song.
/// `AGENTS.md`, "Track identity is the market id", has the rule this serves.
extension Track {
    /// Nil when the response carries no name — an entity with nothing to render.
    init?(spclient track: SpclientTrack, id: String) {
        guard let name = track.name else { return nil }

        self.init(
            id: id,
            name: name,
            uri: "spotify:track:\(id)",
            durationMs: track.duration ?? 0,
            trackNumber: track.number,
            // metadata/4 carries no external_urls; `Track` generates one from the id.
            externalUrl: nil,
            albumId: track.album?.gid.flatMap(SpotifyGID.base62(fromGID:)),
            artistId: track.artist?.first?.gid.flatMap(SpotifyGID.base62(fromGID:)),
            artistName: track.artistNames.first ?? "Unknown",
            albumName: track.album?.name,
            images: ImageSet(spclientImages: track.album?.coverGroup?.image),
        )
    }
}

extension SpclientAPI {
    /// Store entities for many track ids, keyed by the id that was asked for.
    ///
    /// The pair `TrackService` needs: ids that resolved map to an entity, ids Spotify has no
    /// track for are absent, and a track too incomplete to render counts as absent too.
    func trackEntities(ids: [String]) async throws -> [String: Track] {
        let fetched = try await tracks(ids: ids)

        return fetched.reduce(into: [:]) { entities, entry in
            guard let entity = Track(spclient: entry.value, id: entry.key) else { return }

            entities[entry.key] = entity
        }
    }
}

extension ImageSet {
    /// spclient names cover art by file id rather than by URL, unlike every other endpoint the
    /// app reads. The URLs are assembled here from Spotify's image CDN, which is the same host
    /// the Web API's own image URLs point at.
    init(spclientImages images: [SpclientTrack.Album.CoverGroup.Image]?) {
        let variants = (images ?? []).compactMap { image -> ImageVariant? in
            guard let fileId = image.fileId,
                  let url = URL(string: "https://i.scdn.co/image/\(fileId)")
            else {
                return nil
            }

            return ImageVariant(url: url, size: image.width ?? image.height ?? 0)
        }

        self.init(variants: variants.sorted { $0.size > $1.size })
    }
}
