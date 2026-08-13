//
//  PathfinderHome.swift
//  Spotifly
//
//  The start page Spotify's own client draws, in one request.
//

import Foundation

// MARK: - Envelope

/// `{ "data": { "home": { … } } }`
///
/// **`home` is a union, and its failure member arrives as HTTP 200.** A request Spotify will not
/// answer comes back as `{"data":{"home":{"__typename":"GenericError"}}}` — no `errors` array,
/// no status code to check, and every field below it simply absent. A decoder that only reads
/// optional fields would render an empty page and report success, which is why `sections` being
/// empty is distinguished from the payload being an error at all.
nonisolated struct PathfinderHomeResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        let home: PathfinderHome?
    }

    let data: Payload?

    var home: PathfinderHome? {
        data?.home
    }
}

nonisolated struct PathfinderHome: Decodable, Sendable {
    /// The union member naming a page that could be built. Anything else — `GenericError` today
    /// — means the request was understood and refused.
    static let successTypename = "HomeResponsePayload"

    struct Label: Decodable, Sendable {
        /// The rendered string, with `{0}` already substituted. `translatedBaseText` beside it
        /// still holds the placeholder, so this is the one to show.
        let transformedLabel: String?
    }

    struct SectionContainer: Decodable, Sendable {
        struct Sections: Decodable, Sendable {
            let items: [PathfinderHomeSection]?
        }

        let uri: String?
        let sections: Sections?
    }

    let typename: String?
    let greeting: Label?
    let sectionContainer: SectionContainer?

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case greeting
        case sectionContainer
    }

    var isError: Bool {
        typename != Self.successTypename
    }

    var sections: [PathfinderHomeSection] {
        sectionContainer?.sections?.items ?? []
    }
}

// MARK: - Sections

/// One shelf: a title, and the entities under it.
///
/// **The section's own `__typename` decides presentation, and the app deliberately ignores it.**
/// One account's page carried `HomeGenericSectionData`, `HomeShortsSectionData`,
/// `HomeRecentlyPlayedSectionData` and `HomeFeedBaselineSectionData` in a single response, and
/// the set is Spotify's to extend. Rendering by *item kind* rather than by section kind means an
/// unknown section still draws as a shelf of whatever it holds, rather than disappearing.
///
/// `HomeShortsSectionData` carries no title at all, so a section with no title is a real case
/// rather than a decode failure.
nonisolated struct PathfinderHomeSection: Decodable, Sendable {
    struct SectionData: Decodable, Sendable {
        let typename: String?
        let title: PathfinderHome.Label?

        private enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case title
        }
    }

    struct SectionItems: Decodable, Sendable {
        let items: [PathfinderHomeSectionItem]?
    }

    let uri: String?
    let data: SectionData?
    let sectionItems: SectionItems?

    var title: String? {
        data?.title?.transformedLabel
    }

    var items: [PathfinderHomeSectionItem] {
        sectionItems?.items ?? []
    }
}

nonisolated struct PathfinderHomeSectionItem: Decodable, Sendable {
    let content: PathfinderHomeContent?
}

/// What a shelf entry actually is, chosen by the wrapper's `__typename`.
///
/// The three entity cases decode the same `PathfinderAlbum` / `PathfinderArtist` /
/// `PathfinderPlaylist` that search and the library return — `home` selects the same fields, so
/// nothing here is a fourth spelling of an album.
///
/// **An entry can be a tombstone.** Spotify sends `data.__typename: "NotFound"` for content it
/// listed and then could not resolve, which decodes into the wrapper's type with every field
/// nil. Nothing special catches it: the entity has no uri, so it has no id, and the conversion
/// to a store entity drops it — the same mechanism that drops playlist folders.
nonisolated enum PathfinderHomeContent: Decodable, Sendable {
    case album(PathfinderAlbum)
    case artist(PathfinderArtist)
    case playlist(PathfinderPlaylist)
    /// The "Recents" shelf, which arrives as a single list rather than as one entry per item.
    case list(PathfinderHomeList)
    /// A kind this app has no screen for — an audiobook, a podcast episode, a section format
    /// Spotify added since. Skipped rather than guessed at.
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case data
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typename = try container.decodeIfPresent(String.self, forKey: .typename)

        switch typename {
        case "AlbumResponseWrapper":
            self = try Self.decode(container, as: PathfinderAlbum.self).map(Self.album) ?? .unsupported
        case "ArtistResponseWrapper":
            self = try Self.decode(container, as: PathfinderArtist.self).map(Self.artist) ?? .unsupported
        case "PlaylistResponseWrapper":
            self = try Self.decode(container, as: PathfinderPlaylist.self).map(Self.playlist) ?? .unsupported
        case "ListResponseWrapper":
            self = try Self.decode(container, as: PathfinderHomeList.self).map(Self.list) ?? .unsupported
        default:
            self = .unsupported
        }
    }

    private static func decode<Entity: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>,
        as _: Entity.Type,
    ) throws -> Entity? {
        try container.decodeIfPresent(Entity.self, forKey: .data)
    }
}

// MARK: - The Recents list

/// The one shelf whose entries are not entities but *traits*.
///
/// Everything else on this page arrives as the album, artist or playlist type the rest of the
/// app already reads. "Recents" instead nests a generic `Entity` — name, kind, contributors and
/// cover art each behind their own trait object, and its image sources spell the dimensions
/// `maxWidth`/`maxHeight` where every other pathfinder response says `width`/`height`.
///
/// It is decoded rather than skipped because it is the replacement for
/// `/me/player/recently-played`, which was a section of this app's start page and has no other
/// counterpart on the client APIs.
nonisolated struct PathfinderHomeList: Decodable, Sendable {
    struct Entries: Decodable, Sendable {
        struct Entry: Decodable, Sendable {
            struct Wrapper: Decodable, Sendable {
                let data: PathfinderHomeEntity?
            }

            let entity: Wrapper?
        }

        let items: [Entry]?
    }

    let items: Entries?

    var entities: [PathfinderHomeEntity] {
        (items?.items ?? []).compactMap { $0.entity?.data }
    }
}

nonisolated struct PathfinderHomeEntity: Decodable, Sendable {
    struct IdentityTrait: Decodable, Sendable {
        struct Contributors: Decodable, Sendable {
            struct Contributor: Decodable, Sendable {
                let name: String?
                let uri: String?
            }

            let items: [Contributor]?
        }

        let name: String?
        let contributors: Contributors?
    }

    struct EntityTypeTrait: Decodable, Sendable {
        let type: String?
    }

    struct VisualIdentityTrait: Decodable, Sendable {
        struct CoverImage: Decodable, Sendable {
            struct Image: Decodable, Sendable {
                struct Payload: Decodable, Sendable {
                    struct Source: Decodable, Sendable {
                        let url: String?
                        let maxWidth: Int?
                        let maxHeight: Int?
                    }

                    let sources: [Source]?
                }

                let data: Payload?
            }

            let image: Image?
        }

        let squareCoverImage: CoverImage?
    }

    let uri: String?
    let identityTrait: IdentityTrait?
    let entityTypeTrait: EntityTypeTrait?
    let visualIdentityTrait: VisualIdentityTrait?

    var name: String? {
        identityTrait?.name
    }

    var firstContributor: IdentityTrait.Contributors.Contributor? {
        identityTrait?.contributors?.items?.first
    }

    /// Restated in the shape every other pathfinder image takes, so one `ImageSet` conversion
    /// serves the whole page.
    var imageSources: [PathfinderImage.Source] {
        let sources = visualIdentityTrait?.squareCoverImage?.image?.data?.sources ?? []
        return sources.map {
            PathfinderImage.Source(url: $0.url, width: $0.maxWidth, height: $0.maxHeight)
        }
    }
}

// MARK: - Variables

/// The variables `home` takes — and the one that is optional in the schema but not in practice.
///
/// **`sp_t` decides whether there is a page at all.** GraphQL declares only `timeZone` and
/// `homeEndUserIntegration` as required, and a request carrying just those two is accepted and
/// answered `HomeResponsePayload`-less: `{"data":{"home":{"__typename":"GenericError"}}}`, HTTP
/// 200. Measured 2026-08-13, along with what makes it work: the *value* is never inspected —
/// a real device id, a junk string and the empty string all return the same 31 sections — so
/// only its presence is load-bearing. Nothing here needs a session to send it.
///
/// `timeZone` is likewise unvalidated (`Not/AZone` is accepted), but it is a real input to a
/// page that greets you by time of day, so the real one is sent.
///
/// `sectionItemsLimit` is deliberately not sent. It is not the display cap it looks like:
/// setting it to 3 returned 22 sections instead of 31, so it drops whole shelves rather than
/// trimming them, and the default already stops at 10 items — 30 returned no more than 10.
nonisolated struct PathfinderHomeVariables: Encodable, Sendable {
    /// An IANA identifier, e.g. `Europe/Berlin`.
    var timeZone: String
    /// The only member the schema accepts; established from the web client's own call site.
    var homeEndUserIntegration = "INTEGRATION_WEB_PLAYER"
    /// Present, never read. The installation's device id is used because it already exists and
    /// is already sent to Spotify with every client-token request — inventing a second
    /// identifier for a field nobody reads would be worse on both counts.
    var deviceId: String

    private enum CodingKeys: String, CodingKey {
        case timeZone
        case homeEndUserIntegration
        case deviceId = "sp_t"
    }

    init(
        timeZone: String = TimeZone.current.identifier,
        deviceId: String = UserDefaultsDeviceIdStore().deviceId(),
    ) {
        self.timeZone = timeZone
        self.deviceId = deviceId
    }
}

// MARK: - Profile

/// `profileAttributes`, which is what the web client asks instead of `/me`.
///
/// Everything `UserProfile` holds is here: `username` is the id the Web API called `id`, `name`
/// is `display_name`, and `avatar.sources` is `images`. Only the profile URL is absent, and that
/// is a fixed form rather than a fact — `open.spotify.com/user/<username>`.
nonisolated struct PathfinderProfileResponse: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct Me: Decodable, Sendable {
            let profile: PathfinderProfile?
        }

        let me: Me?
    }

    let data: Payload?

    var profile: PathfinderProfile? {
        data?.me?.profile
    }
}

nonisolated struct PathfinderProfile: Decodable, Sendable {
    let username: String?
    let name: String?
    let uri: String?
    let avatar: PathfinderImage?
}
